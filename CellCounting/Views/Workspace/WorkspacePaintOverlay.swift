import SwiftUI

/// Shared direct manipulation for legacy and canonical journals. This draws a
/// vector preview only; the selected persistence/engine owns scientific labels.
struct WorkspacePaintOverlay: View {
    let imageSize: CGSize
    let strokes: [WorkspacePaintStroke]
    let enabled: Bool
    let classValue: UInt16
    let radius: Double
    let erases: Bool
    var onInteractionChanged: (Bool) -> Void = { _ in }
    let onStroke: ([WorkspaceCoordinate]) -> Void
    @State private var liveStroke: [WorkspaceCoordinate] = []
    @State private var strokeLimitReached = false

    var body: some View {
        GeometryReader { geometry in
            Canvas { context, _ in
                let sx = geometry.size.width / max(1, imageSize.width)
                let sy = geometry.size.height / max(1, imageSize.height)
                for stroke in strokes { draw(stroke.points, radius: stroke.radiusPx,
                    erases: stroke.erases, classValue: stroke.classValue, context: &context, sx: sx, sy: sy) }
                draw(liveStroke, radius: radius, erases: erases, classValue: classValue,
                     context: &context, sx: sx, sy: sy)
            }
            .contentShape(Rectangle())
            .gesture(enabled ? DragGesture(minimumDistance: 0, coordinateSpace: .local)
                .onChanged { value in
                    guard liveStroke.count < 4096 else { strokeLimitReached = true; return }
                    let point = WorkspaceCoordinate(
                        x: min(max(0, value.location.x / max(1, geometry.size.width) * imageSize.width), max(0, imageSize.width - 1)),
                        y: min(max(0, value.location.y / max(1, geometry.size.height) * imageSize.height), max(0, imageSize.height - 1)))
                    if let last = liveStroke.last, hypot(point.x - last.x, point.y - last.y) < max(0.75, radius * 0.08) { return }
                    if liveStroke.isEmpty { onInteractionChanged(true) }
                    liveStroke.append(point)
                }
                .onEnded { _ in
                    let points = liveStroke
                    liveStroke.removeAll(keepingCapacity: true)
                    if !points.isEmpty && !strokeLimitReached { onStroke(points) }
                    strokeLimitReached = false
                    onInteractionChanged(false)
                } : nil)
            .allowsHitTesting(enabled)
            .overlay(alignment: .bottom) {
                if strokeLimitReached { Text("Stroke is too long. Release, then draw shorter strokes; this stroke will not be saved.")
                    .font(.caption).padding(8).background(.regularMaterial).allowsHitTesting(false) }
            }
        }
        .onChange(of: enabled) { _, value in
            if !value { liveStroke.removeAll(); onInteractionChanged(false) }
        }
        .onDisappear { onInteractionChanged(false) }
    }

    private func draw(_ points: [WorkspaceCoordinate], radius: Double, erases: Bool,
                      classValue: UInt16, context: inout GraphicsContext, sx: Double, sy: Double) {
        guard let first = points.first else { return }
        let color: Color = erases ? .white.opacity(0.35) : (classValue == 1 ? .cyan.opacity(0.52) : .orange.opacity(0.52))
        if points.count == 1 {
            context.fill(Path(ellipseIn: CGRect(x: (first.x - radius) * sx, y: (first.y - radius) * sy,
                width: radius * 2 * sx, height: radius * 2 * sy)), with: .color(color))
        } else {
            var path = Path()
            path.move(to: CGPoint(x: first.x * sx, y: first.y * sy))
            for point in points.dropFirst() { path.addLine(to: CGPoint(x: point.x * sx, y: point.y * sy)) }
            context.stroke(path, with: .color(color), style: StrokeStyle(lineWidth: max(1, radius * 2 * sx), lineCap: .round, lineJoin: .round))
        }
    }
}
