import Foundation
import Testing
@testable import CellCounting

@Suite(.serialized) @MainActor
struct WorkbenchNavigationTests {
    @Test func taskOnlyNavigationPreservesSpatialSelectionAndUnfinishedMask() async throws {
        let preferences = UserDefaults(suiteName: "workbench-task-navigation-\(UUID().uuidString)")!
        var operations: [String] = []
        let session = WorkbenchSession(preferences: preferences) { operation, _, _, _ in
            operations.append(operation)
            throw WorkbenchFailure(code: "unexpected-operation", message: operation)
        }
        session.images = [try #require(WorkbenchImage(.object([
            "id": .string("image"), "name": .string("Selected acquisition"),
            "width": .number(64), "height": .number(64), "channels": .number(3)
        ])))]
        session.selectedImageID = "image"
        session.channel = 2
        session.threshold = 243
        session.method = "manual"
        session.polygon = [[1, 2], [3, 4], [5, 6]]
        session.drawingPolygon = true
        session.selectedLabels = [7]
        let spatialSelection = session.viewSessionSelection.object.filter { $0.key != "task" }

        try await session.loadNavigationSelection(.object(["task": .string("measurements")]))

        #expect(session.task == .measurements)
        #expect(session.viewSessionSelection["task"].string == "measurements")
        #expect(session.viewSessionSelection.object.filter { $0.key != "task" } == spatialSelection)
        #expect(session.threshold == 243 && session.method == "manual")
        #expect(session.polygon == [[1, 2], [3, 4], [5, 6]])
        #expect(session.drawingPolygon && session.selectedLabels == [7])
        #expect(operations.isEmpty)
    }

    @Test func unsupportedTaskDoesNotMoveTheCurrentTask() async throws {
        let preferences = UserDefaults(suiteName: "workbench-invalid-navigation-\(UUID().uuidString)")!
        let session = WorkbenchSession(preferences: preferences)
        session.task = .segmentation
        do {
            try await session.loadNavigationSelection(.object(["task": .string("unsupported")]))
            Issue.record("An unsupported task was accepted.")
        } catch let error as WorkbenchFailure {
            #expect(error.code == "task-unavailable")
        }
        #expect(session.task == .segmentation)
    }

    @Test func spatialNavigationCannotBypassDraftDeferralAsATaskOnlyRequest() {
        let preferences = UserDefaults(suiteName: "workbench-spatial-navigation-\(UUID().uuidString)")!
        let session = WorkbenchSession(preferences: preferences)
        #expect(session.isTaskOnlyNavigation(.object(["task": .string("review")])))
        #expect(!session.isTaskOnlyNavigation(.object([
            "task": .string("review"), "imageId": .string("another-image")
        ])))
        #expect(!session.isTaskOnlyNavigation(.object(["task": .string("unsupported")])))
    }
}
