import SwiftUI
import AppKit

/// Both panes use one source-pixel center and zoom, so dragging either pane
/// inspects exactly the same location in the other. Paths are built once per
/// mask revision and culled against the visible source rectangle when drawing.
struct VariantComparisonView: View {
    @Bindable var state: AppState
    let image: ImageRecord
    let variant: SegmentationVariantRecord
    let onApply: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var loadedImage: NSImage?
    @State private var savedPaths: [ComparisonMaskPath] = []
    @State private var currentPaths: [ComparisonMaskPath] = []
    @State private var comparison = VariantMaskComparison()
    @State private var zoom = 1.0
    @State private var center = CGPoint(x: 0.5, y: 0.5)
    @State private var differencesOnly = false
    @State private var loading = true
    @State private var failure: String?
    @State private var loadedRevision: Int?

    var body: some View {
        VStack(spacing: 14) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Compare saved masks").font(.system(size: 18, weight: .semibold))
                    Text(image.fileName).font(.system(size: 11)).foregroundStyle(Tokens.textTertiary)
                }
                Spacer()
                Button("Close") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            HStack(spacing: 14) {
                legend("\(comparison.added.count) added", color: .green)
                legend("\(comparison.removed.count) removed", color: .red)
                legend("\(comparison.changedCurrent.count) changed", color: .orange)
                legend("\(comparison.unchangedCurrent.count) unchanged", color: .cyan)
                Spacer()
                Toggle("Differences only", isOn: $differencesOnly).toggleStyle(.checkbox)
            }.font(.system(size: 11))
            if loading {
                ProgressView("Comparing mask geometry…").frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let failure {
                Text(failure).foregroundStyle(Tokens.danger).frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                HStack(spacing: 10) {
                    pane(title: "Saved · \(variant.label)", paths: savedPaths)
                    pane(title: "Current", paths: currentPaths)
                }
            }
            HStack(spacing: 10) {
                Text("Drag either image to pan both")
                Spacer()
                Button("−") { zoom = max(1, zoom / 1.3) }
                Text(String(format: "%.1f×", zoom)).monospacedDigit().frame(width: 36)
                Button("+") { zoom = min(12, zoom * 1.3) }
                Button("Fit") { zoom = 1; center = CGPoint(x: 0.5, y: 0.5) }
                Button("Use saved variant") { onApply(); dismiss() }
                    .appButton(.primary, size: .sm)
                    .disabled(loading || failure != nil || image.detection?.cellsRevision != loadedRevision)
            }.font(.system(size: 11))
            Text("Colors describe changes from Saved to Current. Geometry matches nearby masks across runs; split/merge results may appear as additions or removals. Display uses the same image preview in both panes.")
                .font(.system(size: 10)).foregroundStyle(Tokens.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(20).frame(minWidth: 800, idealWidth: 1000, minHeight: 580, idealHeight: 700)
        .background(Tokens.bg)
        .focusedSceneValue(\.cellCounterShortcuts, comparisonShortcuts)
        .task(id: "\(image.detection?.id.uuidString ?? "none")-\(image.detection?.cellsRevision ?? -1)") { await load() }
    }

    private var comparisonShortcuts: ScreenShortcutActions {
        var actions = ScreenShortcutActions()
        actions.zoomIn = { zoom = min(12, zoom * 1.3) }
        actions.zoomOut = { zoom = max(1, zoom / 1.3) }
        actions.fit = { zoom = 1; center = CGPoint(x: 0.5, y: 0.5) }
        actions.cancel = { dismiss() }
        actions.isModalContext = true
        return actions
    }

    private func legend(_ text: String, color: Color) -> some View {
        HStack(spacing: 4) { Circle().fill(color).frame(width: 7, height: 7); Text(text) }
    }

    private func pane(title: String, paths: [ComparisonMaskPath]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.system(size: 12, weight: .medium)).lineLimit(1).help(title)
            ComparisonImagePane(image: loadedImage, paths: paths,
                                sourceSize: CGSize(width: max(1, image.widthPx), height: max(1, image.heightPx)),
                                zoom: $zoom, center: $center, differencesOnly: differencesOnly)
        }
    }

    private func load() async {
        loading = true; failure = nil
        let revision = image.detection?.cellsRevision
        let detectionId = image.detection?.id
        let currentData = image.detection?.cellsData
        let savedData = variant.cellsData
        let imageURL = image.displayURL
        guard let currentData else { loading = false; failure = "This image has no current detection to compare."; return }
        let payload = await Task.detached(priority: .userInitiated) {
            let saved = DetectionRecord.decodeCellsData(savedData)
            let current = DetectionRecord.decodeCellsData(currentData)
            return (saved, current, VariantMaskComparison.compare(saved: saved, current: current))
        }.value
        guard !Task.isCancelled, image.detection?.cellsRevision == revision,
              image.detection?.id == detectionId else { return }
        comparison = payload.2
        savedPaths = payload.0.map { ComparisonMaskPath(cell: $0,
                                                       color: comparison.removed.contains($0.id) ? .red : comparison.changedSaved.contains($0.id) ? .orange : .cyan,
                                                       changed: !comparison.unchangedSaved.contains($0.id)) }
        currentPaths = payload.1.map { ComparisonMaskPath(cell: $0,
                                                         color: comparison.added.contains($0.id) ? .green : comparison.changedCurrent.contains($0.id) ? .orange : .cyan,
                                                         changed: !comparison.unchangedCurrent.contains($0.id)) }
        loadedImage = await Task.detached(priority: .userInitiated) { NSImage(contentsOf: imageURL) }.value
        guard !Task.isCancelled else { return }
        loadedRevision = revision; loading = false
    }
}

private struct ComparisonMaskPath: Identifiable {
    let id: UUID
    let path: Path
    let bounds: CGRect
    let color: Color
    let changed: Bool

    init(cell: DetectedCell, color: Color, changed: Bool) {
        id = cell.id; self.color = color; self.changed = changed
        bounds = VariantMaskComparison.geometryBounds(cell)
        if let contour = cell.contourPx, contour.count >= 3 {
            path = Path { path in path.addLines(contour); path.closeSubpath() }
        } else { path = Path(ellipseIn: bounds) }
    }
}

private struct ComparisonImagePane: View {
    let image: NSImage?
    let paths: [ComparisonMaskPath]
    let sourceSize: CGSize
    @Binding var zoom: Double
    @Binding var center: CGPoint
    let differencesOnly: Bool
    @State private var dragCenter: CGPoint?
    @State private var pinchStart: Double?

    var body: some View {
        GeometryReader { geometry in
            let size = geometry.size
            let viewport = ReviewViewport(sourceSize: sourceSize, viewSize: size, zoom: zoom, center: center)
            let scale = viewport.scale, offset = viewport.offset
            let visible = viewport.visibleSourceRect
            Canvas { context, _ in
                if let image {
                    context.draw(Image(nsImage: image), in: CGRect(origin: offset,
                                 size: CGSize(width: sourceSize.width * scale, height: sourceSize.height * scale)))
                }
                context.translateBy(x: offset.x, y: offset.y)
                context.scaleBy(x: scale, y: scale)
                for mask in paths where (!differencesOnly || mask.changed) && visible.intersects(mask.bounds) {
                    context.fill(mask.path, with: .color(mask.color.opacity(0.15)))
                    context.stroke(mask.path, with: .color(mask.color), lineWidth: 1.5 / scale)
                }
            }
            .background(Color.black.opacity(0.85))
            .overlay(alignment: .bottomLeading) {
                if image == nil { Text("Image preview unavailable · masks shown in source coordinates")
                        .font(.system(size: 10)).foregroundStyle(.white).padding(8) }
            }
            .contentShape(Rectangle()).clipped()
            .gesture(DragGesture(minimumDistance: 1)
                .onChanged { value in
                    if dragCenter == nil { dragCenter = center }
                    if let origin = dragCenter {
                        center = viewport.centerAfterPan(from: origin, translation: value.translation)
                    }
                }
                .onEnded { _ in dragCenter = nil })
            .simultaneousGesture(MagnificationGesture()
                .onChanged { value in
                    if pinchStart == nil { pinchStart = zoom }
                    zoom = min(12, max(1, (pinchStart ?? zoom) * value))
                }.onEnded { _ in pinchStart = nil })
        }
    }
}
