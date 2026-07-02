import SwiftUI

// MARK: — Splice points
//
// 1. ROI LAYER: in `ResultsView.swift`, inside `RealImageViewer`'s inner ZStack
//    (the one that contains the image + EditableOverlay), layer this view
//    ABOVE the existing EditableOverlay so ROIs draw on top of cells:
//
//        EditableROI(state: state,
//                    image: image,
//                    viewScale: Double(scale),
//                    viewOffset: .zero,
//                    mode: $roiMode)
//
//    `roiMode` is `@State private var roiMode: ROIMode = .off` on ResultsView,
//    threaded down through `ViewerPanel` → `RealImageViewer` as a Binding.
//
// 2. ROI MODE PICKER: splice `ROIModePicker(mode: $roiMode)` into the viewer's
//    top-center controls in `ResultsView.swift` (next to `EditorModeToolbar`
//    inside `ViewerControlsTopCenter`):
//
//        HStack(spacing: 8) {
//            EditorModeToolbar(mode: $editorMode)
//            ROIModePicker(mode: $roiMode)
//        }

enum ROIMode: Hashable {
    case off
    case drawRect
    case drawEllipse
    case drawExcludeRect
    case drawExcludeEllipse

    var isExclude: Bool {
        self == .drawExcludeRect || self == .drawExcludeEllipse
    }
    var isEllipse: Bool {
        self == .drawEllipse || self == .drawExcludeEllipse
    }
    var isActive: Bool { self != .off }
    var kindString: String { isExclude ? "exclude" : "include" }
    var shapeString: String { isEllipse ? "ellipse" : "rect" }
}

/// Overlay that renders ROIs and supports drawing new ones. Operates in
/// source-image pixel coordinates (cells, rois, x/y/w/h all share that space).
struct EditableROI: View {
    @Bindable var state: AppState
    let image: ImageRecord
    /// Source-pixel -> view-point scale factor. View frame is sized externally
    /// to (sourceWidth * viewScale) × (sourceHeight * viewScale).
    var viewScale: Double
    var viewOffset: CGPoint
    @Binding var mode: ROIMode

    @Environment(AppTheme.self) private var theme

    @State private var selectedROIId: UUID? = nil
    @State private var dragStart: CGPoint? = nil
    @State private var dragCurrent: CGPoint? = nil

    private var rois: [ROIRecord] {
        state.repos.rois(for: image.id)
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            existingROIsLayer
            dragPreview
            deleteAffordance
        }
        .contentShape(Rectangle())
        // Bug #12: only intercept gestures when ROI drawing/selection is active.
        // When mode == .off the ROI layer must be fully transparent to input so
        // EditableOverlay's gesture (below it in the ZStack) can fire.
        .allowsHitTesting(mode.isActive || selectedROIId != nil)
        .gesture(mode.isActive || selectedROIId != nil ? primaryGesture : nil)
    }

    // MARK: — Existing ROI rendering

    private var existingROIsLayer: some View {
        Canvas { ctx, _ in
            for roi in rois {
                let rect = viewRect(for: roi)
                let path = roi.shape == "ellipse"
                    ? Path(ellipseIn: rect)
                    : Path(roundedRect: rect, cornerRadius: 2)
                let stroke = roi.kind == "exclude" ? Tokens.danger : theme.accentColor
                let fillOpacity: Double = roi.kind == "exclude" ? 0.10 : 0.06
                let style: StrokeStyle = roi.kind == "exclude"
                    ? StrokeStyle(lineWidth: 1.5, dash: [5, 3])
                    : StrokeStyle(lineWidth: 1.5)
                ctx.fill(path, with: .color(stroke.opacity(fillOpacity)))
                ctx.stroke(path, with: .color(stroke), style: style)

                if roi.id == selectedROIId {
                    let ring = roi.shape == "ellipse"
                        ? Path(ellipseIn: rect.insetBy(dx: -3, dy: -3))
                        : Path(roundedRect: rect.insetBy(dx: -3, dy: -3), cornerRadius: 4)
                    ctx.stroke(ring, with: .color(stroke.opacity(0.5)),
                               style: StrokeStyle(lineWidth: 1.0))
                }
            }
        }
        .allowsHitTesting(false)
    }

    // MARK: — In-progress drag preview

    @ViewBuilder
    private var dragPreview: some View {
        if mode.isActive, let s = dragStart, let c = dragCurrent {
            let rect = CGRect(
                x: min(s.x, c.x), y: min(s.y, c.y),
                width: abs(c.x - s.x), height: abs(c.y - s.y)
            )
            let stroke = mode.isExclude ? Tokens.danger : theme.accentColor
            let style: StrokeStyle = mode.isExclude
                ? StrokeStyle(lineWidth: 1.5, dash: [5, 3])
                : StrokeStyle(lineWidth: 1.5)
            Canvas { ctx, _ in
                let path = mode.isEllipse
                    ? Path(ellipseIn: rect)
                    : Path(roundedRect: rect, cornerRadius: 2)
                ctx.fill(path, with: .color(stroke.opacity(mode.isExclude ? 0.10 : 0.06)))
                ctx.stroke(path, with: .color(stroke), style: style)
            }
            .allowsHitTesting(false)
        }
    }

    // MARK: — Delete (×) button for selection

    @ViewBuilder
    private var deleteAffordance: some View {
        if let id = selectedROIId, let roi = rois.first(where: { $0.id == id }) {
            let rect = viewRect(for: roi)
            Button {
                state.repos.deleteROI(roi)
                selectedROIId = nil
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(.white, Tokens.danger)
                    .background(
                        Circle().fill(.white).padding(2)
                    )
            }
            .buttonStyle(.plain)
            .position(x: rect.maxX + 12, y: rect.minY - 2)
        }
    }

    // MARK: — Gestures

    private var primaryGesture: some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { v in
                if mode.isActive {
                    if dragStart == nil {
                        // Begin drawing on first changed event so we capture the start.
                        if !hitTestExistingROI(at: v.startLocation) {
                            dragStart = v.startLocation
                        }
                    }
                    if dragStart != nil { dragCurrent = v.location }
                }
            }
            .onEnded { v in
                if mode.isActive, let s = dragStart {
                    let c = v.location
                    let dx = abs(c.x - s.x)
                    let dy = abs(c.y - s.y)
                    if dx >= 6, dy >= 6 {
                        createROI(from: s, to: c)
                    } else {
                        // Treat as a tap — try to select an existing ROI.
                        handleTap(at: v.startLocation)
                    }
                } else {
                    handleTap(at: v.startLocation)
                }
                dragStart = nil
                dragCurrent = nil
            }
    }

    private func handleTap(at p: CGPoint) {
        if let id = hitTestROIId(at: p) {
            selectedROIId = (selectedROIId == id) ? nil : id
        } else {
            selectedROIId = nil
        }
    }

    private func hitTestExistingROI(at p: CGPoint) -> Bool {
        hitTestROIId(at: p) != nil
    }

    private func hitTestROIId(at p: CGPoint) -> UUID? {
        // Source-pixel space hit test (newer ROIs on top).
        let scale = max(viewScale, 0.0001)
        let sx = (p.x - viewOffset.x) / scale
        let sy = (p.y - viewOffset.y) / scale
        for roi in rois.reversed() {
            if ROIFilter.contains(roi: roi, x: Double(sx), y: Double(sy)) {
                return roi.id
            }
        }
        return nil
    }

    private func createROI(from s: CGPoint, to c: CGPoint) {
        let scale = max(viewScale, 0.0001)
        let x0 = (min(s.x, c.x) - viewOffset.x) / scale
        let y0 = (min(s.y, c.y) - viewOffset.y) / scale
        let w = abs(c.x - s.x) / scale
        let h = abs(c.y - s.y) / scale
        let roi = ROIRecord(
            imageId: image.id,
            kind: mode.kindString,
            shape: mode.shapeString,
            x: Double(x0), y: Double(y0),
            width: Double(w), height: Double(h)
        )
        state.repos.save(roi, on: image)
    }

    private func viewRect(for roi: ROIRecord) -> CGRect {
        CGRect(
            x: roi.x * viewScale + Double(viewOffset.x),
            y: roi.y * viewScale + Double(viewOffset.y),
            width: roi.width * viewScale,
            height: roi.height * viewScale
        )
    }
}

// MARK: — ROI mode picker (segmented control)
//
// Splice into the viewer's top-center controls. See splice notes at top of file.

struct ROIModePicker: View {
    @Binding var mode: ROIMode

    @Environment(AppTheme.self) private var theme

    private struct Item: Identifiable {
        let id: ROIMode
        let icon: String
        let label: String
    }

    private var items: [Item] {
        [
            .init(id: .drawRect,         icon: "square.dashed",              label: "Include rectangle"),
            .init(id: .drawEllipse,      icon: "oval.portrait.fill",         label: "Include ellipse"),
            .init(id: .drawExcludeRect,  icon: "rectangle.slash",            label: "Exclude rectangle"),
            .init(id: .drawExcludeEllipse, icon: "circle.slash",             label: "Exclude ellipse"),
            .init(id: .off,              icon: "hand.point.up.left",         label: "Off"),
        ]
    }

    var body: some View {
        HStack(spacing: 2) {
            ForEach(items) { item in
                Button {
                    withAnimation(Tokens.Motion.easeFast) {
                        mode = item.id
                    }
                } label: {
                    Image(systemName: item.icon)
                        .font(.system(size: 12, weight: .medium))
                        .frame(width: 28, height: 28)
                        .foregroundStyle(foreground(for: item.id))
                        .background(
                            RoundedRectangle(cornerRadius: Tokens.Radius.sm)
                                .fill(background(for: item.id))
                        )
                }
                .buttonStyle(.plain)
                .help(item.label)
            }
        }
        .padding(4)
        .background(
            RoundedRectangle(cornerRadius: Tokens.Radius.md)
                .fill(Tokens.bgToolbar)
                .overlay(
                    RoundedRectangle(cornerRadius: Tokens.Radius.md)
                        .strokeBorder(Tokens.border, lineWidth: 0.5)
                )
        )
        .shadow(color: .black.opacity(0.06), radius: 2, y: 1)
    }

    private func foreground(for item: ROIMode) -> Color {
        guard mode == item else { return Tokens.textSecondary }
        return item.isExclude ? Tokens.danger : theme.accentColor
    }

    private func background(for item: ROIMode) -> Color {
        guard mode == item else { return .clear }
        return item.isExclude
            ? Tokens.danger.opacity(0.12)
            : theme.accentSofter
    }
}
