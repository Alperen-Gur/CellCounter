import Foundation

/// The fields a workspace keeps for a detected cell. A batch import converts
/// each image's full measurements to this form as soon as they are loaded.
nonisolated struct WorkspaceFrameCell: Equatable, Sendable {
    var id: UUID
    var cx: Double
    var cy: Double
    var diameter: Double
    var confidence: Double

    init(_ cell: DetectedCell) {
        id = cell.id; cx = cell.cx; cy = cell.cy
        diameter = cell.diameter; confidence = cell.confidence
    }

    static func makeLayer(frame: Int, cells: [WorkspaceFrameCell], timeAxisID: UUID,
                          axisIDs: [UUID]) -> WorkspaceLayer {
        let points = cells.map { cell in
            WorkspacePoint(id: cell.id,
                           coordinate: WorkspaceCoordinate(x: cell.cx, y: cell.cy),
                           position: WorkspacePosition(indices: [timeAxisID: frame]),
                           label: "Cell", features: [
                            "diameter": cell.diameter,
                            "confidence": cell.confidence,
                           ])
        }
        return WorkspaceLayer(name: "Cells · frame \(frame + 1)", kind: .points,
                              source: .generated(operation: "CellCounter detections"),
                              payload: .points(points), axisIDs: axisIDs,
                              metadata: ["frame": String(frame)])
    }
}
