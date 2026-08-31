//
//  CellCountingTests.swift
//  CellCountingTests
//
//  Created by Alperen Gür on 26.05.2026.
//

import Foundation
import AppKit
import ImageIO
import SwiftData
import Testing
import UniformTypeIdentifiers
@testable import CellCounting

struct CellCountingTests {

    @Test @MainActor func largeInteractiveWorkloadsStayWithinFrameFriendlyBudgets() {
        let side = 50
        let count = side * side
        let imageId = UUID()
        let cells: [DetectedCell] = (0..<count).map { index in
            let x = Double(index % side) * 24 + 12
            let y = Double(index / side) * 24 + 12
            return DetectedCell(cx: x, cy: y, diameter: 10,
                                diameterPx: 18, confidence: 0.9)
        }
        let annotations = cells.map {
            GroundTruthAnnotation(imageId: imageId, cx: $0.cx + 0.5, cy: $0.cy - 0.5)
        }

        var score: AnnotationMatcher.Score?
        let matcherTime = ContinuousClock().measure {
            score = AnnotationMatcher.evaluate(
                annotations: annotations, detections: cells,
                matchRadiusFactor: 0.75)
        }
        #expect(score?.tp == count)
        #expect(Self.seconds(matcherTime) < 0.45,
                "Large annotation matching must remain interactive")

        let detection = DetectionRecord(detectorId: "performance", cells: cells)
        _ = detection.cells
        var observedCount = 0
        let cachedAccessTime = ContinuousClock().measure {
            for _ in 0..<150 { observedCount += detection.cells.count }
        }
        #expect(observedCount == count * 150)
        #expect(Self.seconds(cachedAccessTime) < 0.08,
                "Repeated cell reads must use the decoded revision cache")

        let frames = (0..<4).map { frame in
            cells.map { cell in
                DetectedCell(cx: cell.cx + Double(frame) * 2,
                             cy: cell.cy + Double(frame),
                             diameter: cell.diameter,
                             diameterPx: cell.diameterPx,
                             confidence: cell.confidence)
            }
        }
        var drift: [SequenceWorkflowService.DriftOffset] = []
        let driftTime = ContinuousClock().measure {
            drift = SequenceWorkflowService.estimateDrift(frames: frames)
        }
        #expect(drift.last?.dxPx == 6)
        #expect(drift.last?.dyPx == 3)
        #expect(Self.seconds(driftTime) < 0.45,
                "Sequence drift estimation must avoid quadratic frame scans")

        var propagation: SequenceWorkflowService.PropagationResult?
        let propagationTime = ContinuousClock().measure {
            propagation = SequenceWorkflowService.propagate(
                sourceCells: cells, sourceFrame: 0,
                frames: [cells, frames[1]], offsets: Array(drift.prefix(2)),
                targetFrames: [1])
        }
        #expect(propagation?.skippedExisting == count)
        #expect(Self.seconds(propagationTime) < 0.45,
                "Sequence propagation must use spatial conflict lookup")

        let insightInput = BatchInsightsInput(
            revision: 1,
            images: frames.enumerated().map { frame, frameCells in
                .init(id: UUID(), fileName: "frame-\(frame).png",
                      cells: frameCells, imageStats: [:])
            })
        var insight: BatchInsightsSnapshot?
        let insightTime = ContinuousClock().measure {
            insight = BatchInsightsService.compute(insightInput)
        }
        #expect(insight?.cellCount == count * frames.count)
        #expect(Self.seconds(insightTime) < 0.65,
                "Batch analytics must stay off the quadratic drift path")
    }

    private static func seconds(_ duration: Duration) -> Double {
        let parts = duration.components
        return Double(parts.seconds) + Double(parts.attoseconds) / 1_000_000_000_000_000_000
    }

    @Test func vendorImportAllowListMatchesPythonReaders() {
        #expect(ImageLoader.vendorSupported == ["nd2", "czi", "lif", "oif", "oib", "oir"])
        #expect(ImageLoader.vendorSupported.isSubset(of: ImageLoader.supported))
        #expect(ImageLoader.isVendorExtension(".ND2"))
        #expect(!ImageLoader.isVendorExtension("png"))
    }

    @Test func overlayPaletteNormalizesInvalidColorsAndClampsBins() {
        let palette = OverlayPalette(
            binHexes: ["not-a-color", "#112233"],
            overlayMode: .byBin,
            singleOverlayHex: "invalid"
        ).normalized()

        #expect(palette.binHexes == ["#112233"])
        #expect(palette.binHex(-10) == "#112233")
        #expect(palette.binHex(99) == "#112233")
        #expect(palette.singleOverlayHex == "#00D7FF")
    }

    @Test @MainActor func homeCalibrationLeavesAnalyzedBatchFrozen() {
        let defaults = UserDefaults.standard
        let oldValue = defaults.object(forKey: "cc-pxperum")
        defer {
            if let oldValue { defaults.set(oldValue, forKey: "cc-pxperum") }
            else { defaults.removeObject(forKey: "cc-pxperum") }
        }

        let repos = Repositories(inMemory: true)
        let batch = repos.createBatch(displayName: "Analyzed batch",
                                      modelId: "test", pxPerUm: 2.5,
                                      thresholds: [10, 20])
        let state = AppState(repos: repos)
        state.currentBatchId = batch.id

        state.applyCalibration(8.0, source: "manual-entry",
                               updateCurrentBatch: false)

        #expect(state.pxPerUm == 8.0)
        #expect(batch.pxPerUm == 2.5)
        #expect(batch.pxPerUmSource == nil)
    }

    @Test func batchAnnotatedExportUsesBatchFolderAndWritesEveryImage() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("CellCounterBatchExport-\(UUID().uuidString)",
                                    isDirectory: true)
        try FileManager.default.createDirectory(at: root,
                                                withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let source = root.appendingPathComponent("source.png")
        try Self.writeSolidPNG(to: source, width: 800, height: 500)
        let cell = DetectedCell(cx: 70, cy: 55, diameter: 18,
                                diameterPx: 36, confidence: 0.95)
        let inputs = [
            ExportService.BatchAnnotatedImageInput(
                fileName: "field.nd2", imageURL: source,
                cells: [cell], confidence: 0.5),
            ExportService.BatchAnnotatedImageInput(
                fileName: "field.nd2", imageURL: source,
                cells: [cell], confidence: 0.5),
        ]

        let result = try ExportService.writeBatchAnnotatedPNGs(
            batchName: "Plate 7 / Control",
            images: inputs,
            thresholds: [10, 20],
            pxPerUm: 1.5,
            overlayMode: .outline,
            parentDirectory: root)

        #expect(result.folder.lastPathComponent == "Plate 7 _ Control")
        #expect(result.errors.isEmpty)
        #expect(result.written == ["field-annotated.png", "field-annotated_2.png"])
        for name in result.written {
            let url = result.folder.appendingPathComponent(name)
            #expect(FileManager.default.fileExists(atPath: url.path))
            #expect(CGImageSourceCreateWithURL(url as CFURL, nil) != nil)
        }

        let geometry = ExportService.scaleBarGeometry(
            imageWidth: 800, imageHeight: 500, pxPerUm: 1.5)
        #expect(geometry.barLengthPx == 150)
        #expect(geometry.label == "100 µm")
    }

    private static func writeSolidPNG(to url: URL,
                                      width: Int,
                                      height: Int) throws {
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        let context = CGContext(data: nil, width: width, height: height,
                                bitsPerComponent: 8, bytesPerRow: 0,
                                space: space,
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(CGColor(gray: 0.18, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let image = context.makeImage()!
        let destination = CGImageDestinationCreateWithURL(
            url as CFURL, UTType.png.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else {
            throw NSError(domain: "CellCountingTests", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "PNG fixture write failed"])
        }
    }

    @Test func detectionStorageSnapshotPreservesCellsAndSummaries() {
        let firstId = UUID()
        let cells = [
            DetectedCell(id: firstId, cx: 10, cy: 20, diameter: 6,
                         diameterPx: 12, confidence: 0.42, isManual: true),
            DetectedCell(cx: 30, cy: 40, diameter: 8,
                         diameterPx: 16, confidence: 0.91),
        ]
        let detection = DetectionRecord(detectorId: "test", cells: [])

        let snapshot = DetectionRecord.makeStorageSnapshot(cells)
        detection.applyStorageSnapshot(snapshot)

        #expect(detection.summaryCellCount == 2)
        #expect(detection.cellsRevision == 1)
        #expect(detection.minConfidence == 0.42)
        #expect(detection.cells.map(\.id) == cells.map(\.id))
        #expect(detection.cells.first?.isManual == true)
    }

    @Test func cellPayloadRevisionInvalidatesDecodedCaches() {
        let detection = DetectionRecord(
            detectorId: "test",
            cells: [DetectedCell(cx: 1, cy: 2, diameter: 3,
                                 diameterPx: 6, confidence: 0.8)])
        #expect(detection.cellsRevision == 0)

        detection.cells = detection.cells + [
            DetectedCell(cx: 4, cy: 5, diameter: 6,
                         diameterPx: 12, confidence: 0.7),
        ]
        #expect(detection.cellsRevision == 1)

        detection.applyStorageSnapshot(DetectionRecord.makeStorageSnapshot([]))
        #expect(detection.cellsRevision == 2)
        #expect(detection.summaryCellCount == 0)
    }

    @Test @MainActor func aSingleReviewCorrectionTriagesOneIndexedRow() throws {
        let repos = Repositories(inMemory: true)
        let batch = repos.createBatch(displayName: "review", modelId: "test",
                                      pxPerUm: 1, thresholds: [10, 20])
        let image = ImageRecord(fileName: "review.png", originalPath: "",
                                widthPx: 100, heightPx: 100)
        repos.context.insert(image)
        repos.attach(image: image, to: batch)
        let cells = [
            DetectedCell(cx: 10, cy: 10, diameter: 5, diameterPx: 5, confidence: 0.2),
            DetectedCell(cx: 20, cy: 20, diameter: 5, diameterPx: 5, confidence: 0.3),
        ]
        repos.saveDetection(cells, detectorId: "test", for: image)
        let detection = try #require(image.detection)

        let result = repos.commitCellEdit(
            storage: nil,
            corrections: [CorrectionSpec(kind: "accept", cell: cells[0])],
            detection: detection,
            image: image)

        #expect(result.reviewCountDelta == -1)
        #expect(detection.reviewPendingCount == 1)
        #expect(repos.pendingReviewCandidateCount() == 1)
        #expect(detection.corrections.count == 1)
    }

    @Test func batchSummaryDoesNotNeedDetectionBlobDecoding() {
        let batch = BatchRecord(name: "batch", displayName: "Batch",
                                modelId: "test", pxPerUm: 2,
                                thresholds: [10, 20])
        batch.imageCountSummary = 700
        batch.cellCountSummary = 12_345

        #expect(batch.imageCount == 700)
        #expect(batch.totalCells == 12_345)
    }

    @Test func sequenceDriftCorrectionKeepsAStationaryObjectAligned() {
        let frames = [
            [DetectedCell(cx: 10, cy: 20, diameter: 8, diameterPx: 16, confidence: 0.9)],
            [DetectedCell(cx: 15, cy: 23, diameter: 8, diameterPx: 16, confidence: 0.9)],
            [DetectedCell(cx: 20, cy: 26, diameter: 8, diameterPx: 16, confidence: 0.9)],
        ]

        let offsets = SequenceWorkflowService.estimateDrift(frames: frames)
        let corrected = SequenceWorkflowService.driftCorrected(frames: frames, offsets: offsets)

        #expect(offsets.map(\.dxPx) == [0, 5, 10])
        #expect(offsets.map(\.dyPx) == [0, 3, 6])
        #expect(corrected.map { $0[0].cx } == [10, 10, 10])
        #expect(corrected.map { $0[0].cy } == [20, 20, 20])
    }

    @Test func propagationUsesDriftAndDoesNotDuplicateExistingLabels() {
        let selected = DetectedCell(cx: 10, cy: 20, diameter: 8,
                                    diameterPx: 16, confidence: 0.9)
        let existing = DetectedCell(cx: 20, cy: 26, diameter: 8,
                                    diameterPx: 16, confidence: 0.9)
        let offsets = [
            SequenceWorkflowService.DriftOffset(frame: 0, dxPx: 0, dyPx: 0, matchedObjects: 0),
            SequenceWorkflowService.DriftOffset(frame: 1, dxPx: 5, dyPx: 3, matchedObjects: 1),
            SequenceWorkflowService.DriftOffset(frame: 2, dxPx: 10, dyPx: 6, matchedObjects: 1),
        ]

        let result = SequenceWorkflowService.propagate(
            sourceCells: [selected], sourceFrame: 0,
            frames: [[selected], [], [existing]], offsets: offsets,
            targetFrames: [1, 2])

        #expect(result.cellsByFrame[1]?.first?.cx == 15)
        #expect(result.cellsByFrame[1]?.first?.cy == 23)
        #expect(result.cellsByFrame[2] == nil)
        #expect(result.skippedExisting == 1)
    }

    @Test func labelInterpolationCreatesIntermediateMasks() {
        let start = DetectedCell(cx: 0, cy: 0, diameter: 4, diameterPx: 8,
                                 confidence: 0.9,
                                 contourPx: [.init(x: -1, y: -1), .init(x: 1, y: -1),
                                             .init(x: 1, y: 1), .init(x: -1, y: 1)])
        let end = DetectedCell(cx: 30, cy: 15, diameter: 10, diameterPx: 20,
                               confidence: 0.8,
                               contourPx: [.init(x: 29, y: 14), .init(x: 31, y: 14),
                                           .init(x: 31, y: 16), .init(x: 29, y: 16)])

        let interpolated = SequenceWorkflowService.interpolate(
            start: start, startFrame: 0, end: end, endFrame: 3)

        #expect(interpolated.count == 2)
        #expect(interpolated[1]?.cx == 10)
        #expect(interpolated[2]?.cy == 10)
        #expect(interpolated[1]?.contourPx?.count == 16)
    }

    @Test func preprocessingArgumentsOnlyEnableRequestedWork() {
        let input = DetectionInput(
            imageURL: nil, modelId: "test", pxPerUm: 1,
            confidenceThreshold: 0.5,
            preprocessingPreset: .claheAndDiffusion, useGPU: true)

        #expect(input.preprocessingArguments == [
            "--clahe", "--anisotropic-diffusion", "--gpu-preprocess",
        ])
    }

    @Test func batchInsightsAreDeterministicAndRankRiskyImagesFirst() {
        let safeId = UUID()
        let riskyId = UUID()
        let safeCells = (0..<10).map { index in
            DetectedCell(cx: Double(index * 10), cy: 10, diameter: 12,
                         diameterPx: 24, confidence: 0.95)
        }
        let riskyCells = (0..<10).map { index in
            DetectedCell(cx: Double(index * 10 + 12), cy: 14, diameter: 8,
                         diameterPx: 16, confidence: 0.3,
                         edgeTouching: true, likelyDebris: true)
        }
        let input = BatchInsightsInput(revision: 7, images: [
            .init(id: safeId, fileName: "safe.tif", cells: safeCells,
                  imageStats: ["focus_score": 0.9, "illumination_residual": 0.02]),
            .init(id: riskyId, fileName: "risky.tif", cells: riskyCells,
                  imageStats: ["focus_score": 0.2, "illumination_residual": 0.5,
                               "ensemble_agreement": 4, "ensemble_disagreement": 6]),
        ])

        let snapshot = BatchInsightsService.compute(input)

        #expect(snapshot.revision == 7)
        #expect(snapshot.cellCount == 20)
        #expect(snapshot.confidenceBins.reduce(0, +) == 20)
        #expect(snapshot.diameterBins.reduce(0, +) == 20)
        #expect(snapshot.riskImages.first?.imageId == riskyId)
        #expect(snapshot.ensembleAgreement == 4)
        #expect(snapshot.ensembleDisagreement == 6)
        #expect(snapshot.recommendations.contains { $0.contains("CLAHE") })
    }

}
