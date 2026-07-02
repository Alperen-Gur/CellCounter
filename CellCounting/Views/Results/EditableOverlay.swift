import SwiftUI
import AppKit

/// Interactive overlay sitting on top of the rendered image. Operates entirely in
/// source-pixel coordinates — pass in `viewScale` to map source pixels to view points.
/// Caller decides whether to persist edits (Results) or keep them local (Fine-tune).
struct EditableOverlay: View {
    @Binding var cells: [DetectedCell]
    var pxPerUm: Double
    var thresholds: [Double]
    var overlayMode: OverlayMode
    var uncertaintyThreshold: Double
    /// Source-pixel -> view-point scale factor. View frame should be
    /// (sourceWidth * viewScale) by (sourceHeight * viewScale).
    var viewScale: Double = 1.0
    /// Optional offset into the view's coordinate space.
    var viewOffset: CGPoint = .zero
    /// Reports edits as they happen so the caller can persist or update mirrored state.
    var onEdit: ((EditEvent) -> Void)? = nil
    /// When nil, the view is non-interactive (read-only). When non-nil, edits write through.
    var editorMode: Binding<EditorMode>? = nil
    /// Default marker diameter (µm) for manual-count mode. Bind to AppState.manualMarkerDiameter.
    var manualMarkerDiameter: Double = 20.0
    /// Pass-15 (A2): optional external binding for the multi-selection set so
    /// callers (the toolbar's "delete selection" override) can read/clear it.
    /// When nil, the overlay manages selection in its own @State.
    var externalSelectedCellIds: Binding<Set<UUID>>? = nil

    /// Pass-17 (Lane B): ground-truth annotation points rendered as yellow
    /// crosshairs over the image. The matching `.annotate` editor mode lets
    /// the user click to add / click an existing one to remove via the
    /// callbacks below. When `annotations` is empty AND the callbacks are nil
    /// (the default), the overlay behaves exactly as before — no new chrome.
    var annotations: [GroundTruthAnnotation] = []
    /// Called when the user clicks empty space in `.annotate` mode. Receives
    /// source-pixel coords. Caller persists.
    var onAddAnnotation: ((CGPoint) -> Void)? = nil
    /// Called when the user clicks an existing annotation in `.annotate` mode
    /// (toggle-to-delete behavior).
    var onRemoveAnnotation: ((GroundTruthAnnotation) -> Void)? = nil

    enum EditorMode: String, Hashable, CaseIterable { case view, add, remove, merge, manualCount, annotate }

    enum EditEvent {
        case removed(DetectedCell)
        case added(DetectedCell)
        case merged(removed: [DetectedCell], added: DetectedCell)
        case resized(DetectedCell, oldDiameter: Double)
    }

    /// Source-pixel space.
    fileprivate struct DragSession {
        var start: CGPoint
        var current: CGPoint
        var kind: Kind
        enum Kind {
            case newBox
            case resize(cellId: UUID, corner: Corner, originalDiameter: Double)
        }
        enum Corner { case topLeft, topRight, bottomLeft, bottomRight }
    }

    @State private var selectedCellId: UUID? = nil
    @State private var mergeFirstId: UUID? = nil
    @State private var dragSession: DragSession? = nil

    // Bug #6: undo/redo stacks (capped at 50 entries each)
    @State private var undoStack: [EditEvent] = []
    @State private var redoStack: [EditEvent] = []

    // Pass-14 (F2): Bulk-delete rectangle drag — source-pixel rect being drawn in `.remove` mode.
    @State private var removeRectStart: CGPoint? = nil  // source-pixel space
    @State private var removeRectCurrent: CGPoint? = nil

    // Pass-14 (F2): Right-click freeform draw — captured path points in source-pixel space.
    @State private var freeformPath: [CGPoint] = []
    @State private var freeformActive: Bool = false

    // Pass-15 (A2): multi-selection set for cmd/shift-click + lasso in .view mode.
    // When `externalSelectedCellIds` is non-nil, that binding is the source of truth.
    @State private var internalSelectedCellIds: Set<UUID> = []
    private var selectedCellIds: Set<UUID> {
        get { externalSelectedCellIds?.wrappedValue ?? internalSelectedCellIds }
        nonmutating set {
            if let b = externalSelectedCellIds { b.wrappedValue = newValue }
            else { internalSelectedCellIds = newValue }
        }
    }
    // Anchor for shift-range selection (cell index in cells array at last plain click).
    @State private var selectionAnchorIndex: Int? = nil
    // Pass-15 (A2): selection-rectangle drag in .view mode (source-pixel space).
    @State private var selectRectStart: CGPoint? = nil
    @State private var selectRectCurrent: CGPoint? = nil
    // Whether the current select-rect drag should extend (cmd held at start) or replace.
    @State private var selectRectExtend: Bool = false
    // Snapshot of selection at drag start (for extend-rect mode).
    @State private var selectRectBaseline: Set<UUID> = []

    private var mode: EditorMode { editorMode?.wrappedValue ?? .view }
    private var interactive: Bool { editorMode != nil }

    var body: some View {
        ZStack(alignment: .topLeading) {
            cellsLayer
            multiSelectionHighlight  // Pass-15 (A2): selection set outline overlay
            selectRectOverlay        // Pass-15 (A2): dashed rect for lasso selection
            dragPreview
            removeRectOverlay        // Pass-14 (F2): dashed rect for bulk delete drag
            freeformPathOverlay      // Pass-14 (F2): right-click freeform stroke preview
            annotationsLayer         // Pass-17 (Lane B): yellow crosshairs for ground-truth points
            selectionAffordances
            deleteFloater
            // Pass-14 (F2): invisible NSView that taps into AppKit's right-mouse events.
            if interactive {
                RightClickCatcher(
                    isActive: mode == .add,
                    onBegin: { p in beginFreeform(at: viewToSource(p)) },
                    onChange: { p in updateFreeform(to: viewToSource(p)) },
                    onEnd: { p in endFreeform(at: viewToSource(p)) }
                )
                .allowsHitTesting(mode == .add)
            }
        }
        .contentShape(Rectangle())
        .gesture(interactive ? primaryGesture : nil)
        .focusable(interactive)
        .focusEffectDisabled()
        .onKeyPress(.init("v")) { setMode(.view); return .handled }
        .onKeyPress(.init("a")) { setMode(.add); return .handled }
        .onKeyPress(.init("r")) { setMode(.remove); return .handled }
        .onKeyPress(.init("m")) { setMode(.merge); return .handled }
        .onKeyPress(.init("c")) { setMode(.manualCount); return .handled }
        // Pass-17 (Lane B): "g" for ground-truth annotation mode.
        .onKeyPress(.init("g")) { setMode(.annotate); return .handled }
        // Bug #6 / Pass-15 (A2): Delete / Backspace — remove selection (multi or single)
        .onKeyPress(.delete) {
            guard interactive else { return .ignored }
            return performDeleteFromKeyboard()
        }
        .onKeyPress(.deleteForward) {
            guard interactive else { return .ignored }
            return performDeleteFromKeyboard()
        }
        // Bug #6: Escape — clear selection + reset to view mode
        .onKeyPress(.escape) {
            guard interactive else { return .ignored }
            selectedCellId = nil
            selectedCellIds.removeAll()
            selectionAnchorIndex = nil
            mergeFirstId = nil
            dragSession = nil
            setMode(.view)
            return .handled
        }
        // Bug #6: Cmd+Z undo, Cmd+Shift+Z redo
        .onKeyPress(keys: [.init("z")]) { press in
            guard interactive else { return .ignored }
            if press.modifiers.contains(.command) && press.modifiers.contains(.shift) {
                performRedo()
                return .handled
            } else if press.modifiers.contains(.command) {
                performUndo()
                return .handled
            }
            return .ignored
        }
        .onKeyPress(keys: [.init("y")]) { press in
            guard interactive, press.modifiers.contains(.command) else { return .ignored }
            performRedo()
            return .handled
        }
        .onHover { inside in
            // Pass-17 (Lane B): annotate mode also wants a crosshair cursor —
            // it's the same "you are about to place a point" affordance.
            if inside && (mode == .manualCount || mode == .annotate) {
                NSCursor.crosshair.push()
            } else {
                NSCursor.pop()
            }
        }
        .onChange(of: mode) { _, newMode in
            // If mode changes while hovering, update cursor immediately.
            if newMode != .manualCount && newMode != .annotate {
                NSCursor.pop()
            }
        }
    }

    // MARK: — Cell rendering (Canvas) — non-hit-testing layer

    /// Fixed visual radius (in points) for manual count markers — independent of cell diameter.
    private static let manualMarkerRadius: Double = 7.0  // 14pt diameter

    private var cellsLayer: some View {
        Canvas { ctx, _ in
            var manualSequence = 0
            for c in cells {
                let isManual = c.isManual
                let r = (c.diameterPx * viewScale) / 2
                let cxv = c.cx * viewScale + viewOffset.x
                let cyv = c.cy * viewScale + viewOffset.y
                let rect = CGRect(x: cxv - r, y: cyv - r, width: r * 2, height: r * 2)

                if isManual {
                    // Manual marker: fixed 14pt pin — small circle with sequential number.
                    // Visual size is FIXED regardless of cell diameter (diameter still used for stats).
                    manualSequence += 1
                    let mr = Self.manualMarkerRadius
                    let pinRect = CGRect(x: cxv - mr, y: cyv - mr, width: mr * 2, height: mr * 2)
                    let circlePath = Path(ellipseIn: pinRect)
                    ctx.fill(circlePath, with: .color(.accentColor))
                    ctx.stroke(circlePath, with: .color(.white), style: StrokeStyle(lineWidth: 1.5))

                    // Draw sequential number centered inside the pin
                    let label = "\(manualSequence)"
                    let resolved = ctx.resolve(
                        Text(label)
                            .font(.system(size: 9, weight: .bold, design: .monospaced))
                            .foregroundColor(.white)
                    )
                    let textSize = resolved.measure(in: CGSize(width: 28, height: 20))
                    ctx.draw(resolved, at: CGPoint(x: cxv - textSize.width / 2,
                                                   y: cyv - textSize.height / 2))
                } else {
                    // Standard ML-detected cell rendering
                    let idx = BinMath.binIndex(for: c.diameter, thresholds: thresholds)
                    let col = Tokens.binColor(idx)
                    let isUncertain = c.confidence < uncertaintyThreshold

                    if let contour = c.contourPx, contour.count >= 3 {
                        // Pass-14: paint the per-cell mask as a filled polygon
                        // in the bin color. Independent of OverlayMode — whenever
                        // contour data is present we use it.
                        var poly = Path()
                        let first = contour[0]
                        poly.move(to: CGPoint(
                            x: first.x * viewScale + viewOffset.x,
                            y: first.y * viewScale + viewOffset.y))
                        for i in 1..<contour.count {
                            let p = contour[i]
                            poly.addLine(to: CGPoint(
                                x: p.x * viewScale + viewOffset.x,
                                y: p.y * viewScale + viewOffset.y))
                        }
                        poly.closeSubpath()
                        ctx.fill(poly, with: .color(col.opacity(0.25)))
                        let style: StrokeStyle = isUncertain
                            ? StrokeStyle(lineWidth: 1, dash: [3.5, 3])
                            : StrokeStyle(lineWidth: 1)
                        ctx.stroke(poly, with: .color(col), style: style)
                    } else {
                        let path = overlayMode == .outline
                            ? Path(ellipseIn: rect)
                            : Path(roundedRect: rect, cornerRadius: 2)
                        ctx.fill(path, with: .color(col.opacity(overlayMode == .outline ? 0.18 : 0.10)))
                        let style: StrokeStyle = isUncertain
                            ? StrokeStyle(lineWidth: 1.5, dash: [3.5, 3])
                            : StrokeStyle(lineWidth: 1.5)
                        ctx.stroke(path, with: .color(col), style: style)
                    }
                }

                let isMergeStaged = (mergeFirstId == c.id)
                let isSelected = (selectedCellId == c.id)
                if isSelected || isMergeStaged {
                    let ringRect = rect.insetBy(dx: -2, dy: -2)
                    let ringPath = overlayMode == .outline
                        ? Path(ellipseIn: ringRect)
                        : Path(roundedRect: ringRect, cornerRadius: 3)
                    ctx.stroke(ringPath,
                               with: .color(isMergeStaged ? Tokens.warning : .accentColor),
                               style: StrokeStyle(lineWidth: 2))
                }
            }
        }
        .allowsHitTesting(false)
    }

    // MARK: — Drag preview (new box being drawn / resize)

    private var dragPreview: some View {
        Group {
            if let s = dragSession {
                switch s.kind {
                case .newBox:
                    let r = currentDragRectView(s)
                    RoundedRectangle(cornerRadius: 2)
                        .strokeBorder(Color.accentColor, style: StrokeStyle(lineWidth: 1.5, dash: [4, 3]))
                        .background(Color.accentColor.opacity(0.08))
                        .frame(width: r.width, height: r.height)
                        .position(x: r.midX, y: r.midY)
                        .allowsHitTesting(false)
                case .resize:
                    // The cell itself is being mutated live in `cells`; nothing extra to draw.
                    Color.clear
                }
            }
        }
    }

    // Pass-14 (F2): Dashed rectangle drawn while user bulk-selects cells in .remove mode.
    private var removeRectOverlay: some View {
        Group {
            if let a = removeRectStart, let b = removeRectCurrent {
                let av = sourceToView(a)
                let bv = sourceToView(b)
                let r = CGRect(x: min(av.x, bv.x), y: min(av.y, bv.y),
                               width: abs(bv.x - av.x), height: abs(bv.y - av.y))
                ZStack {
                    Rectangle()
                        .fill(Tokens.danger.opacity(0.10))
                        .frame(width: r.width, height: r.height)
                        .position(x: r.midX, y: r.midY)
                    RoundedRectangle(cornerRadius: 2)
                        .strokeBorder(Tokens.danger.opacity(0.5),
                                      style: StrokeStyle(lineWidth: 1.5, dash: [5, 3]))
                        .frame(width: r.width, height: r.height)
                        .position(x: r.midX, y: r.midY)

                    // Highlight cells inside the rect (in source space).
                    let srcRect = CGRect(x: min(a.x, b.x), y: min(a.y, b.y),
                                         width: abs(b.x - a.x), height: abs(b.y - a.y))
                    ForEach(cells.filter { srcRect.contains(CGPoint(x: $0.cx, y: $0.cy)) }) { c in
                        let cr = (c.diameterPx * viewScale) / 2
                        let cxv = c.cx * viewScale + viewOffset.x
                        let cyv = c.cy * viewScale + viewOffset.y
                        Rectangle()
                            .fill(Tokens.danger.opacity(0.30))
                            .frame(width: max(cr * 2, 6), height: max(cr * 2, 6))
                            .position(x: cxv, y: cyv)
                    }
                }
                .allowsHitTesting(false)
            }
        }
    }

    // Pass-14 (F2): preview stroke for right-click freeform path.
    private var freeformPathOverlay: some View {
        Group {
            if freeformActive, freeformPath.count > 1 {
                Path { p in
                    let first = sourceToView(freeformPath[0])
                    p.move(to: first)
                    for pt in freeformPath.dropFirst() {
                        p.addLine(to: sourceToView(pt))
                    }
                }
                .stroke(Color.accentColor,
                        style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round, dash: [4, 3]))
                .allowsHitTesting(false)
            }
        }
    }

    private func currentDragRectView(_ s: DragSession) -> CGRect {
        let sx = sourceToView(s.start)
        let cx = sourceToView(s.current)
        let x = min(sx.x, cx.x)
        let y = min(sx.y, cx.y)
        let w = abs(cx.x - sx.x)
        let h = abs(cx.y - sx.y)
        return CGRect(x: x, y: y, width: w, height: h)
    }

    // MARK: — Selection affordances (resize handles)

    private var selectionAffordances: some View {
        Group {
            if let id = selectedCellId, let cell = cells.first(where: { $0.id == id }) {
                let r = (cell.diameterPx * viewScale) / 2
                let cx = cell.cx * viewScale + viewOffset.x
                let cy = cell.cy * viewScale + viewOffset.y
                let rect = CGRect(x: cx - r, y: cy - r, width: r * 2, height: r * 2)
                ForEach(Array(DragSession.Corner.all.enumerated()), id: \.offset) { _, corner in
                    handleView()
                        .position(handlePosition(for: corner, in: rect))
                        .gesture(handleGesture(for: cell, corner: corner))
                }
            }
        }
    }

    private func handleView() -> some View {
        Rectangle()
            .fill(Color.white)
            .frame(width: 8, height: 8)
            .overlay(Rectangle().strokeBorder(Color.accentColor, lineWidth: 1))
    }

    private func handlePosition(for corner: DragSession.Corner, in rect: CGRect) -> CGPoint {
        switch corner {
        case .topLeft: return CGPoint(x: rect.minX, y: rect.minY)
        case .topRight: return CGPoint(x: rect.maxX, y: rect.minY)
        case .bottomLeft: return CGPoint(x: rect.minX, y: rect.maxY)
        case .bottomRight: return CGPoint(x: rect.maxX, y: rect.maxY)
        }
    }

    private func handleGesture(for cell: DetectedCell, corner: DragSession.Corner) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                let cur = viewToSource(value.location)
                if dragSession == nil {
                    dragSession = DragSession(
                        start: viewToSource(value.startLocation),
                        current: cur,
                        kind: .resize(cellId: cell.id, corner: corner, originalDiameter: cell.diameter)
                    )
                }
                applyResize(cell: cell, corner: corner, to: cur)
            }
            .onEnded { value in
                applyResize(cell: cell, corner: corner, to: viewToSource(value.location))
                if let updated = cells.first(where: { $0.id == cell.id }) {
                    onEdit?(.resized(updated, oldDiameter: cell.diameter))
                }
                dragSession = nil
            }
    }

    private func applyResize(cell: DetectedCell, corner _: DragSession.Corner, to point: CGPoint) {
        guard let i = cells.firstIndex(where: { $0.id == cell.id }) else { return }
        let dx = point.x - cell.cx
        let dy = point.y - cell.cy
        let newRadiusPx = max(4, hypot(dx, dy))
        let newDiameterPx = newRadiusPx * 2
        let newDiameterUm = pxPerUm > 0 ? newDiameterPx / pxPerUm : cell.diameter
        cells[i].diameterPx = newDiameterPx
        cells[i].diameter = newDiameterUm
    }

    // MARK: — Floating delete button next to selected cell

    @ViewBuilder
    private var deleteFloater: some View {
        if interactive,
           mode != .merge,
           let id = selectedCellId,
           let cell = cells.first(where: { $0.id == id }) {
            let r = (cell.diameterPx * viewScale) / 2
            let cx = cell.cx * viewScale + viewOffset.x
            let cy = cell.cy * viewScale + viewOffset.y
            Button {
                removeCell(id: id, emit: true)
            } label: {
                ZStack {
                    Circle().fill(Tokens.danger)
                    Image(systemName: "xmark")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(.white)
                }
                .frame(width: 22, height: 22)
                .shadow(color: .black.opacity(0.25), radius: 3, y: 1)
            }
            .buttonStyle(.plain)
            .position(x: cx + r + 14, y: cy - r - 4)
        }
    }

    // MARK: — Primary gesture (capture clicks + drags on the whole overlay)

    private var primaryGesture: some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                handleDragChanged(start: value.startLocation, current: value.location)
            }
            .onEnded { value in
                handleDragEnded(start: value.startLocation, end: value.location, translation: value.translation)
            }
    }

    private func handleDragChanged(start: CGPoint, current: CGPoint) {
        let dist = hypot(current.x - start.x, current.y - start.y)

        // Pass-14 (F2): bulk-delete rectangle drag in .remove mode.
        // Differentiate click vs drag at distance >= 6.
        if mode == .remove {
            if dist >= 6 {
                if removeRectStart == nil {
                    removeRectStart = viewToSource(start)
                }
                removeRectCurrent = viewToSource(current)
            }
            return
        }

        // Pass-15 (A2): lasso-rectangle drag in .view mode.
        if mode == .view {
            if dist >= 6 {
                if selectRectStart == nil {
                    selectRectStart = viewToSource(start)
                    // Snapshot modifiers + baseline selection at drag start.
                    let mods = NSApp.currentEvent?.modifierFlags ?? []
                    selectRectExtend = mods.contains(.command)
                    selectRectBaseline = selectRectExtend ? selectedCellIds : []
                }
                selectRectCurrent = viewToSource(current)
                updateSelectionFromRect()
            }
            return
        }

        // Only initiate "new box" drag when in add mode AND drag exceeds tap threshold.
        guard dist > 4 else { return }
        if dragSession == nil {
            if mode == .add {
                if hitTest(at: viewToSource(start)) == nil {
                    dragSession = DragSession(
                        start: viewToSource(start),
                        current: viewToSource(current),
                        kind: .newBox
                    )
                }
            }
        } else if case .newBox = dragSession?.kind {
            dragSession?.current = viewToSource(current)
        }
    }

    // Pass-15 (A2): recompute selection from in-flight lasso rect.
    private func updateSelectionFromRect() {
        guard let a = selectRectStart, let b = selectRectCurrent else { return }
        let r = CGRect(x: min(a.x, b.x), y: min(a.y, b.y),
                       width: abs(b.x - a.x), height: abs(b.y - a.y))
        let inside = cells.filter { r.contains(CGPoint(x: $0.cx, y: $0.cy)) }.map(\.id)
        if selectRectExtend {
            selectedCellIds = selectRectBaseline.union(inside)
        } else {
            selectedCellIds = Set(inside)
        }
    }

    private func handleDragEnded(start: CGPoint, end: CGPoint, translation: CGSize) {
        let dist = hypot(translation.width, translation.height)
        defer {
            dragSession = nil
            removeRectStart = nil
            removeRectCurrent = nil
            selectRectStart = nil
            selectRectCurrent = nil
            selectRectBaseline = []
            selectRectExtend = false
        }

        // Pass-14 (F2): handle bulk-delete drag end.
        if mode == .remove {
            if dist >= 6, let a = removeRectStart {
                let b = removeRectCurrent ?? viewToSource(end)
                bulkDeleteCellsInRect(from: a, to: b)
                return
            }
            // Fall through to click path for short drags / pure clicks.
        }

        // Pass-15 (A2): finalize lasso selection in .view mode.
        if mode == .view, dist >= 6, selectRectStart != nil {
            updateSelectionFromRect()
            // Drop single-cell selectedCellId if multi-set is now active so
            // ring + handles defer to multiSelectionHighlight.
            if !selectedCellIds.isEmpty {
                selectedCellId = nil
            }
            return
        }

        if dist < 5 {
            // Treat as click.
            handleClick(at: viewToSource(end))
            return
        }
        // Drag finished — finalize newBox if any.
        if let s = dragSession, case .newBox = s.kind {
            finalizeNewBox(from: s.start, to: viewToSource(end))
        }
    }

    // Pass-14 (F2): delete every cell whose centroid is inside the rect, in one batch.
    private func bulkDeleteCellsInRect(from a: CGPoint, to b: CGPoint) {
        let r = CGRect(
            x: min(a.x, b.x),
            y: min(a.y, b.y),
            width: abs(b.x - a.x),
            height: abs(b.y - a.y)
        )
        guard r.width > 1 && r.height > 1 else { return }
        let victims = cells.filter { r.contains(CGPoint(x: $0.cx, y: $0.cy)) }
        guard !victims.isEmpty else { return }
        for c in victims {
            removeCell(id: c.id, emit: true)
        }
    }

    private func handleClick(at p: CGPoint) {
        let hit = hitTest(at: p)
        switch mode {
        case .view:
            // Pass-15 (A2): cmd/shift modifiers drive multi-selection set.
            let mods = NSApp.currentEvent?.modifierFlags ?? []
            handleViewClick(hit: hit, modifiers: mods)
            mergeFirstId = nil
        case .add:
            if let h = hit {
                selectedCellId = h.id
            } else {
                // Single click in add mode = create a small default cell at the point.
                let defaultDiameterUm: Double = 18
                let defaultDiameterPx = defaultDiameterUm * max(pxPerUm, 0.001)
                let new = DetectedCell(
                    cx: p.x,
                    cy: p.y,
                    diameter: defaultDiameterUm,
                    diameterPx: defaultDiameterPx,
                    confidence: 1.0
                )
                cells.append(new)
                selectedCellId = new.id
                pushUndo(.added(new))
                onEdit?(.added(new))
            }
        case .remove:
            if let h = hit {
                removeCell(id: h.id, emit: true)
            }
        case .merge:
            guard let h = hit else { mergeFirstId = nil; return }
            if let first = mergeFirstId, first != h.id,
               let a = cells.first(where: { $0.id == first }),
               let b = cells.first(where: { $0.id == h.id }) {
                mergeCells(a, b)
                mergeFirstId = nil
            } else {
                mergeFirstId = h.id
            }
        case .manualCount:
            // Right-click / Cmd+click removes nearest manual marker; plain click adds one.
            if let h = hit, h.isManual {
                // Remove nearest manual marker on second click on same cell
                removeManualCell(id: h.id)
            } else {
                // Place a new manual marker at the click location
                let diamUm = manualMarkerDiameter
                let diamPx = diamUm * max(pxPerUm, 0.001)
                var new = DetectedCell(
                    cx: p.x,
                    cy: p.y,
                    diameter: diamUm,
                    diameterPx: diamPx,
                    confidence: 1.0
                )
                new.isManual = true
                cells.append(new)
                pushUndo(.added(new))
                onEdit?(.added(new))
            }
        case .annotate:
            // Pass-17 (Lane B): ground-truth annotation placement.
            // First check if the click landed on an existing annotation —
            // toggle-to-delete behavior. Otherwise add a new annotation
            // at the click's source-pixel coords. Detection hit-testing is
            // intentionally NOT used here: annotations live in a separate
            // visual layer and should be independent of cell selection.
            if let existing = annotationHitTest(at: p) {
                onRemoveAnnotation?(existing)
            } else {
                onAddAnnotation?(p)
            }
        }
    }

    private func removeManualCell(id: UUID) {
        removeCell(id: id, emit: true)
    }

    private func finalizeNewBox(from a: CGPoint, to b: CGPoint) {
        let w = abs(b.x - a.x)
        let h = abs(b.y - a.y)
        let side = max(w, h)
        guard side > 2 else { return }
        let cx = (a.x + b.x) / 2
        let cy = (a.y + b.y) / 2
        let diameterPx = side
        let diameterUm = pxPerUm > 0 ? diameterPx / pxPerUm : diameterPx
        let new = DetectedCell(
            cx: cx,
            cy: cy,
            diameter: diameterUm,
            diameterPx: diameterPx,
            confidence: 1.0
        )
        cells.append(new)
        selectedCellId = new.id
        pushUndo(.added(new))
        onEdit?(.added(new))
    }

    private func mergeCells(_ a: DetectedCell, _ b: DetectedCell) {
        let cx = (a.cx + b.cx) / 2
        let cy = (a.cy + b.cy) / 2
        let diam = (a.diameter + b.diameter) / 2
        let diamPx = (a.diameterPx + b.diameterPx) / 2
        let merged = DetectedCell(
            cx: cx, cy: cy,
            diameter: diam, diameterPx: diamPx,
            confidence: max(a.confidence, b.confidence)
        )
        cells.removeAll { $0.id == a.id || $0.id == b.id }
        cells.append(merged)
        selectedCellId = merged.id
        pushUndo(.merged(removed: [a, b], added: merged))
        onEdit?(.merged(removed: [a, b], added: merged))
    }

    private func removeCell(id: UUID, emit: Bool) {
        guard let i = cells.firstIndex(where: { $0.id == id }) else { return }
        let removed = cells.remove(at: i)
        if selectedCellId == id { selectedCellId = nil }
        if mergeFirstId == id { mergeFirstId = nil }
        if emit {
            pushUndo(.removed(removed))
            onEdit?(.removed(removed))
        }
    }

    // Bug #6: called by Delete/Backspace key handler — wraps removeCell with undo
    private func performRemove(id: UUID) {
        removeCell(id: id, emit: true)
    }

    // MARK: — Undo / Redo

    private func pushUndo(_ event: EditEvent) {
        undoStack.append(event)
        if undoStack.count > 50 { undoStack.removeFirst() }
        redoStack.removeAll()  // any new action clears redo history
    }

    private func performUndo() {
        guard let last = undoStack.popLast() else { return }
        switch last {
        case .removed(let c):
            // Re-insert the removed cell
            cells.append(c)
            redoStack.append(.added(c))
            onEdit?(.added(c))
        case .added(let c):
            // Remove the added cell
            guard let i = cells.firstIndex(where: { $0.id == c.id }) else { return }
            cells.remove(at: i)
            if selectedCellId == c.id { selectedCellId = nil }
            redoStack.append(.removed(c))
            onEdit?(.removed(c))
        case .merged(let removedCells, let added):
            // Undo merge: remove the merged result, re-insert originals (best-effort)
            if let i = cells.firstIndex(where: { $0.id == added.id }) {
                cells.remove(at: i)
            }
            for c in removedCells { cells.append(c) }
            redoStack.append(last)
            onEdit?(.removed(added))
        case .resized(let c, let oldDiameter):
            guard let i = cells.firstIndex(where: { $0.id == c.id }) else { return }
            let current = cells[i]
            let oldDiamPx = pxPerUm > 0 ? oldDiameter * pxPerUm : oldDiameter
            cells[i].diameter = oldDiameter
            cells[i].diameterPx = oldDiamPx
            redoStack.append(.resized(current, oldDiameter: oldDiameter))
            onEdit?(.resized(cells[i], oldDiameter: current.diameter))
        }
        if redoStack.count > 50 { redoStack.removeFirst() }
    }

    private func performRedo() {
        guard let last = redoStack.popLast() else { return }
        switch last {
        case .added(let c):
            cells.append(c)
            undoStack.append(.added(c))
            onEdit?(.added(c))
        case .removed(let c):
            guard let i = cells.firstIndex(where: { $0.id == c.id }) else { return }
            cells.remove(at: i)
            if selectedCellId == c.id { selectedCellId = nil }
            undoStack.append(.removed(c))
            onEdit?(.removed(c))
        case .merged(let removedCells, let added):
            for c in removedCells {
                if let i = cells.firstIndex(where: { $0.id == c.id }) { cells.remove(at: i) }
            }
            cells.append(added)
            undoStack.append(last)
            onEdit?(.merged(removed: removedCells, added: added))
        case .resized(let c, let oldDiameter):
            guard let i = cells.firstIndex(where: { $0.id == c.id }) else { return }
            let current = cells[i]
            let newDiamPx = pxPerUm > 0 ? c.diameter * pxPerUm : c.diameter
            cells[i].diameter = c.diameter
            cells[i].diameterPx = newDiamPx
            undoStack.append(.resized(current, oldDiameter: oldDiameter))
            onEdit?(.resized(cells[i], oldDiameter: current.diameter))
        }
        if undoStack.count > 50 { undoStack.removeFirst() }
    }

    private func hitTest(at p: CGPoint) -> DetectedCell? {
        // Iterate in reverse so latest-drawn cell wins on overlap.
        for c in cells.reversed() {
            let dx = p.x - c.cx
            let dy = p.y - c.cy
            if c.isManual {
                // Manual markers are fixed 14pt circles in view-space; convert back to source pixels.
                let hitRadiusSrc = Self.manualMarkerRadius / max(viewScale, 0.0001)
                if (dx * dx + dy * dy) <= hitRadiusSrc * hitRadiusSrc { return c }
            } else if let contour = c.contourPx, contour.count >= 3 {
                // Pass-14: point-in-polygon when contour data is present so
                // selection matches the filled shape rather than the bbox.
                if Self.pointInPolygon(p, polygon: contour) { return c }
            } else {
                let r = c.diameterPx / 2
                if overlayMode == .outline {
                    if (dx * dx + dy * dy) <= r * r { return c }
                } else {
                    if abs(dx) <= r && abs(dy) <= r { return c }
                }
            }
        }
        return nil
    }

    /// Ray-casting point-in-polygon test. Polygon vertices and `p` are both
    /// expected to be in source-image-pixel coordinates.
    private static func pointInPolygon(_ p: CGPoint, polygon: [CGPoint]) -> Bool {
        guard polygon.count >= 3 else { return false }
        var inside = false
        var j = polygon.count - 1
        for i in 0..<polygon.count {
            let pi = polygon[i]
            let pj = polygon[j]
            if ((pi.y > p.y) != (pj.y > p.y)) {
                let denom = pj.y - pi.y
                if denom != 0 {
                    let xIntersect = (pj.x - pi.x) * (p.y - pi.y) / denom + pi.x
                    if p.x < xIntersect { inside.toggle() }
                }
            }
            j = i
        }
        return inside
    }

    // MARK: — Coordinate helpers

    private func viewToSource(_ p: CGPoint) -> CGPoint {
        let s = max(viewScale, 0.0001)
        return CGPoint(x: (p.x - viewOffset.x) / s,
                       y: (p.y - viewOffset.y) / s)
    }
    private func sourceToView(_ p: CGPoint) -> CGPoint {
        CGPoint(x: p.x * viewScale + viewOffset.x,
                y: p.y * viewScale + viewOffset.y)
    }

    // MARK: — Pass-14 (F2) freeform draw (right-click)

    private func beginFreeform(at p: CGPoint) {
        // Only in .add mode; ignore otherwise.
        guard mode == .add else { return }
        freeformActive = true
        freeformPath = [p]
    }

    private func updateFreeform(to p: CGPoint) {
        guard freeformActive else { return }
        // Append only if it advances enough to keep the path light.
        if let last = freeformPath.last {
            let dx = p.x - last.x
            let dy = p.y - last.y
            if dx * dx + dy * dy < 1.0 { return }
        }
        freeformPath.append(p)
    }

    private func endFreeform(at p: CGPoint) {
        guard freeformActive else { return }
        defer {
            freeformActive = false
            freeformPath = []
        }
        if freeformPath.last.map({ $0 != p }) ?? true {
            freeformPath.append(p)
        }
        // Need at least 3 points to form a polygon.
        guard freeformPath.count >= 3 else { return }

        // Close the path: if endpoint is near the start (or always — Cellpose semantics close on release).
        var poly = freeformPath
        if let first = poly.first, let last = poly.last, first != last {
            poly.append(first)
        }

        // Compute bounding box and equivalent diameter from area.
        var minX = poly[0].x, maxX = poly[0].x
        var minY = poly[0].y, maxY = poly[0].y
        for pt in poly {
            if pt.x < minX { minX = pt.x }
            if pt.x > maxX { maxX = pt.x }
            if pt.y < minY { minY = pt.y }
            if pt.y > maxY { maxY = pt.y }
        }
        let w = maxX - minX
        let h = maxY - minY
        guard w > 2 && h > 2 else { return }

        let cx = (minX + maxX) / 2
        let cy = (minY + maxY) / 2

        // Equivalent-circle diameter from polygon area (shoelace).
        let area = abs(polygonAreaShoelace(poly))
        let equivDiameterPx: Double
        if area > 1 {
            equivDiameterPx = 2.0 * sqrt(area / .pi)
        } else {
            equivDiameterPx = max(w, h)
        }
        let diameterUm = pxPerUm > 0 ? equivDiameterPx / pxPerUm : equivDiameterPx

        var new = DetectedCell(
            cx: cx,
            cy: cy,
            diameter: diameterUm,
            diameterPx: equivDiameterPx,
            confidence: 1.0
        )
        // Pass-14 (F2): hand the drawn polygon to F1's contour field. The renderer
        // picks this up and fills the cell with the bin color outline.
        new.contourPx = poly
        cells.append(new)
        selectedCellId = new.id
        pushUndo(.added(new))
        onEdit?(.added(new))
    }

    private func polygonAreaShoelace(_ pts: [CGPoint]) -> Double {
        guard pts.count >= 3 else { return 0 }
        var sum: Double = 0
        for i in 0..<pts.count {
            let j = (i + 1) % pts.count
            sum += pts[i].x * pts[j].y - pts[j].x * pts[i].y
        }
        return sum / 2.0
    }

    private func setMode(_ m: EditorMode) {
        guard let binding = editorMode else { return }
        binding.wrappedValue = m
        if m != .merge { mergeFirstId = nil }
        if m != .view && m != .add { selectedCellId = nil }
        // Pass-15 (A2): leaving .view drops the multi-selection set; entering
        // any other mode means clicks have a different meaning.
        if m != .view {
            selectedCellIds.removeAll()
            selectionAnchorIndex = nil
        }
        // Pass-17 (Lane B): annotate mode never interacts with cells —
        // clear the drag/select state to avoid stray rectangles.
        if m == .annotate {
            dragSession = nil
            removeRectStart = nil
            removeRectCurrent = nil
            selectRectStart = nil
            selectRectCurrent = nil
        }
    }

    // MARK: — Pass-15 (A2) multi-selection

    /// Branch for `.view`-mode clicks that honors cmd/shift modifiers.
    private func handleViewClick(hit: DetectedCell?, modifiers: NSEvent.ModifierFlags) {
        guard let h = hit else {
            // Click on empty space in .view mode clears everything.
            selectedCellId = nil
            selectedCellIds.removeAll()
            selectionAnchorIndex = nil
            return
        }
        let cmd = modifiers.contains(.command)
        let shift = modifiers.contains(.shift)
        let idx = cells.firstIndex(where: { $0.id == h.id })

        if cmd && !shift {
            // Toggle membership in the selection set.
            if selectedCellIds.contains(h.id) {
                selectedCellIds.remove(h.id)
            } else {
                selectedCellIds.insert(h.id)
            }
            selectionAnchorIndex = idx
            // When the multi-set is active, drop the single-cell focus so the
            // resize handles + delete floater don't fight with the highlight.
            selectedCellId = selectedCellIds.count == 1 ? selectedCellIds.first : nil
        } else if shift, let endIdx = idx {
            // Range-add between anchor (or current single-selection) and click,
            // by reading order in the cells array.
            let anchor = selectionAnchorIndex
                ?? (selectedCellId.flatMap { id in cells.firstIndex(where: { $0.id == id }) })
                ?? endIdx
            let lo = min(anchor, endIdx)
            let hi = max(anchor, endIdx)
            for i in lo...hi {
                if cells.indices.contains(i) {
                    selectedCellIds.insert(cells[i].id)
                }
            }
            selectedCellId = nil
        } else {
            // Plain click — replace selection with just this cell.
            selectedCellIds = [h.id]
            selectedCellId = h.id
            selectionAnchorIndex = idx
        }
    }

    /// Returns `.handled` if the keypress consumed a delete-selection action,
    /// otherwise `.ignored` (so caller chain may handle it).
    private func performDeleteFromKeyboard() -> KeyPress.Result {
        // Pass-16: in any mode, prefer the multi-select set if populated; fall
        // back to the single-cell `selectedCellId` (the yellow-handle "this
        // one" selection that the legacy click-to-select path still sets).
        // Without this fallback, a user clicking a cell and pressing Backspace
        // sees nothing happen — exactly the bug the screenshot showed.
        if !selectedCellIds.isEmpty {
            deleteCurrentSelection()
            return .handled
        }
        if let id = selectedCellId {
            performRemove(id: id)
            return .handled
        }
        // Nothing selected — do NOT delete random cells.
        return .ignored
    }

    /// Delete every cell in `selectedCellIds`, emitting one event each so the
    /// existing per-cell undo records the batch in sequence.
    fileprivate func deleteCurrentSelection() {
        guard !selectedCellIds.isEmpty else { return }
        let victims = Array(selectedCellIds)
        for id in victims {
            removeCell(id: id, emit: true)
        }
        selectedCellIds.removeAll()
        selectionAnchorIndex = nil
    }

    /// Painted on top of cellsLayer — does not touch F1/F2's drawing.
    private var multiSelectionHighlight: some View {
        Canvas { ctx, _ in
            guard !selectedCellIds.isEmpty else { return }
            for c in cells where selectedCellIds.contains(c.id) {
                let r = (c.diameterPx * viewScale) / 2
                let cxv = c.cx * viewScale + viewOffset.x
                let cyv = c.cy * viewScale + viewOffset.y
                let rect = CGRect(x: cxv - r, y: cyv - r, width: r * 2, height: r * 2)
                // Yellow inner glow.
                let glowRect = rect.insetBy(dx: -1, dy: -1)
                let glowPath = overlayMode == .outline
                    ? Path(ellipseIn: glowRect)
                    : Path(roundedRect: glowRect, cornerRadius: 3)
                ctx.stroke(glowPath,
                           with: .color(Tokens.warning.opacity(0.85)),
                           style: StrokeStyle(lineWidth: 3.5))
                // White 2px outer stroke.
                let ringRect = rect.insetBy(dx: -3, dy: -3)
                let ringPath = overlayMode == .outline
                    ? Path(ellipseIn: ringRect)
                    : Path(roundedRect: ringRect, cornerRadius: 4)
                ctx.stroke(ringPath,
                           with: .color(.white),
                           style: StrokeStyle(lineWidth: 2))
            }
        }
        .allowsHitTesting(false)
    }

    // MARK: — Pass-17 (Lane B) ground-truth annotations

    /// Visual radius (in points / view-space) of each annotation crosshair.
    /// Independent of cell diameter so a sparse-click workflow stays readable
    /// at any zoom level.
    private static let annotationCrosshairRadius: Double = 6.0

    /// Yellow crosshairs ("+") rendered for every ground-truth annotation.
    /// Sits above the cell layer so it's always visible regardless of which
    /// overlay mode (.bbox/.outline/contour) is active. Uses the same source-
    /// pixel → view-point transform every other layer uses.
    private var annotationsLayer: some View {
        Canvas { ctx, _ in
            guard !annotations.isEmpty else { return }
            let armLen = Self.annotationCrosshairRadius
            // Light translucent halo gives contrast against bright cells too.
            for a in annotations {
                let cxv = a.cx * viewScale + viewOffset.x
                let cyv = a.cy * viewScale + viewOffset.y

                // Soft halo behind the crosshair so the marker stays visible
                // on top of cells of any color.
                let haloRect = CGRect(x: cxv - armLen - 1, y: cyv - armLen - 1,
                                      width: (armLen + 1) * 2, height: (armLen + 1) * 2)
                ctx.fill(Path(ellipseIn: haloRect),
                         with: .color(.black.opacity(0.30)))

                // Crosshair arms.
                var stroke = Path()
                stroke.move(to: CGPoint(x: cxv - armLen, y: cyv))
                stroke.addLine(to: CGPoint(x: cxv + armLen, y: cyv))
                stroke.move(to: CGPoint(x: cxv, y: cyv - armLen))
                stroke.addLine(to: CGPoint(x: cxv, y: cyv + armLen))
                ctx.stroke(stroke,
                           with: .color(Tokens.warning),
                           style: StrokeStyle(lineWidth: 1.8, lineCap: .round))

                // Center dot — small white pip for extra visibility.
                let dot = CGRect(x: cxv - 1.25, y: cyv - 1.25, width: 2.5, height: 2.5)
                ctx.fill(Path(ellipseIn: dot), with: .color(.white))
            }
        }
        .allowsHitTesting(false)
    }

    /// Source-pixel-space hit test against the current annotation set. The
    /// pickable radius is the crosshair arm length expressed back in source
    /// pixels (so the hit area shrinks/grows with zoom in a consistent way),
    /// clamped to a sensible minimum.
    private func annotationHitTest(at p: CGPoint) -> GroundTruthAnnotation? {
        guard !annotations.isEmpty else { return nil }
        let hitRadiusSrc = max(2.0, (Self.annotationCrosshairRadius + 4) / max(viewScale, 0.0001))
        let r2 = hitRadiusSrc * hitRadiusSrc
        // Reverse so the most recently added annotation wins on overlap.
        for a in annotations.reversed() {
            let dx = p.x - a.cx
            let dy = p.y - a.cy
            if dx * dx + dy * dy <= r2 { return a }
        }
        return nil
    }

    /// Dashed selection rectangle drawn while user lasso-selects in `.view` mode.
    private var selectRectOverlay: some View {
        Group {
            if mode == .view, let a = selectRectStart, let b = selectRectCurrent {
                let av = sourceToView(a)
                let bv = sourceToView(b)
                let r = CGRect(x: min(av.x, bv.x), y: min(av.y, bv.y),
                               width: abs(bv.x - av.x), height: abs(bv.y - av.y))
                ZStack {
                    Rectangle()
                        .fill(Color.accentColor.opacity(0.08))
                        .frame(width: r.width, height: r.height)
                        .position(x: r.midX, y: r.midY)
                    RoundedRectangle(cornerRadius: 2)
                        .strokeBorder(Color.accentColor.opacity(0.65),
                                      style: StrokeStyle(lineWidth: 1.5, dash: [5, 3]))
                        .frame(width: r.width, height: r.height)
                        .position(x: r.midX, y: r.midY)
                }
                .allowsHitTesting(false)
            }
        }
    }
}

private extension EditableOverlay.DragSession.Corner {
    static var all: [EditableOverlay.DragSession.Corner] {
        [.topLeft, .topRight, .bottomLeft, .bottomRight]
    }
}

// MARK: — Pass-14 (F2) right-click capture (AppKit bridge)

/// Transparent NSView that captures right-mouse events so SwiftUI gestures —
/// which only see left-button events — don't have to. Emits points in the
/// view's own coordinate space (top-left origin, matching SwiftUI).
private struct RightClickCatcher: NSViewRepresentable {
    var isActive: Bool
    var onBegin: (CGPoint) -> Void
    var onChange: (CGPoint) -> Void
    var onEnd: (CGPoint) -> Void

    func makeNSView(context: Context) -> RightClickCatcherView {
        let v = RightClickCatcherView()
        v.onBegin = onBegin
        v.onChange = onChange
        v.onEnd = onEnd
        v.isActive = isActive
        return v
    }

    func updateNSView(_ nsView: RightClickCatcherView, context: Context) {
        nsView.onBegin = onBegin
        nsView.onChange = onChange
        nsView.onEnd = onEnd
        nsView.isActive = isActive
    }
}

final class RightClickCatcherView: NSView {
    var onBegin: ((CGPoint) -> Void)?
    var onChange: ((CGPoint) -> Void)?
    var onEnd: ((CGPoint) -> Void)?
    var isActive: Bool = true

    override var isFlipped: Bool { true }  // match SwiftUI's top-left origin

    override func hitTest(_ point: NSPoint) -> NSView? {
        // Only consume right-button events; let everything else pass through.
        guard isActive, let event = NSApp.currentEvent else { return nil }
        switch event.type {
        case .rightMouseDown, .rightMouseDragged, .rightMouseUp:
            return self
        default:
            return nil
        }
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func rightMouseDown(with event: NSEvent) {
        guard isActive else {
            super.rightMouseDown(with: event)
            return
        }
        let p = convert(event.locationInWindow, from: nil)
        onBegin?(CGPoint(x: p.x, y: p.y))
    }

    override func rightMouseDragged(with event: NSEvent) {
        guard isActive else {
            super.rightMouseDragged(with: event)
            return
        }
        let p = convert(event.locationInWindow, from: nil)
        onChange?(CGPoint(x: p.x, y: p.y))
    }

    override func rightMouseUp(with event: NSEvent) {
        guard isActive else {
            super.rightMouseUp(with: event)
            return
        }
        let p = convert(event.locationInWindow, from: nil)
        onEnd?(CGPoint(x: p.x, y: p.y))
    }
}

// MARK: — Mode toolbar (small floating pill)

struct EditorModeToolbar: View {
    @Binding var mode: EditableOverlay.EditorMode
    /// Bind to AppState.manualMarkerDiameter. Shown inline when .manualCount is active.
    @Binding var manualMarkerDiameter: Double
    /// Pass-15 (A2): optional override fired when the Remove button is clicked.
    /// If non-nil and returns `true`, the default mode-switch is suppressed —
    /// used by Results to delete an active multi-selection in one click.
    var onRemoveTapped: (() -> Bool)? = nil

    init(mode: Binding<EditableOverlay.EditorMode>,
         manualMarkerDiameter: Binding<Double> = .constant(20.0),
         onRemoveTapped: (() -> Bool)? = nil) {
        self._mode = mode
        self._manualMarkerDiameter = manualMarkerDiameter
        self.onRemoveTapped = onRemoveTapped
    }

    var body: some View {
        HStack(spacing: 2) {
            modeButton(.view, icon: "eye", label: "View")
            modeButton(.add, icon: "plus", label: "Add")
            modeButton(.remove, icon: "minus", label: "Remove")
            modeButton(.merge, icon: "layers", label: "Merge")
            // A5: Manual count button — keyboard shortcut C
            modeButton(.manualCount, icon: "circle", label: "Count")
            // Pass-17 (Lane B): Annotate (ground truth). Keyboard shortcut G.
            // No dedicated crosshair icon in Iconography.swift — "plus" reads
            // closely enough as "place a point".
            modeButton(.annotate, icon: "plus", label: "Annotate")

            // Diameter pill — shown only when Count mode is active
            if mode == .manualCount {
                Divider()
                    .frame(height: 16)
                    .padding(.horizontal, 2)

                HStack(spacing: 0) {
                    Button {
                        manualMarkerDiameter = max(5, manualMarkerDiameter - 1)
                    } label: {
                        Text("−")
                            .font(.system(size: 14, weight: .medium))
                            .frame(width: 22, height: 24)
                            .foregroundStyle(manualMarkerDiameter > 5 ? Tokens.text : Tokens.textTertiary)
                    }
                    .buttonStyle(.plain)

                    Text(String(format: "%.0f µm", manualMarkerDiameter))
                        .font(.system(size: 11.5, design: .monospaced))
                        .foregroundStyle(Tokens.text)
                        .frame(minWidth: 46)
                        .multilineTextAlignment(.center)

                    Button {
                        manualMarkerDiameter = min(100, manualMarkerDiameter + 1)
                    } label: {
                        Text("+")
                            .font(.system(size: 14, weight: .medium))
                            .frame(width: 22, height: 24)
                            .foregroundStyle(manualMarkerDiameter < 100 ? Tokens.text : Tokens.textTertiary)
                    }
                    .buttonStyle(.plain)
                }
                .background(
                    RoundedRectangle(cornerRadius: Tokens.Radius.sm)
                        .fill(Tokens.bgSunken)
                        .overlay(
                            RoundedRectangle(cornerRadius: Tokens.Radius.sm)
                                .strokeBorder(Tokens.border, lineWidth: 0.5)
                        )
                )
                .padding(.horizontal, 4)
                .frame(height: 24)
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
        .animation(Tokens.Motion.easeFast, value: mode)
    }

    @ViewBuilder
    private func modeButton(_ m: EditableOverlay.EditorMode, icon: String, label: String) -> some View {
        let isActive = (mode == m)
        Button {
            // Pass-15 (A2): the Remove button doubles as "delete current
            // selection" when the caller signals it consumed the tap.
            if m == .remove, let handler = onRemoveTapped, handler() {
                return
            }
            mode = m
        } label: {
            HStack(spacing: 4) {
                Icon(icon, size: 12)
                Text(label).font(.system(size: 11.5, weight: .medium))
            }
            .padding(.horizontal, 8)
            .frame(height: 24)
            .foregroundStyle(isActive ? Color.white : Tokens.textSecondary)
            .background(
                RoundedRectangle(cornerRadius: Tokens.Radius.sm)
                    .fill(isActive ? Color.accentColor : Color.clear)
            )
        }
        .buttonStyle(.plain)
        .help(label)
    }
}
