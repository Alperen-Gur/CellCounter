import Foundation
import SwiftData
import Testing
@testable import CellCounting

/// Per-image pixel scale: which scale an image gets, how a batch's scales are
/// summarised, how an override is worded, the objective-name check, and which
/// scale changes offer to segment again. Pure values only, apart from the last
/// test, which uses an in-memory library and writes no preferences.
@Suite(.serialized) @MainActor
struct ImageScaleTests {
    private let tenX = ImageScale.Value(pxPerUm: 4.1666, source: "exif-tiff")
    private let twentyX = ImageScale.Value(pxPerUm: 8.3333, source: "exif-tiff")

    private func imageState(_ id: UUID, explicit: ImageScale.Value? = nil, file: ImageScale.Value? = nil,
                            measured: ImageScale.Value? = nil, depends: Bool = true) -> ScaleChange.ImageState {
        ScaleChange.ImageState(id: id, explicit: explicit, file: file, measured: measured,
                               segmentationDependsOnScale: depends)
    }

    // MARK: - Effective scale

    @Test func ownValueWinsThenTheFileThenTheBatch() throws {
        let own = ImageScale.Value(pxPerUm: 3, source: ImageScale.typedSource)
        let fallback = ImageScale.Value(pxPerUm: 2.6, source: ImageScale.defaultSource)
        let mine = try #require(ImageScale.resolve(explicit: own, file: tenX, fallback: fallback))
        #expect(mine.origin == .image && mine.pxPerUm == 3)
        let file = try #require(ImageScale.resolve(explicit: nil, file: tenX, fallback: fallback))
        #expect(file.origin == .file && file.value == tenX)
        let batch = try #require(ImageScale.resolve(explicit: nil, file: nil, fallback: fallback))
        #expect(batch.origin == .batch && batch.pxPerUm == 2.6 && batch.source == "batch:default")
        #expect(ImageScale.resolve(explicit: nil, file: nil, fallback: nil) == nil)
    }

    @Test func unusableValuesMeanNoScale() {
        #expect(ImageScale.Value(0, source: "manual") == nil)
        #expect(ImageScale.Value(-1, source: "manual") == nil)
        #expect(ImageScale.Value(Double.nan, source: "manual") == nil)
        #expect(ImageScale.Value(nil, source: "manual") == nil)
        #expect(ImageScale.Value(2.5, source: nil)?.source == "")
        let zero = ImageScale.Value(pxPerUm: 0, source: "exif-tiff")
        #expect(ImageScale.resolve(explicit: zero, file: zero, fallback: zero) == nil)
        #expect(ImageScale.batchSource("manual") == "batch:manual")
        #expect(ImageScale.batchSource("batch:manual") == "batch:manual")
        #expect(ImageScale.batchSource(nil) == "batch:unrecorded")
    }

    @Test func aValueSetForAnImageNeverSilentlyReplacesItsFile() {
        let typed = ImageScale.Value(pxPerUm: 4.1666, source: ImageScale.typedSource)
        #expect(ImageScale.mismatch(explicit: typed, file: twentyX) != nil)
        let override = ImageScale.Value(pxPerUm: 4.1666, source: ImageScale.overrideSource(filePxPerUm: 8.3333))
        #expect(ImageScale.mismatch(explicit: override, file: twentyX) == nil)
        #expect(ImageScale.mismatch(explicit: typed, file: tenX) == nil)
        #expect(ImageScale.mismatch(explicit: typed, file: nil) == nil)
    }

    @Test func eachImageIsAnalysedAtItsOwnScale() {
        var job = AnalysisRunSettings()
        job.pxPerUm = 0
        job.calibrationSource = ImageScale.unsetSource
        // A job may have no scale for images without one.
        #expect(job.validationError == nil)
        var negative = job; negative.pxPerUm = -1
        #expect(negative.validationError != nil)
        let perImage = job.withScale(ImageScale.Resolved(value: twentyX, origin: .file))
        #expect(perImage.pxPerUm == 8.3333 && perImage.calibrationSource == "exif-tiff")
        #expect(job.withScale(nil) == job)
        // The size hint in pixels follows the image's scale.
        #expect(SizeHint.resolve(perImage).diameterPx == SizeHint.segmentationDiameterPx(diameterUm: 25, pxPerUm: 8.3333))
        // Where a scale came from never forces a new run; its value does.
        var relabelled = perImage; relabelled.calibrationSource = "unconfirmed"
        #expect(relabelled.hasSameInputs(as: perImage))
        var otherScale = perImage; otherScale.pxPerUm = 4.1666
        #expect(!otherScale.hasSameInputs(as: perImage))
        #expect(otherScale.hasSameInputs(as: perImage, ignoringScale: true))
    }

    // MARK: - Words

    @Test func scalesAreDescribedInPlainWords() {
        #expect(ImageScale.caption(tenX) == "4.1666 px/µm · from file")
        #expect(ImageScale.label("metadata-czi") == "from file")
        #expect(ImageScale.label("manual-entry") == "typed")
        #expect(ImageScale.label("manual") == "typed")
        #expect(ImageScale.label("scale-bar") == "scale bar")
        #expect(ImageScale.label("preset-Nikon Ts2 · 10×") == "preset “Nikon Ts2 · 10×”")
        #expect(ImageScale.label("default") == "your default")
        #expect(ImageScale.label("batch:manual") == "batch scale (typed)")
        #expect(ImageScale.label("batch:unrecorded") == "batch scale")
        #expect(ImageScale.label(nil) == "source not recorded")
        #expect(ImageScale.overrideSource(filePxPerUm: 8.33333) == "manual override (file: 8.3333 px/µm)")
        #expect(ImageScale.label("manual override (file: 8.3333 px/µm)") == "your override; file says 8.3333 px/µm")
        #expect(ImageScale.format(2.6) == "2.6")
        #expect(ImageScale.format(4.16663) == "4.1666")
    }

    // MARK: - Grouping and summary

    @Test func aMixedTenAndTwentyXFolderIsGroupedPerScale() {
        var entries = Array(repeating: ImageScale.Entry.scale(tenX), count: 8)
        entries += Array(repeating: .scale(twentyX), count: 8)
        let summary = ImageScale.summarize(entries)
        #expect(summary.lines == ["8 images · 4.1666 px/µm (from file)", "8 images · 8.3333 px/µm (from file)"])
        #expect(summary.text == "8 images · 4.1666 px/µm (from file) · 8 images · 8.3333 px/µm (from file)")
        #expect(summary.distinctScales == 2)
        #expect(summary.overview == "2 scales")
        #expect(summary.missing == 0 && summary.missingLine == nil)
    }

    @Test func imagesWithoutAScaleAreCountedAndNearlyEqualScalesShareAGroup() {
        let typed = ImageScale.Value(pxPerUm: 4.1667, source: ImageScale.typedSource)
        let summary = ImageScale.summarize([
            .scale(tenX), .scale(ImageScale.Value(pxPerUm: 4.1670, source: "exif-tiff")), .scale(typed),
            .missing, .missing, .missing, .missing, .readOnImport,
        ])
        #expect(summary.lines == ["2 images · 4.1666 px/µm (from file)", "1 image · 4.1667 px/µm (typed)"])
        #expect(summary.missingLine == "4 images have no scale")
        #expect(summary.readOnImportLine == "1 image · scale read from the file when imported")
        #expect(summary.distinctScales == 1)
        #expect(summary.overview == "4.1666 px/µm · 4 without")
        #expect(ImageScale.summarize([.missing]).missingLine == "1 image has no scale")
        #expect(ImageScale.summarize([.missing]).overview == "No scale")
        // A value taken from the batch is grouped by where the batch's value came from.
        #expect(ImageScale.summarize([.scale(ImageScale.Value(pxPerUm: 2.6, source: "batch:default"))]).lines
                == ["1 image · 2.6 px/µm (your default)"])
    }

    // MARK: - Override wording

    @Test func anOverrideSaysWhatHappensToTheSizes() {
        #expect(ImageScale.overrideEffect(yours: 5.2, file: 8.32)
                == "Your value is 1.6× smaller than the file's, so sizes would be 1.6× larger.")
        #expect(ImageScale.overrideEffect(yours: 8.3333, file: 4.1666)
                == "Your value is 2× larger than the file's, so sizes would be 2× smaller.")
        #expect(ImageScale.overrideEffect(yours: 4.17, file: 4.1666) == "Your value matches the file's.")
        #expect(ImageScale.overrideEffect(yours: 4.3, file: 4.1666).contains("1.03×"))
        #expect(ImageScale.overrideLines(yours: 4.1666, files: [8.3333, 8.3333, 4.1666]) == [
            "File says 4.1666 px/µm (1 image). Your value matches the file's.",
            "File says 8.3333 px/µm (2 images). Your value is 2× smaller than the file's, so sizes would be 2× larger.",
        ])
    }

    // MARK: - Objective names in file names

    @Test func objectiveTokensAreSeparateWordsInFileNames() {
        #expect(ImageScale.objectiveToken(in: "sample_p7_10x_01.tif") == 10)
        #expect(ImageScale.objectiveToken(in: "field 20X.TIF") == 20)
        #expect(ImageScale.objectiveToken(in: "40×-well3.png") == 40)
        #expect(ImageScale.objectiveToken(in: "63x.czi") == 63)
        #expect(ImageScale.objectiveToken(in: "4x") == 4)
        #expect(ImageScale.objectiveToken(in: "10x_10x.tif") == 10)
        #expect(ImageScale.objectiveToken(in: "sample10x.tif") == nil)
        #expect(ImageScale.objectiveToken(in: "10xA.tif") == nil)
        #expect(ImageScale.objectiveToken(in: "2.5x.tif") == nil)
        #expect(ImageScale.objectiveToken(in: "3x.tif") == nil)
        #expect(ImageScale.objectiveToken(in: "10x_vs_20x.tif") == nil)
        #expect(ImageScale.objectiveToken(in: "unfiltriert5.tif") == nil)
    }

    @Test func objectiveNamesThatContradictTheScalesGiveOneWarning() throws {
        // 20x images measured with the 10x scale.
        let same = ImageScale.objectiveWarning([("a_10x.tif", 4.1666), ("b_20x.tif", 4.1666), ("c_20x.tif", 8.3333)])
        #expect(try #require(same).contains("10x and 20x have the same scale (4.1666 px/µm)"))
        // A scale ratio far from the objectives' ratio.
        let ratio = ImageScale.objectiveWarning([("a_10x.tif", 4.1666), ("b_40x.tif", 10.4)])
        #expect(try #require(ratio).contains("about 4×"))
        // Consistent, unnamed or unscaled images: no warning.
        #expect(ImageScale.objectiveWarning([("a_10x.tif", 4.1666), ("b_20x.tif", 8.3333)]) == nil)
        #expect(ImageScale.objectiveWarning([("a_10x.tif", 2.6), ("b_40x.tif", 10.4)]) == nil)
        #expect(ImageScale.objectiveWarning([("a_10x.tif", 4.1666), ("b.tif", 4.1666)]) == nil)
        #expect(ImageScale.objectiveWarning([("a_10x.tif", nil), ("b_20x.tif", 4.1666)]) == nil)
    }

    // MARK: - Applying a scale: rescale or segment again

    @Test func aTypedValueAppliesOnlyToImagesWithoutAScale() {
        let fileScaled = UUID(), bare = UUID(), bareAnalysed = UUID()
        let context = ScaleChange.Context(batchId: UUID(), images: [
            imageState(fileScaled, file: tenX, measured: tenX),
            imageState(bare),
            imageState(bareAnalysed, measured: ImageScale.Value(pxPerUm: 2.6, source: "batch:default")),
        ], fallback: ImageScale.Value(pxPerUm: 2.6, source: ImageScale.defaultSource), currentImageId: fileScaled)
        #expect(context.withoutOwnScaleCount == 2 && context.fileScaled.count == 1)
        let typed = ImageScale.Value(pxPerUm: 3.2, source: ImageScale.typedSource)
        let plan = ScaleChange.plan(.init(value: typed, scope: .imagesWithoutOwnScale), context: context)
        #expect(plan.fallback == typed)
        #expect(plan.explicit.isEmpty && plan.overridden == 0)
        #expect(plan.changed == [bareAnalysed: ImageScale.Value(pxPerUm: 3.2, source: "batch:manual-entry")])
        #expect(plan.resegment == [bareAnalysed])
        #expect(plan.offersResegmentation)
    }

    @Test func overridingAFilesScaleIsExplicitAndRecorded() throws {
        let analysed = UUID(), pending = UUID()
        let context = ScaleChange.Context(batchId: UUID(), images: [
            imageState(analysed, file: tenX, measured: tenX),
            imageState(pending, file: twentyX),
        ], fallback: nil, currentImageId: analysed)
        let typed = ImageScale.Value(pxPerUm: 5.2, source: ImageScale.typedSource)
        // Without the explicit choice, an image whose file has a scale keeps it.
        #expect(ScaleChange.plan(.init(value: typed, scope: .image(pending)), context: context).isEmpty)
        let plan = ScaleChange.plan(.init(value: typed, scope: .imagesWithoutOwnScale, overrideFiles: true),
                                    context: context)
        #expect(plan.overridden == 2)
        let recorded = try #require(plan.explicit[analysed] ?? nil)
        #expect(recorded.pxPerUm == 5.2 && recorded.source == "manual override (file: 4.1666 px/µm)")
        #expect((plan.explicit[pending] ?? nil)
                == ImageScale.Value(pxPerUm: 5.2, source: "manual override (file: 8.3333 px/µm)"))
        #expect(plan.changed[analysed]?.pxPerUm == 5.2)
        #expect(plan.changed[pending] == nil)
    }

    @Test func oldNumbersChangeOnlyWhenTheUserAsks() {
        let legacy = UUID()
        let atBatchScale = ImageScale.Value(pxPerUm: 4.1666, source: "batch:manual")
        let context = ScaleChange.Context(batchId: UUID(), images: [
            imageState(legacy, file: twentyX, measured: atBatchScale),
        ], fallback: ImageScale.Value(pxPerUm: 4.1666, source: "manual"), currentImageId: legacy)
        // A new scale for images without one leaves it alone.
        let fallbackOnly = ScaleChange.plan(.init(value: ImageScale.Value(pxPerUm: 4, source: ImageScale.typedSource),
                                                  scope: .imagesWithoutOwnScale), context: context)
        #expect(fallbackOnly.changed.isEmpty && fallbackOnly.relabel.isEmpty)
        // Using its file's scale moves it to 8.3333.
        let useFile = ScaleChange.plan(.init(value: twentyX, scope: .image(legacy), useFileScale: true), context: context)
        #expect(useFile.changed == [legacy: twentyX])
        // Keeping 4.1666 as an override changes no number, only the recorded source.
        let keep = ScaleChange.plan(.init(value: ImageScale.Value(pxPerUm: 4.1666, source: ImageScale.typedSource),
                                          scope: .image(legacy), overrideFiles: true), context: context)
        #expect(keep.changed.isEmpty)
        #expect(keep.relabel[legacy]?.source == "manual override (file: 8.3333 px/µm)")
    }

    @Test func modelsThatDoNotUseTheScaleOnlyRescale() {
        let image = UUID()
        let context = ScaleChange.Context(batchId: UUID(), images: [
            imageState(image, measured: ImageScale.Value(pxPerUm: 2, source: "batch:manual"), depends: false),
        ], fallback: ImageScale.Value(pxPerUm: 2, source: "manual"), currentImageId: nil)
        let plan = ScaleChange.plan(.init(value: ImageScale.Value(pxPerUm: 3, source: ImageScale.scaleBarSource),
                                          scope: .imagesWithoutOwnScale), context: context)
        #expect(plan.changed.count == 1 && plan.resegment.isEmpty && !plan.offersResegmentation)

        func depends(_ family: String, _ id: String, diameter: Double = 0, split: Bool = false) -> Bool {
            ImageScale.segmentationDependsOnScale(modelFamily: family, modelId: id,
                                                  expectedDiameterUm: diameter, watershedSplit: split)
        }
        #expect(depends("Cellpose", "cp-cyto3"))
        #expect(depends("Cellpose-SAM", "cpsam"))
        #expect(!depends("StarDist", "sd-2d"))
        #expect(depends("StarDist", "sd-2d", split: true))
        #expect(!depends("Omnipose", "omni-bact"))
        #expect(depends("Omnipose", "omni-bact", diameter: 12))
        #expect(!depends("SAM-family", "sam-b", diameter: 20))
    }

    // MARK: - Notices and exports

    @Test func analysedImagesSayWhenTheirNumbersUseAnotherScale() {
        let atBatchScale = ImageScale.Value(pxPerUm: 4.1666, source: "batch:manual")
        let file = ImageScale.Resolved(value: twentyX, origin: .file)
        let notice = ImageScale.notice(measured: atBatchScale, effective: file)
        #expect(notice == .fileDisagrees(measured: 4.1666, file: 8.3333))
        #expect(notice?.text == "Measured at 4.1666 px/µm; the file says 8.3333 px/µm.")
        let typed = ImageScale.Resolved(value: ImageScale.Value(pxPerUm: 5, source: ImageScale.typedSource), origin: .image)
        #expect(ImageScale.notice(measured: atBatchScale, effective: typed) == .awaitingAnalysis(measured: 4.1666, next: 5))
        #expect(ImageScale.notice(measured: tenX, effective: ImageScale.Resolved(value: tenX, origin: .file)) == nil)
        #expect(ImageScale.notice(measured: nil, effective: file) == nil)
        #expect(ImageScale.segmentationNote(segmented: 4.1666, measured: 8.3333)
                == "Segmented at 4.1666 px/µm, measured at 8.3333 px/µm")
        #expect(ImageScale.segmentationNote(segmented: 4.1666, measured: 4.1667) == nil)
        #expect(ImageScale.segmentationNote(segmented: nil, measured: 4.1666) == nil)
    }

    @Test func exportsRecordEachImagesScaleAndSegmentationScale() {
        let header = ExportService.configHeaderComment(thresholds: [20, 30], pxPerUm: 8.3333, confidence: 0.5,
                                                       modelId: "cp-cyto3", scaleSource: "exif-tiff",
                                                       segmentedPxPerUm: 4.1666)
        #expect(header == "# confidence=0.50; bins=[20,30]; model=cp-cyto3; pxPerUm=8.3333; pxPerUm_source=exif-tiff; segmented_pxPerUm=4.1666")
        #expect(ExportService.configHeaderComment(thresholds: [20, 30], pxPerUm: 2.6, confidence: 0.5, modelId: "m")
                == "# confidence=0.50; bins=[20,30]; model=m; pxPerUm=2.6")
        #expect(ExportService.SummaryScale(pxPerUm: 8.3333, source: "exif-tiff", segmentedPxPerUm: 8.3333).segmentedPxPerUm == nil)
        #expect(ExportService.SummaryScale(pxPerUm: 8.3333, source: "exif-tiff", segmentedPxPerUm: 4.1666).segmentedPxPerUm == 4.1666)
    }

    @Test func presetsOlderVersionsShippedAreRecognised() {
        #expect(CalibrationPreset.wasShipped(name: "Olympus IX73 — 10×", pxPerUm: 2.6))
        #expect(!CalibrationPreset.wasShipped(name: "Olympus IX73 — 10×", pxPerUm: 2.7))
        #expect(!CalibrationPreset.wasShipped(name: "Nikon Ts2 · 10×", pxPerUm: 4.1666))
    }

    // MARK: - Old libraries

    @Test func oldResultsKeepTheirNumbersUntilTheirScaleIsChanged() async throws {
        let repos = Repositories(inMemory: true)
        let batch = repos.createBatch(displayName: "Analysed before per-image scales", modelId: "cp-cyto3",
                                      pxPerUm: 4.1666, thresholds: [20, 30])
        batch.pxPerUmSource = "manual"
        let image = ImageRecord(fileName: "b_20x.tif", originalPath: "/plate/b_20x.tif", widthPx: 100, heightPx: 100)
        image.sourcePxPerUm = 8.3333
        image.sourceCalibrationSource = "exif-tiff"
        repos.context.insert(image)
        repos.attach(image: image, to: batch)
        repos.saveDetection([DetectedCell(cx: 10, cy: 10, diameter: 25 / 4.1666, diameterPx: 25)],
                            detectorId: "test", for: image)
        // Analysed at the batch's scale, which disagrees with the file.
        #expect(image.measuredScale == ImageScale.Value(pxPerUm: 4.1666, source: "batch:manual"))
        #expect(ImageScale.notice(measured: image.measuredScale, effective: image.effectiveScale)
                == .fileDisagrees(measured: 4.1666, file: 8.3333))

        // Changing the batch's scale for images without one keeps its numbers.
        let state = AppState(repos: repos)
        try await state.pinLegacyMeasurementScales(batch)
        batch.pxPerUm = 3
        try repos.context.save()
        #expect(image.measuredScale?.pxPerUm == 4.1666)
        #expect(try #require(image.detection).cells.first?.diameter == 25 / 4.1666)

        // Moving it to its file's scale converts its sizes and records the scale.
        try await state.rescaleImages([image.id: twentyX], in: batch)
        #expect(image.measuredScale == twentyX)
        let detection = try #require(image.detection)
        let diameter = try #require(detection.cells.first?.diameter)
        #expect(abs(diameter - 25 / 8.3333) < 1e-9)
        #expect(ImageScale.notice(measured: image.measuredScale, effective: image.effectiveScale) == nil)
    }
}
