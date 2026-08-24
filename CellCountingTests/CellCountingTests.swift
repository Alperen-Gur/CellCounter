//
//  CellCountingTests.swift
//  CellCountingTests
//
//  Created by Alperen Gür on 26.05.2026.
//

import Foundation
import SwiftData
import Testing
@testable import CellCounting

struct CellCountingTests {

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
