import Foundation

// MARK: - N-dimensional workspace

nonisolated enum WorkspaceAxisKind: String, Codable, CaseIterable, Sendable {
    case x, y, z, time, channel, other
}

nonisolated struct WorkspaceAxis: Codable, Identifiable, Hashable, Sendable {
    var id: UUID = UUID()
    var name: String
    var kind: WorkspaceAxisKind
    var length: Int
    var unit: String?
    var scale: Double

    init(id: UUID = UUID(), name: String, kind: WorkspaceAxisKind,
         length: Int, unit: String? = nil, scale: Double = 1) {
        self.id = id
        self.name = name
        self.kind = kind
        self.length = max(1, length)
        self.unit = unit
        self.scale = scale.isFinite && scale > 0 ? scale : 1
    }
}

nonisolated struct WorkspacePosition: Codable, Hashable, Sendable {
    var indices: [UUID: Int] = [:]

    subscript(axisID: UUID) -> Int {
        get { indices[axisID, default: 0] }
        set { indices[axisID] = max(0, newValue) }
    }

    func clamped(to axes: [WorkspaceAxis]) -> WorkspacePosition {
        var copy = self
        for axis in axes {
            copy.indices[axis.id] = min(max(0, copy.indices[axis.id, default: 0]), axis.length - 1)
        }
        return copy
    }
}

nonisolated struct WorkspaceCoordinate: Codable, Hashable, Sendable {
    var x: Double
    var y: Double
    var z: Double?

    init(x: Double, y: Double, z: Double? = nil) {
        self.x = x
        self.y = y
        self.z = z
    }
}

/// A deterministic two-dimensional affine transform. Values follow Core Graphics'
/// column-vector convention and are persisted with the workspace.
nonisolated struct WorkspaceAffineTransform: Codable, Hashable, Sendable {
    var a: Double = 1
    var b: Double = 0
    var c: Double = 0
    var d: Double = 1
    var tx: Double = 0
    var ty: Double = 0

    static let identity = WorkspaceAffineTransform()

    static func translation(x: Double, y: Double) -> WorkspaceAffineTransform {
        WorkspaceAffineTransform(tx: x, ty: y)
    }

    func applying(to point: WorkspaceCoordinate) -> WorkspaceCoordinate {
        WorkspaceCoordinate(x: a * point.x + c * point.y + tx,
                            y: b * point.x + d * point.y + ty,
                            z: point.z)
    }

    /// Applies `self`, then `next`.
    func concatenating(_ next: WorkspaceAffineTransform) -> WorkspaceAffineTransform {
        WorkspaceAffineTransform(
            a: next.a * a + next.c * b,
            b: next.b * a + next.d * b,
            c: next.a * c + next.c * d,
            d: next.b * c + next.d * d,
            tx: next.a * tx + next.c * ty + next.tx,
            ty: next.b * tx + next.d * ty + next.ty)
    }

    func inverted() -> WorkspaceAffineTransform? {
        let determinant = a * d - b * c
        guard determinant.isFinite, abs(determinant) > 1e-12 else { return nil }
        let inverse = 1 / determinant
        return WorkspaceAffineTransform(
            a: d * inverse, b: -b * inverse,
            c: -c * inverse, d: a * inverse,
            tx: (c * ty - d * tx) * inverse,
            ty: (b * tx - a * ty) * inverse)
    }
}

nonisolated enum WorkspaceLayerKind: String, Codable, CaseIterable, Sendable {
    case image, labels, points, shapes, surface, tracks

    var displayName: String {
        switch self {
        case .image: return "Image"
        case .labels: return "Labels"
        case .points: return "Points"
        case .shapes: return "Shapes"
        case .surface: return "Surface"
        case .tracks: return "Tracks"
        }
    }
}

nonisolated enum WorkspaceBlendMode: String, Codable, CaseIterable, Sendable {
    case normal, additive, multiply, screen, difference
}

nonisolated enum WorkspaceLayerSource: Codable, Hashable, Sendable {
    case localFile(bookmarkID: UUID?, displayName: String)
    case omeZarr(rootName: String, arrayPath: String, level: Int)
    case generated(operation: String)
    case embedded
}

nonisolated struct WorkspacePoint: Codable, Identifiable, Hashable, Sendable {
    var id: UUID = UUID()
    var coordinate: WorkspaceCoordinate
    var position: WorkspacePosition = WorkspacePosition()
    var label: String?
    var features: [String: Double] = [:]
}

nonisolated enum WorkspaceShapeKind: String, Codable, Sendable {
    case polygon, rectangle, ellipse, line
}

nonisolated struct WorkspaceShape: Codable, Identifiable, Hashable, Sendable {
    var id: UUID = UUID()
    var kind: WorkspaceShapeKind
    var vertices: [WorkspaceCoordinate]
    var position: WorkspacePosition = WorkspacePosition()
    var label: String?
}

nonisolated struct WorkspaceTrackVertex: Codable, Identifiable, Hashable, Sendable {
    var id: UUID = UUID()
    var frame: Int
    var coordinate: WorkspaceCoordinate
    var features: [String: Double] = [:]
}

nonisolated struct WorkspaceTrack: Codable, Identifiable, Hashable, Sendable {
    var id: UUID = UUID()
    var name: String
    var vertices: [WorkspaceTrackVertex]
}

nonisolated struct WorkspaceSurface: Codable, Hashable, Sendable {
    var vertices: [WorkspaceCoordinate]
    /// Zero-based triangle indices; every value must address `vertices`.
    var triangles: [[Int]]
}

nonisolated enum WorkspaceLayerPayload: Codable, Hashable, Sendable {
    case raster
    case points([WorkspacePoint])
    case shapes([WorkspaceShape])
    case tracks([WorkspaceTrack])
    case surface(WorkspaceSurface)
}

nonisolated struct WorkspaceLayer: Codable, Identifiable, Hashable, Sendable {
    var id: UUID = UUID()
    var name: String
    var kind: WorkspaceLayerKind
    var source: WorkspaceLayerSource
    var payload: WorkspaceLayerPayload
    var axisIDs: [UUID]
    var isVisible: Bool = true
    var opacity: Double = 1
    var blendMode: WorkspaceBlendMode = .normal
    var transform: WorkspaceAffineTransform = .identity
    var metadata: [String: String] = [:]

    mutating func normalize() {
        opacity = min(max(opacity.isFinite ? opacity : 1, 0), 1)
    }
}

// MARK: - Plates and fields

nonisolated struct WorkspaceField: Codable, Identifiable, Hashable, Sendable {
    var id: UUID = UUID()
    var name: String
    var path: String
    var layerIDs: [UUID] = []
}

nonisolated struct WorkspaceWell: Codable, Identifiable, Hashable, Sendable {
    var id: UUID = UUID()
    var row: Int
    var column: Int
    var label: String
    var path: String
    var fields: [WorkspaceField] = []
}

nonisolated struct WorkspacePlate: Codable, Identifiable, Hashable, Sendable {
    var id: UUID = UUID()
    var name: String
    var rows: [String]
    var columns: [String]
    var wells: [WorkspaceWell]

    func well(row: Int, column: Int) -> WorkspaceWell? {
        wells.first { $0.row == row && $0.column == column }
    }
}

// MARK: - Lineage graph

nonisolated struct WorkspaceLineageNode: Codable, Identifiable, Hashable, Sendable {
    var id: UUID = UUID()
    var frame: Int
    var coordinate: WorkspaceCoordinate
    var sourceCellID: UUID?
    var label: String?
    var features: [String: Double] = [:]
}

nonisolated enum WorkspaceLineageEdgeKind: String, Codable, CaseIterable, Sendable {
    case continuation, gap, division, merge
}

nonisolated struct WorkspaceLineageEdge: Codable, Identifiable, Hashable, Sendable {
    var id: UUID = UUID()
    var parentID: UUID
    var childID: UUID
    var kind: WorkspaceLineageEdgeKind
}

nonisolated enum WorkspaceLineageError: LocalizedError, Equatable {
    case missingNode
    case sameNode
    case invalidTimeOrder
    case duplicateEdge
    case cycle

    var errorDescription: String? {
        switch self {
        case .missingNode: return "Both lineage observations must exist."
        case .sameNode: return "An observation cannot link to itself."
        case .invalidTimeOrder: return "A lineage link must move forward in time."
        case .duplicateEdge: return "This lineage link already exists."
        case .cycle: return "This link would create a lineage cycle."
        }
    }
}

nonisolated struct WorkspaceLineageGraph: Codable, Hashable, Sendable {
    var nodes: [WorkspaceLineageNode] = []
    var edges: [WorkspaceLineageEdge] = []

    mutating func add(_ node: WorkspaceLineageNode) {
        guard !nodes.contains(where: { $0.id == node.id }) else { return }
        nodes.append(node)
    }

    @discardableResult
    mutating func link(parentID: UUID, childID: UUID,
                       kind: WorkspaceLineageEdgeKind = .continuation) throws -> WorkspaceLineageEdge {
        guard parentID != childID else { throw WorkspaceLineageError.sameNode }
        guard let parent = nodes.first(where: { $0.id == parentID }),
              let child = nodes.first(where: { $0.id == childID }) else {
            throw WorkspaceLineageError.missingNode
        }
        guard child.frame > parent.frame else { throw WorkspaceLineageError.invalidTimeOrder }
        guard !edges.contains(where: { $0.parentID == parentID && $0.childID == childID }) else {
            throw WorkspaceLineageError.duplicateEdge
        }
        let edge = WorkspaceLineageEdge(parentID: parentID, childID: childID, kind: kind)
        edges.append(edge)
        if containsCycle() {
            edges.removeAll { $0.id == edge.id }
            throw WorkspaceLineageError.cycle
        }
        return edge
    }

    mutating func unlink(edgeID: UUID) {
        edges.removeAll { $0.id == edgeID }
    }

    mutating func removeNode(_ id: UUID) {
        nodes.removeAll { $0.id == id }
        edges.removeAll { $0.parentID == id || $0.childID == id }
    }

    func parents(of id: UUID) -> [WorkspaceLineageNode] {
        let ids = Set(edges.lazy.filter { $0.childID == id }.map(\.parentID))
        return nodes.filter { ids.contains($0.id) }
    }

    func children(of id: UUID) -> [WorkspaceLineageNode] {
        let ids = Set(edges.lazy.filter { $0.parentID == id }.map(\.childID))
        return nodes.filter { ids.contains($0.id) }
    }

    func validationIssues() -> [String] {
        let ids = Set(nodes.map(\.id))
        var issues: [String] = []
        if ids.count != nodes.count { issues.append("Duplicate observation identifiers") }
        if edges.contains(where: { !ids.contains($0.parentID) || !ids.contains($0.childID) }) {
            issues.append("A lineage link references a missing observation")
        }
        if containsCycle() { issues.append("The lineage contains a cycle") }
        return issues
    }

    private func containsCycle() -> Bool {
        var adjacency: [UUID: [UUID]] = [:]
        for edge in edges { adjacency[edge.parentID, default: []].append(edge.childID) }
        var visiting = Set<UUID>()
        var visited = Set<UUID>()
        func visit(_ id: UUID) -> Bool {
            if visiting.contains(id) { return true }
            if visited.contains(id) { return false }
            visiting.insert(id)
            for child in adjacency[id, default: []] where visit(child) { return true }
            visiting.remove(id)
            visited.insert(id)
            return false
        }
        return nodes.contains { visit($0.id) }
    }
}

// MARK: - Train-by-painting labels

nonisolated struct WorkspaceLabelClass: Codable, Identifiable, Hashable, Sendable {
    var id: UInt16 { value }
    var value: UInt16
    var name: String
    var colorHex: String
}

nonisolated struct WorkspacePaintStroke: Codable, Identifiable, Hashable, Sendable {
    var id: UUID = UUID()
    var classValue: UInt16
    var radiusPx: Double
    var points: [WorkspaceCoordinate]
    var position: WorkspacePosition = WorkspacePosition()
    var erases: Bool = false
}

nonisolated struct WorkspacePaintDocument: Codable, Hashable, Sendable {
    var width: Int
    var height: Int
    var classes: [WorkspaceLabelClass]
    var strokes: [WorkspacePaintStroke] = []

    mutating func append(_ stroke: WorkspacePaintStroke) {
        guard !stroke.points.isEmpty else { return }
        strokes.append(stroke)
    }

    mutating func undo() -> WorkspacePaintStroke? { strokes.popLast() }

    /// Rasterizes strokes into a row-major UInt16 semantic label plane.
    func rasterized(at position: WorkspacePosition = WorkspacePosition()) -> [UInt16] {
        guard width > 0, height > 0 else { return [] }
        var labels = Array(repeating: UInt16(0), count: width * height)
        for stroke in strokes where stroke.position == position {
            let value: UInt16 = stroke.erases ? 0 : stroke.classValue
            let radius = max(0.5, stroke.radiusPx)
            if stroke.points.count == 1 {
                paintDisk(stroke.points[0], radius: radius, value: value, into: &labels)
                continue
            }
            for pair in zip(stroke.points, stroke.points.dropFirst()) {
                let dx = pair.1.x - pair.0.x
                let dy = pair.1.y - pair.0.y
                let distance = hypot(dx, dy)
                let steps = max(1, Int(ceil(distance / max(1, radius * 0.5))))
                for step in 0...steps {
                    let t = Double(step) / Double(steps)
                    paintDisk(WorkspaceCoordinate(x: pair.0.x + dx * t,
                                                  y: pair.0.y + dy * t),
                              radius: radius, value: value, into: &labels)
                }
            }
        }
        return labels
    }

    private func paintDisk(_ point: WorkspaceCoordinate, radius: Double,
                           value: UInt16, into labels: inout [UInt16]) {
        let minX = max(0, Int(floor(point.x - radius)))
        let maxX = min(width - 1, Int(ceil(point.x + radius)))
        let minY = max(0, Int(floor(point.y - radius)))
        let maxY = min(height - 1, Int(ceil(point.y + radius)))
        guard minX <= maxX, minY <= maxY else { return }
        let radiusSquared = radius * radius
        for y in minY...maxY {
            for x in minX...maxX {
                let dx = Double(x) + 0.5 - point.x
                let dy = Double(y) + 0.5 - point.y
                if dx * dx + dy * dy <= radiusSquared { labels[y * width + x] = value }
            }
        }
    }
}

// MARK: - Closed workflows and animation plans

nonisolated enum WorkspaceWorkflowStep: Codable, Hashable, Sendable, Identifiable {
    case setLayerVisibility(id: UUID, visible: Bool)
    case setLayerOpacity(id: UUID, opacity: Double)
    case translateLayer(id: UUID, x: Double, y: Double)
    case register(referenceID: UUID, movingID: UUID, maxShift: Int)
    case stitch(layerIDs: [UUID], columns: Int, overlap: Double, outputName: String)
    case selectAxis(axisID: UUID, index: Int)

    var id: String {
        switch self {
        case .setLayerVisibility(let id, let visible): return "visibility-\(id)-\(visible)"
        case .setLayerOpacity(let id, let opacity): return "opacity-\(id)-\(opacity)"
        case .translateLayer(let id, let x, let y): return "translate-\(id)-\(x)-\(y)"
        case .register(let referenceID, let movingID, let maxShift):
            return "register-\(referenceID)-\(movingID)-\(maxShift)"
        case .stitch(let ids, let columns, let overlap, let name):
            return "stitch-\(ids.map(\.uuidString).joined())-\(columns)-\(overlap)-\(name)"
        case .selectAxis(let axisID, let index): return "axis-\(axisID)-\(index)"
        }
    }

    var title: String {
        switch self {
        case .setLayerVisibility: return "Set layer visibility"
        case .setLayerOpacity: return "Set layer opacity"
        case .translateLayer: return "Translate layer"
        case .register: return "Register layers"
        case .stitch: return "Stitch layers"
        case .selectAxis: return "Select axis position"
        }
    }
}

nonisolated struct WorkspaceWorkflow: Codable, Identifiable, Hashable, Sendable {
    var id: UUID = UUID()
    var name: String
    var createdAt: Date = Date()
    var steps: [WorkspaceWorkflowStep]
}

nonisolated enum WorkspaceAnimationEasing: String, Codable, CaseIterable, Sendable {
    case linear, easeInOut
}

nonisolated struct WorkspaceAnimationKeyframe: Codable, Identifiable, Hashable, Sendable {
    var id: UUID = UUID()
    var timeSeconds: Double
    var position: WorkspacePosition
    var zoom: Double = 1
    var center: WorkspaceCoordinate = WorkspaceCoordinate(x: 0.5, y: 0.5)
    var visibleLayerIDs: Set<UUID> = []
}

nonisolated struct WorkspaceAnimationPlan: Codable, Identifiable, Hashable, Sendable {
    var id: UUID = UUID()
    var name: String
    var framesPerSecond: Int = 12
    var easing: WorkspaceAnimationEasing = .easeInOut
    var keyframes: [WorkspaceAnimationKeyframe]
}

nonisolated struct WorkspaceAnimationFrameState: Hashable, Sendable {
    var frameNumber: Int
    var timeSeconds: Double
    var position: WorkspacePosition
    var zoom: Double
    var center: WorkspaceCoordinate
    var visibleLayerIDs: Set<UUID>
}

// MARK: - Root document

nonisolated struct MicroscopyWorkspace: Codable, Identifiable, Hashable, Sendable {
    static let currentSchemaVersion = 1

    var schemaVersion: Int = currentSchemaVersion
    var id: UUID = UUID()
    var name: String
    var createdAt: Date = Date()
    var modifiedAt: Date = Date()
    var axes: [WorkspaceAxis]
    var position: WorkspacePosition = WorkspacePosition()
    var layers: [WorkspaceLayer] = []
    var plate: WorkspacePlate?
    var lineage: WorkspaceLineageGraph = WorkspaceLineageGraph()
    var paintDocuments: [UUID: WorkspacePaintDocument] = [:]
    var workflows: [WorkspaceWorkflow] = []
    var animationPlans: [WorkspaceAnimationPlan] = []

    init(name: String, axes: [WorkspaceAxis]) {
        self.name = name
        self.axes = axes
        self.position = WorkspacePosition().clamped(to: axes)
    }

    mutating func addLayer(_ layer: WorkspaceLayer) {
        guard !layers.contains(where: { $0.id == layer.id }) else { return }
        var normalized = layer
        normalized.normalize()
        normalized.axisIDs = normalized.axisIDs.filter { id in axes.contains(where: { $0.id == id }) }
        layers.append(normalized)
        modifiedAt = Date()
    }

    mutating func removeLayer(id: UUID) {
        layers.removeAll { $0.id == id }
        paintDocuments[id] = nil
        modifiedAt = Date()
    }

    mutating func updatePosition(axisID: UUID, index: Int) {
        guard let axis = axes.first(where: { $0.id == axisID }) else { return }
        position[axisID] = min(max(0, index), axis.length - 1)
        modifiedAt = Date()
    }

    func validationIssues() -> [String] {
        var issues: [String] = []
        guard schemaVersion == Self.currentSchemaVersion else {
            return ["Unsupported workspace schema version \(schemaVersion)"]
        }
        let axisIDs = Set(axes.map(\.id))
        if axisIDs.count != axes.count { issues.append("Duplicate axis identifiers") }
        if axes.contains(where: { $0.length < 1 || !$0.scale.isFinite || $0.scale <= 0 }) {
            issues.append("Invalid axis size or physical scale")
        }
        let layerIDs = Set(layers.map(\.id))
        if layerIDs.count != layers.count { issues.append("Duplicate layer identifiers") }
        if layers.contains(where: { !Set($0.axisIDs).isSubset(of: axisIDs) }) {
            issues.append("A layer references an unknown axis")
        }
        issues.append(contentsOf: lineage.validationIssues())
        return issues
    }
}
