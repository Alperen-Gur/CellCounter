import Foundation
import CoreGraphics
import Testing
@testable import CellCounting

struct ReviewWorkflowTests {
    private func cell(x: Double, y: Double = 10, diameter: Double = 10,
                      confidence: Double = 0.9, area: Double? = 100,
                      intensity: Double? = 50, id: UUID = UUID()) -> DetectedCell {
        DetectedCell(id: id, cx: x, cy: y, diameter: diameter / 2, diameterPx: diameter,
                     confidence: confidence, areaMicrons2: area, meanIntensity: intensity)
    }

    @Test func linkedSelectionSurvivesEditsAndRemovesHiddenOrDeletedCells() {
        let left = cell(x: 10), right = cell(x: 30)
        let removed = UUID()
        let initial: Set<UUID> = [left.id, removed]
        let extended = MeasurementSelection.selecting([right.id], from: initial, extend: true)
        #expect(extended == [left.id, right.id, removed])
        #expect(MeasurementSelection.reconciled(extended, cells: [right]) == [right.id])
        #expect(MeasurementSelection.selecting([left.id], from: extended, extend: false) == [left.id])
        #expect(MeasurementSelection.reconciled(extended, cells: []) == [])
    }

    @Test func overlayEditsPreserveExcludedCellsAndApplySequentialChanges() {
        let included = cell(x: 10), hidden = cell(x: 20, confidence: 0.2), added = cell(x: 30)
        var resized = included
        resized.diameterPx = 22
        let first = MeasurementSelection.merging(visible: [resized, added], into: [included, hidden],
                                                 previouslyVisibleIds: [included.id])
        #expect(first.map(\.id) == [included.id, hidden.id, added.id])
        #expect(first.first?.diameterPx == 22)
        let next = MeasurementSelection.merging(visible: [added], into: first,
                                                previouslyVisibleIds: [included.id, added.id])
        #expect(next.map(\.id) == [hidden.id, added.id])
        #expect(next.first?.confidence == 0.2)
    }

    @Test func includedCountsRespectConfidenceAndIncludeExcludeGeometry() {
        let cells = [cell(x: 10), cell(x: 20), cell(x: 30, confidence: 0.4), cell(x: 90)]
        let regions = [ReviewRegion(kind: "include", x: 0, y: 0, width: 40, height: 40),
                       ReviewRegion(kind: "exclude", shape: "ellipse", x: 15, y: 5, width: 10, height: 10)]
        let summary = ReviewSummary.make(cells: cells, confidence: 0.5, regions: regions)
        #expect(summary.cells.map(\.id) == [cells[0].id])
        #expect(summary.totalCount == 4)
        #expect(summary.excludedCount == 3)
        #expect(cells.count == 4, "Filtering must not discard original detections")
        let restored = ReviewSummary.make(cells: cells, confidence: 0, regions: [])
        #expect(restored.cells.count == 4)
        #expect(restored.excludedCount == 0)
    }

    @Test func summaryUsesStablePopulationDeviationAndIgnoresUnknownMeasurements() {
        let cells = [cell(x: 1, diameter: 20, area: 40), cell(x: 2, diameter: 40, area: 60),
                     cell(x: 3, diameter: 60, area: nil)]
        let summary = ReviewSummary.make(cells: cells, confidence: 0, regions: [])
        #expect(summary.meanDiameter == 20)
        #expect(abs(summary.diameterDeviation - sqrt(200.0 / 3)) < 1e-10)
        #expect(summary.means["area"] == 50)
        #expect(summary.means["perimeter"] == nil)
    }

    @MainActor @Test func cacheReusesStyleRedrawsAndInvalidatesSameCountEditsAndROIMovement() {
        let first = cell(x: 10), second = cell(x: 30)
        let imageId = UUID(), detectionId = UUID(), regionId = UUID()
        let cache = ReviewSummaryCache()
        func key(revision: Int = 0, confidence: Double = 0.5, x: Double = 0, calibration: Double = 2) -> ReviewDataKey {
            ReviewDataKey(imageId: imageId, detectionId: detectionId, revision: revision,
                          confidence: confidence,
                          regions: [ReviewRegion(id: regionId, kind: "include", x: x, y: 0, width: 20, height: 20)],
                          pxPerUm: calibration)
        }
        for _ in 0..<100 { _ = cache.value(for: key(), cells: [first, second]) }
        #expect(cache.rebuildCount == 1)
        #expect(cache.value(for: key(), cells: [first, second]).cells.map(\.id) == [first.id])
        #expect(cache.value(for: key(x: 20), cells: [first, second]).cells.map(\.id) == [second.id])
        #expect(cache.rebuildCount == 2, "Moving one ROI without changing its count must invalidate filtering")
        let edited = cell(x: 30, diameter: 20, id: second.id)
        #expect(cache.value(for: key(revision: 1, x: 20), cells: [first, edited]).meanDiameter == 10)
        #expect(cache.rebuildCount == 3)
        #expect(cache.value(for: key(revision: 1, confidence: 0.95, x: 20), cells: [first, edited]).cells.isEmpty)
        _ = cache.value(for: key(revision: 1, confidence: 0.95, x: 20, calibration: 3), cells: [first, edited])
        #expect(cache.rebuildCount == 5)
    }

    @Test func scatterUsesRawSelectedChannelAndNeverTreatsMissingValuesAsZero() {
        var measured = cell(x: 10)
        measured.channelIntensities = [.init(channel: 2, name: "GFP", mean: 4096, integrated: 409600)]
        let unknown = cell(x: 20, area: nil)
        let plot = MeasurementPlot(cells: [measured, unknown], channel: 2)
        #expect(plot.points.count == 1)
        #expect(plot.points[0].intensity == 4096)
        #expect(MeasurementPlot(cells: [measured], channel: 1).points.isEmpty)
        #expect(MeasurementPlot(cells: [cell(x: 1, intensity: .nan)]).points.isEmpty)
        #expect(plot.areaRange.upperBound > plot.areaRange.lowerBound)
        let size = CGSize(width: 300, height: 200)
        let position = plot.position(plot.points[0], size: size)
        #expect(position.x.isFinite && position.y.isFinite)
        #expect(plot.nearest(to: position, size: size) == measured.id)
        #expect(plot.nearest(to: CGPoint(x: -100, y: -100), size: size) == nil)
    }

    @Test func scatterBoxSelectionIncludesEveryCellBeyondDisplayLimit() {
        let cells = (0..<12_000).map { i in cell(x: Double(i), area: Double(i + 1), intensity: Double(i % 127)) }
        let plot = MeasurementPlot(cells: cells)
        let size = CGSize(width: 300, height: 200)
        #expect(plot.selected(in: CGRect(origin: .zero, size: size), size: size).count == 12_000)
        let rightHalf = plot.selected(in: CGRect(x: 150, y: 0, width: 150, height: 200), size: size)
        #expect(rightHalf.count == 6000)
        #expect(rightHalf.contains(cells.last!.id))
        #expect(!rightHalf.contains(cells.first!.id))
    }

    @Test func variantsClassifyMaskEditsIgnoringConfidenceAndReassignedUUIDs() {
        let unchanged = cell(x: 20), changed = cell(x: 60), removed = cell(x: 100)
        var rerunUnchanged = cell(x: 20, confidence: 0.6)
        rerunUnchanged.areaMicrons2 = 999 // Measurements do not change source geometry.
        var edited = changed
        edited.diameterPx = 14
        let added = cell(x: 150)
        let result = VariantMaskComparison.compare(saved: [unchanged, changed, removed],
                                                   current: [rerunUnchanged, edited, added])
        #expect(result.unchangedSaved == [unchanged.id])
        #expect(result.unchangedCurrent == [rerunUnchanged.id])
        #expect(result.changedSaved == [changed.id])
        #expect(result.changedCurrent == [edited.id])
        #expect(result.removed == [removed.id])
        #expect(result.added == [added.id])
    }

    @Test func variantCorrespondenceIsOneToOneAndPolygonOrderIndependent() {
        var old = cell(x: 10)
        old.contourPx = [CGPoint(x: 0, y: 0), CGPoint(x: 20, y: 0), CGPoint(x: 20, y: 20), CGPoint(x: 0, y: 20)]
        var same = old
        same.contourPx = [CGPoint(x: 20, y: 20), CGPoint(x: 20, y: 0), CGPoint(x: 0, y: 0), CGPoint(x: 0, y: 20)]
        #expect(VariantMaskComparison.sameGeometry(old, same))
        let closingPoint = same.contourPx![0]
        same.contourPx?.append(closingPoint)
        #expect(VariantMaskComparison.sameGeometry(old, same), "An explicit closing vertex does not change a polygon")
        var altered = old
        altered.contourPx?[1].x = 18
        #expect(!VariantMaskComparison.sameGeometry(old, altered))
        #expect(VariantMaskComparison.geometryBounds(old).width == 20)
        let split = [cell(x: 8), cell(x: 12)]
        let result = VariantMaskComparison.compare(saved: [cell(x: 10)], current: split)
        #expect(result.changedCurrent.count + result.unchangedCurrent.count == 1)
        #expect(result.added.count == 1)
        #expect(result.removed.isEmpty)
        #expect(VariantMaskComparison.compare(saved: [], current: split).added.count == 2)
        #expect(VariantMaskComparison.compare(saved: split, current: []).removed.count == 2)
    }

    @Test func comparisonViewportKeepsSourceCoordinatesAlignedWhileZoomingAndPanning() {
        let source = CGSize(width: 1000, height: 500), view = CGSize(width: 500, height: 300)
        let center = CGPoint(x: 0.5, y: 0.5)
        let zoomed = ReviewViewport(sourceSize: source, viewSize: view, zoom: 2, center: center)
        #expect(zoomed.scale == 1)
        #expect(zoomed.visibleSourceRect == CGRect(x: 250, y: 100, width: 500, height: 300))
        let movedCenter = zoomed.centerAfterPan(from: center, translation: CGSize(width: 100, height: -50))
        #expect(movedCenter == CGPoint(x: 0.4, y: 0.6))
        let savedPane = ReviewViewport(sourceSize: source, viewSize: view, zoom: 2, center: movedCenter)
        let currentPane = ReviewViewport(sourceSize: source, viewSize: view, zoom: 2, center: movedCenter)
        #expect(savedPane.visibleSourceRect == currentPane.visibleSourceRect)
        #expect(savedPane.visibleSourceRect == CGRect(x: 150, y: 150, width: 500, height: 300))
        let fit = ReviewViewport(sourceSize: source, viewSize: view, zoom: 1, center: center)
        #expect(fit.visibleSourceRect.contains(CGRect(origin: .zero, size: source)))
        #expect(zoomed.centerAfterPan(from: center, translation: CGSize(width: 10_000, height: -10_000)) == CGPoint(x: 0, y: 1))
    }

    @Test func analysisStatusPreservesUnknownLegacySettingsAndAvoidsClaimingManualReview() {
        #expect(AnalysisStateDescription.model(detectorId: "legacy-yolo", savedModelName: nil)
            == "legacy-yolo · settings unavailable")
        #expect(AnalysisStateDescription.model(detectorId: "cellpose-cyto3", savedModelName: "Original model") == "Original model")
        #expect(AnalysisStateDescription.model(detectorId: nil, savedModelName: nil) == "Not analyzed")
        #expect(AnalysisStateDescription.review(pending: nil, correctionCount: 0) == "Not analyzed")
        #expect(AnalysisStateDescription.review(pending: -1, correctionCount: 0) == "Review status unavailable")
        #expect(AnalysisStateDescription.review(pending: 2, correctionCount: 0) == "2 awaiting review")
        #expect(AnalysisStateDescription.review(pending: 0, correctionCount: 0) == "Review queue clear")
        #expect(AnalysisStateDescription.review(pending: 0, correctionCount: 3) == "Review queue clear · corrected")
    }
}
