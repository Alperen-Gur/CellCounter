import AppKit
import SwiftUI

/// Source-grid vector editing shared by measured annotations and layer metadata.
struct WorkspaceGeometryCanvas: View {
    @Binding var points: [[Double]]
    @Binding var selectedVertex: Int?
    let kind: String
    let editVertices: Bool
    let sourceWidth: Int
    let sourceHeight: Int
    let image: NSImage
    @State private var draggedVertex: Int?

    var body: some View {
        GeometryReader { geometry in
            let rect = fittedRect(geometry.size)
            Canvas { context, _ in
                context.draw(Image(nsImage: image), in: rect)
                let vertices = points.map { displayed($0, in: rect) }
                if let first = vertices.first {
                    var path = Path()
                    path.move(to: first)
                    for vertex in vertices.dropFirst() { path.addLine(to: vertex) }
                    if kind == "polygon", vertices.count >= 3 {
                        path.closeSubpath()
                        context.fill(path, with: .color(.yellow.opacity(0.12)))
                    }
                    if ["rectangle", "ellipse"].contains(kind), vertices.count == 2 {
                        let box = CGRect(x: min(vertices[0].x, vertices[1].x), y: min(vertices[0].y, vertices[1].y),
                            width: abs(vertices[1].x - vertices[0].x), height: abs(vertices[1].y - vertices[0].y))
                        path = kind == "ellipse" ? Path(ellipseIn: box) : Path(box)
                    }
                    context.stroke(path, with: .color(.yellow), lineWidth: 2)
                    for (index, vertex) in vertices.enumerated() {
                        let dot = Path(ellipseIn: CGRect(x: vertex.x - 4, y: vertex.y - 4, width: 8, height: 8))
                        context.fill(dot, with: .color(selectedVertex == index ? .white : .yellow))
                    }
                }
            }
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { event in
                    guard editVertices else { return }
                    if draggedVertex == nil {
                        draggedVertex = points.indices.min {
                            distance(displayed(points[$0], in: rect), event.startLocation) <
                                distance(displayed(points[$1], in: rect), event.startLocation)
                        }
                        if let selected = draggedVertex,
                           distance(displayed(points[selected], in: rect), event.startLocation) > 12 {
                            draggedVertex = nil
                        }
                    }
                    if let selected = draggedVertex {
                        selectedVertex = selected
                        points[selected] = source(event.location, in: rect)
                    }
                }
                .onEnded { event in
                    defer { draggedVertex = nil }
                    guard !editVertices, rect.contains(event.location), points.count < 2048 else { return }
                    let point = source(event.location, in: rect)
                    if kind == "point" { points = [point] }
                    else if !["line", "rectangle", "ellipse"].contains(kind) || points.count < 2 { points.append(point) }
                    selectedVertex = points.indices.last
                })
            .accessibilityLabel("Source annotation canvas. Exact vertex coordinates are also available in the controls.")
        }
    }

    private func fittedRect(_ size: CGSize) -> CGRect {
        let scale = min(size.width / Double(sourceWidth), size.height / Double(sourceHeight))
        let width = Double(sourceWidth) * scale, height = Double(sourceHeight) * scale
        return CGRect(x: (size.width - width) / 2, y: (size.height - height) / 2, width: width, height: height)
    }
    private func displayed(_ point: [Double], in rect: CGRect) -> CGPoint {
        CGPoint(x: rect.minX + point[0] / Double(sourceWidth) * rect.width,
                y: rect.minY + point[1] / Double(sourceHeight) * rect.height)
    }
    private func source(_ point: CGPoint, in rect: CGRect) -> [Double] {
        [min(Double(sourceWidth), max(0, (point.x - rect.minX) / rect.width * Double(sourceWidth))),
         min(Double(sourceHeight), max(0, (point.y - rect.minY) / rect.height * Double(sourceHeight)))]
    }
    private func distance(_ first: CGPoint, _ second: CGPoint) -> Double { hypot(first.x - second.x, first.y - second.y) }
}
