import Foundation
import Testing
@testable import CellCounting

@Suite(.serialized) @MainActor
struct WorkbenchLifecycleTests {
    // MARK: Release and restore

    @Test func leavingWithNothingUnsavedReleasesThenRestoresOnReturn() {
        var residency = WorkbenchViewResidency()
        #expect(residency.transition(toActive: false, hasUnsavedDraft: false, hasDisplayedImage: true) == .release)
        #expect(residency.released)
        #expect(residency.transition(toActive: true, hasUnsavedDraft: false, hasDisplayedImage: false) == .restore)
        #expect(!residency.released)
    }

    @Test func draftsAndRunningWorkKeepTheDisplayedImage() {
        var residency = WorkbenchViewResidency()
        #expect(residency.transition(toActive: false, hasUnsavedDraft: true, hasDisplayedImage: true) == .none)
        #expect(!residency.released)
        #expect(residency.transition(toActive: true, hasUnsavedDraft: true, hasDisplayedImage: true) == .none)
    }

    @Test func repeatedSignalsAndEmptyViewsDoNothing() {
        var residency = WorkbenchViewResidency()
        #expect(residency.transition(toActive: true, hasUnsavedDraft: false, hasDisplayedImage: true) == .none)
        #expect(residency.transition(toActive: false, hasUnsavedDraft: false, hasDisplayedImage: false) == .none)
        #expect(!residency.released)
    }

    @Test func aViewMountedHiddenRestoresOnFirstActivation() {
        var residency = WorkbenchViewResidency(startsActive: false)
        #expect(residency.released)
        #expect(residency.transition(toActive: true, hasUnsavedDraft: false, hasDisplayedImage: false) == .restore)
    }

    @Test func releaseKeepsSelectionAndProject() {
        let session = WorkbenchSession(preferences: UserDefaults(suiteName: "WorkbenchLifecycleTests-\(UUID().uuidString)")!)
        session.selectedImageID = "image-1"
        session.setViewActive(false)
        #expect(session.selectedImageID == "image-1")
        #expect(!session.sharedSession.visible)
        #expect(session.sharedSession.residency.isActive == false)
    }

    // MARK: Poll pausing

    @Test func pollIntervalGrowsWhileIdleAndResetsOnChange() {
        var poll = WorkbenchPollBackoff()
        #expect(poll.interval == WorkbenchPollBackoff.baseInterval)
        for _ in 0..<3 { poll.record(changed: false) }
        #expect(poll.interval == WorkbenchPollBackoff.baseInterval * 2)
        for _ in 0..<100 { poll.record(changed: false) }
        #expect(poll.interval == WorkbenchPollBackoff.ceilingInterval)
        poll.record(changed: true)
        #expect(poll.interval == WorkbenchPollBackoff.baseInterval)
    }

    @Test func returningToTheWorkbenchResetsTheInterval() {
        let session = WorkbenchSession(preferences: UserDefaults(suiteName: "WorkbenchLifecycleTests-\(UUID().uuidString)")!)
        for _ in 0..<9 { session.sharedSession.poll.record(changed: false) }
        #expect(session.sharedSession.poll.interval > WorkbenchPollBackoff.baseInterval)
        session.setViewActive(false)
        session.setViewActive(true)
        #expect(session.sharedSession.poll.interval == WorkbenchPollBackoff.baseInterval)
    }

    @Test func inactiveSessionDoesNotPoll() async {
        let calls = CallCounter()
        let session = WorkbenchSession(
            preferences: UserDefaults(suiteName: "WorkbenchLifecycleTests-\(UUID().uuidString)")!,
            request: { operation, _, _, _ in calls.count += 1; return .null })
        session.sharedSession.visible = false
        session.refreshProjectActivity()
        try? await Task.sleep(for: .milliseconds(50))
        #expect(calls.count == 0)
    }

    // MARK: Streaming batch import

    private func fixtureCells(frame: Int, count: Int) -> [DetectedCell] {
        (0..<count).map { index in
            DetectedCell(cx: Double(10 * index + frame), cy: Double(5 + frame), diameter: 8 + Double(index),
                         diameterPx: 16, confidence: 0.5 + Double(index) / 10,
                         areaMicrons2: 40, contourPx: [CGPoint(x: 1, y: 1), CGPoint(x: 2, y: 3)])
        }
    }

    /// The previous all-at-once implementation, kept as the reference.
    private func referenceLayers(frames: [[DetectedCell]], timeAxis: WorkspaceAxis, axisIDs: [UUID]) -> [WorkspaceLayer] {
        frames.enumerated().map { frame, cells in
            let points = cells.map { cell in
                WorkspacePoint(id: cell.id, coordinate: WorkspaceCoordinate(x: cell.cx, y: cell.cy),
                               position: WorkspacePosition(indices: [timeAxis.id: frame]), label: "Cell",
                               features: ["diameter": cell.diameter, "confidence": cell.confidence])
            }
            return WorkspaceLayer(name: "Cells · frame \(frame + 1)", kind: .points,
                                  source: .generated(operation: "CellCounter detections"),
                                  payload: .points(points), axisIDs: axisIDs, metadata: ["frame": String(frame)])
        }
    }

    @Test func streamedImportMatchesAllAtOnceImport() {
        let full = [fixtureCells(frame: 0, count: 3), [], fixtureCells(frame: 2, count: 2)]
        // Streaming: each frame is reduced as it arrives; the full cells are dropped.
        var streamed: [[WorkspaceFrameCell]] = []
        for cells in full { streamed.append(cells.map(WorkspaceFrameCell.init)) }

        let session = WorkspaceSession()
        session.importDetections(frames: streamed)
        guard let timeAxis = session.workspace.axes.first(where: { $0.kind == .time }) else {
            Issue.record("time axis missing"); return
        }
        #expect(timeAxis.length == 3)
        let expected = referenceLayers(frames: full, timeAxis: timeAxis, axisIDs: session.workspace.axes.map(\.id))
        let actual = session.workspace.layers
        #expect(actual.count == expected.count)
        for (got, want) in zip(actual, expected) {
            #expect(got.name == want.name && got.kind == want.kind && got.source == want.source)
            #expect(got.payload == want.payload)
            #expect(got.metadata == want.metadata && got.axisIDs == want.axisIDs)
        }
    }
}

@MainActor private final class CallCounter { var count = 0 }
