import Foundation
import CoreGraphics
import Testing
@testable import CellCounting

/// Expected cell size ("size hint"): the Swift mirror of the sidecar rule
/// `max(15.0, diameter_um * pxPerUm)` with the size-class midpoint as the
/// automatic value, the inline warnings, and how runs record and export it.
@Suite(.serialized) @MainActor
struct SizeHintTests {
    // MARK: Conversion

    @Test func micrometresConvertToPixelsWithTheSidecarClamp() {
        #expect(SizeHint.segmentationDiameterPx(diameterUm: 25, pxPerUm: 2.6) == 65)
        #expect(SizeHint.segmentationDiameterPx(diameterUm: 10, pxPerUm: 2) == 20)
        // Below 15 px the sidecar uses 15 px.
        #expect(SizeHint.unclampedDiameterPx(diameterUm: 5, pxPerUm: 2) == 10)
        #expect(SizeHint.segmentationDiameterPx(diameterUm: 5, pxPerUm: 2) == 15)
        #expect(SizeHint.segmentationDiameterPx(diameterUm: 7.5, pxPerUm: 2) == 15)
        #expect(abs(SizeHint.segmentationDiameterPx(diameterUm: 25, pxPerUm: 8.33) - 208.25) < 1e-9)
    }

    @Test func automaticIsTheMidpointOfTheFirstAndLastSizeClass() {
        #expect(SizeHint.automaticDiameterUm(thresholds: [20, 30]) == 25)
        #expect(SizeHint.automaticDiameterUm(thresholds: [10, 20, 40]) == 25)
        #expect(SizeHint.automaticDiameterUm(thresholds: [12]) == 12)
        // The Swift side forwards 20 and 30 when a run has no thresholds.
        #expect(SizeHint.automaticDiameterUm(thresholds: []) == 25)
        #expect(SizeHint.effectiveDiameterUm(expectedDiameterUm: 0, thresholds: [8, 14]) == 11)
        #expect(SizeHint.effectiveDiameterUm(expectedDiameterUm: 17, thresholds: [8, 14]) == 17)
        #expect(SizeHint.isAutomatic(0) && SizeHint.isAutomatic(-1) && SizeHint.isAutomatic(.nan))
        #expect(!SizeHint.isAutomatic(0.5))
    }

    @Test func resolvedValueFollowsEachDetectorFamily() {
        var settings = AnalysisRunSettings()
        settings.pxPerUm = 2; settings.thresholds = [20, 30]
        #expect(SizeHint.resolve(settings) == .init(source: "automatic", behavior: .cellposeRescale,
                                                    diameterUm: 25, diameterPx: 50))
        settings.expectedDiameterUm = 6
        #expect(SizeHint.resolve(settings) == .init(source: "explicit", behavior: .cellposeRescale,
                                                    diameterUm: 6, diameterPx: 15))

        settings.modelId = "cpsam"; settings.modelFamily = "Cellpose-SAM"
        #expect(SizeHint.behavior(for: settings) == .cellposeRescale)

        // Omnipose: automatic is no rescaling, an explicit value is not clamped.
        settings.modelId = "omni-bact"; settings.modelFamily = "Omnipose"
        #expect(SizeHint.resolve(settings) == .init(source: "explicit", behavior: .omniposeRescale,
                                                    diameterUm: 6, diameterPx: 12))
        settings.expectedDiameterUm = 0
        #expect(SizeHint.resolve(settings) == .init(source: "automatic", behavior: .omniposeRescale))
        #expect(SizeHint.summary(SizeHint.resolve(settings)) == "Automatic · no rescaling")

        settings.modelId = "cw-otsu"; settings.modelFamily = "Classical"
        #expect(SizeHint.behavior(for: settings) == .watershedSpacing)
        settings.modelId = "sd-versatile"; settings.modelFamily = "StarDist"
        #expect(SizeHint.summary(SizeHint.resolve(settings)) == "Not used by this model")
    }

    @Test func ensemblesRecordThatEachMemberUsesTheValueItsOwnWay() {
        #expect(SizeHint.behavior(modelFamily: "Ensemble", modelId: "ensemble") == .mixed)
        let auto = SizeHint.resolve(expectedDiameterUm: 0, thresholds: [20, 30], pxPerUm: 2.6, behavior: .mixed)
        #expect(auto.diameterUm == nil)
        #expect(auto.diameterPx == nil)
        #expect(SizeHint.summary(auto) == "Automatic · per ensemble member")
        let set = SizeHint.resolve(expectedDiameterUm: 12, thresholds: [20, 30], pxPerUm: 2.6, behavior: .mixed)
        #expect(set.diameterUm == 12)
        #expect(set.diameterPx == nil)
        #expect(SizeHint.summary(set) == "12 µm · per ensemble member")
    }

    @Test func summariesAreShortAndUnitLabelled() {
        let auto = SizeHint.resolve(expectedDiameterUm: 0, thresholds: [20, 30], pxPerUm: 2.6, behavior: .cellposeRescale)
        #expect(SizeHint.summary(auto) == "Automatic · 25 µm · 65 px")
        let explicit = SizeHint.resolve(expectedDiameterUm: 12.5, thresholds: [20, 30], pxPerUm: 2, behavior: .cellposeRescale)
        #expect(SizeHint.summary(explicit) == "12.5 µm · 25 px")
        #expect(SizeHint.format(2.6, digits: 3) == "2.6")
        #expect(SizeHint.format(8.333, digits: 3) == "8.333")
        #expect(SizeHint.format(208.25, digits: 0) == "208")
    }

    // MARK: Warnings

    @Test func warningsMatchTheClampAndHeavyShrink() {
        // Under the 15 px clamp.
        #expect(SizeHint.warning(diameterUm: 5, pxPerUm: 2) == .belowMinimum(px: 10))
        // 25 µm at 8.33 px/µm is about 208 px: the image is scaled down heavily.
        #expect(SizeHint.warning(diameterUm: 25, pxPerUm: 8.33) == .heavyShrink(px: 25 * 8.33))
        // Typical 10× case: no warning.
        #expect(SizeHint.warning(diameterUm: 25, pxPerUm: 2.6) == nil)
        // Boundaries are inclusive of the working range.
        #expect(SizeHint.warning(diameterUm: 7.5, pxPerUm: 2) == nil)
        #expect(SizeHint.warning(diameterUm: 60, pxPerUm: 2) == nil)
        #expect(SizeHint.warning(diameterUm: 60.5, pxPerUm: 2) == .heavyShrink(px: 121))
        // Only the Cellpose family clamps and rescales this way.
        #expect(SizeHint.warning(diameterUm: 5, pxPerUm: 2, behavior: .omniposeRescale) == nil)
        #expect(SizeHint.warning(diameterUm: 5, pxPerUm: 2, behavior: .unused) == nil)
        #expect(SizeHint.warning(diameterUm: 5, pxPerUm: 0) == nil)
        #expect(SizeHint.Warning.belowMinimum(px: 10).message.contains("15 px"))
        #expect(SizeHint.Warning.heavyShrink(px: 208.25).message.contains("208 px"))
    }

    // MARK: Measuring on the image

    @Test func measuredLineConvertsToMicrometres() throws {
        // A 400 × 100 image fitted into 200 × 100 points is drawn at half size.
        let length = try #require(LineMeasurement.imagePixelLength(
            from: CGPoint(x: 10, y: 50), to: CGPoint(x: 36, y: 50),
            viewSize: CGSize(width: 200, height: 100), imageSize: CGSize(width: 400, height: 100)))
        #expect(abs(length - 52) < 1e-9)
        #expect(SizeHint.measuredDiameterUm(lengthPx: length, pxPerUm: 2.6) == 20)
        #expect(SizeHint.measuredDiameterUm(lengthPx: 33, pxPerUm: 2.6) == 12.7)
        #expect(SizeHint.measuredDiameterUm(lengthPx: 0.5, pxPerUm: 2.6) == nil)
        #expect(SizeHint.measuredDiameterUm(lengthPx: 30, pxPerUm: 0) == nil)
        #expect(LineMeasurement.imagePixelLength(from: .zero, to: CGPoint(x: 1, y: 1),
                                                 viewSize: .zero, imageSize: CGSize(width: 1, height: 1)) == nil)
    }

    // MARK: Persistence and provenance

    @Test func runSettingsKeepTheStoredMeaning() throws {
        var settings = AnalysisRunSettings()
        #expect(settings.expectedDiameterUm == 0)   // automatic by default
        settings.expectedDiameterUm = 12.5
        let decoded = try JSONDecoder().decode(AnalysisRunSettings.self, from: JSONEncoder().encode(settings))
        #expect(decoded == settings && decoded.expectedDiameterUm == 12.5)
        var changed = settings; changed.expectedDiameterUm = 0
        #expect(!changed.hasSameInputs(as: settings))
        changed.expectedDiameterUm = -1
        #expect(changed.validationError != nil)
    }

    @Test func savedJobKeepsTheExpectedCellSize() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("size-hint-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = AnalysisJobStore(url: directory.appendingPathComponent("jobs.json"))
        var settings = AnalysisRunSettings(); settings.expectedDiameterUm = 14
        let job = AnalysisJob(batchId: UUID(), title: "Sizes", settings: settings,
                              items: [AnalysisJobItem(url: URL(fileURLWithPath: "/tmp/a.tif"), imageId: UUID())])
        try await store.save([job])
        let recovered = try #require(try await store.load().first)
        #expect(recovered.settings.expectedDiameterUm == 14)
    }

    @Test func provenanceRecordsTheSizeTheRunUsed() throws {
        let repos = Repositories(inMemory: true)
        let batch = repos.createBatch(displayName: "Sizes", modelId: "cp-cyto3", pxPerUm: 5, thresholds: [20, 30])
        let image = ImageRecord(fileName: "a.tif", originalPath: "/a.tif", widthPx: 20, heightPx: 20)
        repos.attach(image: image, to: batch)
        var run = AnalysisRunSettings(); run.pxPerUm = 2; run.thresholds = [20, 30]; run.expectedDiameterUm = 12
        repos.saveDetection([DetectedCell(cx: 10, cy: 10, diameter: 5, diameterPx: 10)],
                            detectorId: "Cellpose/cp-cyto3", for: image, runSettings: run)
        let state = AppState(repos: repos)
        let metadata = ProvenanceMetadata.capture(for: image, state: state)
        // The run's own calibration, not the batch's later one.
        #expect(metadata.sizeHint == .init(source: "explicit", behavior: .cellposeRescale, diameterUm: 12, diameterPx: 24))
        let csv = metadata.asCSVHeader
        #expect(csv.contains("# expected_diameter_source: explicit\n"))
        #expect(csv.contains("# expected_diameter_um: 12\n"))
        #expect(csv.contains("# expected_diameter_px: 24.0\n"))
        #expect(metadata.asMarkdown.contains("- Expected cell size: 12 µm · 24 px"))
        #expect(PDFReportGenerator.provenanceFooterLines(metadata).last == "expected cell size: 12 µm · 24 px")

        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(ProvenanceMetadata.self, from: metadata.asJSON)
        #expect(decoded.sizeHint == metadata.sizeHint)
        #expect(decoded.originalRunSettings?.expectedDiameterUm == 12)

        run.expectedDiameterUm = 0
        repos.saveDetection([], detectorId: "Cellpose/cp-cyto3", for: image, runSettings: run)
        let automatic = ProvenanceMetadata.capture(for: image, state: state)
        #expect(automatic.sizeHint == .init(source: "automatic", behavior: .cellposeRescale, diameterUm: 25, diameterPx: 50))
        #expect(automatic.asCSVHeader.contains("# expected_diameter_source: automatic\n# expected_diameter_um: 25\n# expected_diameter_px: 50.0\n"))
    }

    @Test func runsWithoutSettingsExportNoSizeHint() {
        let image = ImageRecord(fileName: "old.tif", originalPath: "/old.tif", widthPx: 20, heightPx: 20)
        image.detection = DetectionRecord(detectorId: "Cellpose/cp-cyto3", cells: [])
        let metadata = ProvenanceMetadata.capture(for: image, state: AppState(repos: Repositories(inMemory: true)))
        #expect(metadata.sizeHint == nil)
        #expect(!metadata.asCSVHeader.contains("expected_diameter"))
    }
}
