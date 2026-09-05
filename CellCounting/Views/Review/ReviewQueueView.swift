import SwiftUI
import AppKit
import SwiftData

/// Active-learning Review queue.
///
/// Builds a work queue of low-confidence detected cells across all batches.
/// Each card crops tight to the cell and offers Reject / Keep / Edit actions.
///
/// What qualifies as "needs review":
///   A cell is in the queue iff
///     (1) `cell.confidence < 0.65` — the canonical cutoff, shared with the
///         sidebar badge through `AppState.reviewQueueConfidenceCutoff` /
///         `Repositories.uncorrectedCellCount(below:)`. Intentionally
///         independent of the global `state.confidence` slider so the
///         badge and queue can never drift apart.
///   AND (2) no `CorrectionRecord` exists yet for that `cellId` (any kind —
///         "remove", "accept", "resize", "move", "add", "manual"). Triaging
///         once is forever.
///
/// What each action writes:
///   - Reject  → records a `"remove"` CorrectionRecord AND removes the cell
///               from `detection.cells`. The cell stops counting toward Total
///               and size bins in ResultsSidebar.
///   - Keep    → records an `"accept"` CorrectionRecord (no data mutation).
///               The cell stays in Total/bins and is marked triaged so it
///               won't reappear.
///   - Edit    → records a `"resize"` CorrectionRecord AND updates the cell's
///               diameter (and `diameterPx`) in `detection.cells`. The cell
///               re-bins immediately in ResultsSidebar.
///   - Skip (→) advances the cursor without writing anything; the cell will
///               reappear next time the queue is opened.
struct ReviewQueueView: View {
    @Bindable var state: AppState
    @Environment(AppTheme.self) private var theme

    @State private var cursor: Int = 0
    @FocusState private var reviewFocused: Bool
    @State private var editingDiameter: Double? = nil
    @State private var queue: [ReviewItem] = []
    @AppStorage("cc-review-layout-v1") private var layoutRaw = "card"
    /// True while we're emitting our own correction (so the
    /// `ccCorrectionsChanged` listener below skips re-rebuilding the queue —
    /// `advance()` already moved the cursor and a rebuild would clobber it).
    @State private var suppressNextRebuild: Bool = false
    @State private var actionInFlight: Bool = false

    /// The most recent Reject/Keep, retained so a single mistaken keystroke is
    /// reversible (Cmd+Z or the on-screen "Undo"). Cleared once undone, or when
    /// the queue is rebuilt from a foreign correction.
    @State private var lastAction: UndoableAction? = nil

    /// Canonical Review-queue cutoff. Mirrors `AppState.reviewQueueConfidenceCutoff`
    /// (private there) so this view doesn't need a getter on AppState. If you
    /// change one, change the other — both feed the sidebar badge and the
    /// queue contents.
    private static let reviewCutoff: Double = 0.65

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().overlay(Tokens.divider).frame(height: 0.5)

            if queue.isEmpty {
                EmptyStateView(
                    title: "Done — nothing to review",
                    subtitle: "All low-confidence detections have been triaged. Drop in another batch to keep training the model.",
                    symbol: "checkmark.seal"
                )
            } else if cursor >= queue.count {
                EmptyStateView(
                    title: "Done — nothing to review",
                    subtitle: "You triaged \(queue.count) cell\(queue.count == 1 ? "" : "s"). Improvements will show up after the next fine-tune.",
                    symbol: "checkmark.seal"
                )
            } else if layoutRaw == "grid" {
                gridStack
            } else {
                cardStack
            }
        }
        // The key handlers below are attached HERE — to the content — and not
        // after the `.frame(maxWidth: .infinity, maxHeight: .infinity)` that
        // follows. `onKeyPress` makes its subject focusable, and SwiftUI sizes
        // that focusable region to the frame it is applied to. Applied after an
        // infinite frame it claimed the whole content column; the symptom was
        // that the left nav bar stopped responding to clicks as soon as the
        // Review queue opened (the only screen in the app with `onKeyPress`),
        // leaving the X button as the sole way out. Bounding the region to the
        // real content keeps the shortcuts working without swallowing clicks
        // meant for the sidebar.
        .focusable().focused($reviewFocused)
        .onKeyPress(keys: [.escape, .rightArrow, .return, .init("r"), .init("k"), .init("e")]) { handleReviewKey($0) }
        .focusedSceneValue(\.cellCounterShortcuts, shortcutActions)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Tokens.bg)
        .onAppear { rebuild(); reviewFocused = true }
        // The queue cutoff is fixed at `reviewCutoff` (independent of
        // `state.confidence`), so changing the global confidence slider
        // intentionally does NOT rebuild — that would just reset cursor=0 and
        // bounce the user out of position for no logical reason.
        .onReceive(NotificationCenter.default.publisher(for: Notification.Name("ccCorrectionsChanged"))) { _ in
            // We post this notification ourselves on every Reject/Keep/Edit,
            // and `advance()` has already moved the cursor for those cases —
            // rebuilding here would clobber the cursor and re-add cells we
            // just triaged at a confusing index. The `suppressNextRebuild`
            // flag covers exactly that local round-trip.
            if suppressNextRebuild {
                suppressNextRebuild = false
                return
            }
            // Mid-edit? Keep the user's slider state and let them finish.
            if editingDiameter != nil { return }
            // A correction from a different surface invalidates our undo target.
            lastAction = nil
            rebuild(preservingCursor: true)
        }
    }

    private var shortcutActions: ScreenShortcutActions {
        var actions = ScreenShortcutActions()
        guard !actionInFlight else { return actions }
        actions.cancel = { cancelReviewAction() }
        if cursor < queue.count { actions.next = { skipCell() } }
        if editingDiameter != nil { actions.save = { commitEdit() } }
        if canTriage {
            actions.deleteSelection = { applyAction(.reject) }
            actions.keep = { applyAction(.keep) }
            actions.edit = { startEditing() }
        }
        if lastAction != nil { actions.undo = { undoLastAction() } }
        return actions
    }

    private func handleReviewKey(_ press: KeyPress) -> KeyPress.Result {
        guard press.modifiers.isEmpty, !KeyboardShortcutContext.isEditingText,
              !KeyboardShortcutContext.hasNativeSheet, !KeyboardShortcutContext.hasOverlay(state),
              !actionInFlight else { return .ignored }
        switch press.key {
        case .escape: cancelReviewAction()
        case .rightArrow: guard cursor < queue.count else { return .ignored }; skipCell()
        case .return: guard editingDiameter != nil else { return .ignored }; commitEdit()
        case .init("r"): guard canTriage else { return .ignored }; applyAction(.reject)
        case .init("k"): guard canTriage else { return .ignored }; applyAction(.keep)
        case .init("e"): guard canTriage else { return .ignored }; startEditing()
        default: return .ignored
        }
        return .handled
    }

    private var header: some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Review queue")
                    .font(.system(size: 22, weight: .bold))
                    .tracking(-0.02 * 22)
                    .foregroundStyle(Tokens.text)
                Text("Sort uncertain detections. Each correction nudges the model toward your imaging.")
                    .font(.system(size: 13))
                    .foregroundStyle(Tokens.textTertiary)
            }
            Spacer()
            if !queue.isEmpty {
                Text("\(state.reviewQueueCount.formatted()) remaining")
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(Tokens.textTertiary)
                    .padding(.trailing, 8)
            }
            Picker("Layout", selection: $layoutRaw) {
                Label("Card", systemImage: "rectangle.portrait").tag("card")
                Label("Grid", systemImage: "square.grid.3x3").tag("grid")
            }
            .labelsHidden()
            .pickerStyle(.segmented)
            .frame(width: 150)
            .padding(.trailing, 8)
            Button {
                state.view = .home
            } label: {
                ZStack {
                    Circle()
                        .fill(Tokens.bgSunken)
                    Image(systemName: "xmark")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Tokens.textSecondary)
                }
                .frame(width: 28, height: 28)
            }
            .buttonStyle(.plain)
            .help("Close review queue (Esc)")
        }
        .padding(.horizontal, 32).padding(.vertical, 20)
    }

    private var cardStack: some View {
        VStack(spacing: 16) {
            ZStack {
                // Background "next card" peek
                if cursor + 1 < queue.count {
                    ReviewCardView(state: state, item: queue[cursor + 1], thresholds: state.thresholds,
                                   palette: state.overlayPalette,
                                   editingDiameter: .constant(nil))
                        .scaleEffect(0.96)
                        .offset(y: 14)
                        .opacity(0.4)
                        .allowsHitTesting(false)
                }
                ReviewCardView(state: state, item: queue[cursor],
                                thresholds: state.thresholds,
                                palette: state.overlayPalette,
                                editingDiameter: $editingDiameter)
                    .id(queue[cursor].id)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
            .frame(maxWidth: 560)

            actionRow
                .frame(maxWidth: 560)
                .disabled(actionInFlight)

            // Undo affordance — visible right after a Reject/Keep so a mistaken
            // action is recoverable without knowing the Cmd+Z shortcut.
            if lastAction != nil {
                Button(action: undoLastAction) {
                    HStack(spacing: 6) {
                        Image(systemName: "arrow.uturn.backward")
                            .font(.system(size: 11, weight: .semibold))
                        Text(lastAction?.action == .reject ? "Undo reject (⌘Z)" : "Undo keep (⌘Z)")
                            .font(.system(size: 12))
                    }
                    .foregroundStyle(Tokens.textSecondary)
                }
                .buttonStyle(.plain)
                .padding(.top, 2)
            }

            // Always-visible escape hatch — user should never feel trapped in the queue
            Button {
                state.view = .home
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 11, weight: .semibold))
                    Text("Done — back to home")
                        .font(.system(size: 12))
                }
                .foregroundStyle(Tokens.textTertiary)
            }
            .buttonStyle(.plain)
            .padding(.top, 4)
        }
        .padding(.horizontal, 32).padding(.vertical, 24)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    private var gridStack: some View {
        ScrollView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 190, maximum: 260), spacing: 12)],
                      spacing: 12) {
                ForEach(Array(queue.enumerated()), id: \.element.id) { index, item in
                    ReviewGridTile(item: item,
                                   thresholds: state.thresholds,
                                   palette: state.overlayPalette,
                                   isBusy: actionInFlight,
                                   onReject: { applyAction(.reject, at: index) },
                                   onKeep: { applyAction(.keep, at: index) })
                }
            }
            .padding(24)
        }
        .overlay(alignment: .bottom) {
            if lastAction != nil {
                Button(action: undoLastAction) {
                    Label("Undo last action (⌘Z)", systemImage: "arrow.uturn.backward")
                }
                .appButton(.standard, size: .sm)
                .padding(14)
            }
        }
    }

    private var actionRow: some View {
        HStack(spacing: 10) {
            Button(action: { applyAction(.reject) }) {
                HStack(spacing: 6) { Icon("x", size: 12); Text("Reject") }
            }
            .appButton(.danger, size: .md)

            Button(action: { applyAction(.keep) }) {
                HStack(spacing: 6) { Icon("check", size: 12); Text("Keep") }
            }
            .appButton(.standard, size: .md)

            Spacer()

            if editingDiameter == nil {
                Button(action: startEditing) {
                    HStack(spacing: 6) { Icon("ruler", size: 12); Text("Edit diameter") }
                }
                .appButton(.standard, size: .md)
                } else {
                Button(action: { editingDiameter = nil }) {
                    Text("Cancel")
                }
                .appButton(.ghost, size: .md)

                Button(action: commitEdit) {
                    HStack(spacing: 6) { Icon("check", size: 12); Text("Save edit") }
                }
                .appButton(.primary, size: .md)
                }
        }
    }

    private enum Action: Equatable { case reject, keep }

    /// Snapshot of the last Reject/Keep sufficient to fully reverse it.
    private struct UndoableAction {
        let action: Action
        let correction: CorrectionRecord
        let candidate: ReviewCandidateRecord
        let detection: DetectionRecord
        /// The cell removed by a Reject (nil for Keep), retained so it can be
        /// re-inserted on undo.
        let removedCell: DetectedCell?
        /// Its original index in `detection.cells`, so undo restores order.
        let removedIndex: Int?
        /// Cursor position before the action, restored on undo.
        let cursorBefore: Int
    }

    private var canTriage: Bool { cursor < queue.count && !actionInFlight && editingDiameter == nil }
    private func cancelReviewAction() {
        if editingDiameter != nil { editingDiameter = nil }
        else { state.view = .home }
    }
    private func skipCell() {
        guard cursor < queue.count, !actionInFlight else { return }
        withAnimation(Tokens.Motion.ease) { cursor += 1; editingDiameter = nil }
    }

    private func startEditing() {
        guard cursor < queue.count else { return }
        editingDiameter = queue[cursor].cell.diameter
    }

    private func commitEdit() {
        guard !actionInFlight, cursor < queue.count, let d = editingDiameter else { return }
        let item = queue[cursor]
        actionInFlight = true
        Task { @MainActor in
            defer { actionInFlight = false }
            var cells = await state.loadCells(for: item.detection)
            if let i = cells.firstIndex(where: { $0.id == item.cell.id }) {
                let newDiamPx = item.pxPerUm > 0 ? d * item.pxPerUm : cells[i].diameterPx
                cells[i].diameter = d
                cells[i].diameterPx = newDiamPx
            }
            let storage = await Task.detached(priority: .userInitiated) {
                DetectionRecord.makeStorageSnapshot(cells)
            }.value
            let result = state.repos.commitCellEdit(
                storage: storage,
                corrections: [CorrectionSpec(kind: "resize", cellId: item.cell.id,
                                             cx: item.cell.cx, cy: item.cell.cy,
                                             diameter: d)],
                detection: item.detection,
                image: item.image)

            suppressNextRebuild = true
            NotificationCenter.default.post(name: .ccCorrectionsChanged,
                                            object: item.image.id,
                                            userInfo: ["reviewDelta": result.reviewCountDelta])
            editingDiameter = nil
            advance()
        }
    }

    private func applyAction(_ action: Action, at requestedIndex: Int? = nil) {
        guard !actionInFlight else { return }
        let actionIndex = requestedIndex ?? cursor
        guard queue.indices.contains(actionIndex) else { return }
        let item = queue[actionIndex]
        let kind: String
        switch action {
        case .reject: kind = "remove"
        case .keep:   kind = "accept"
        }
        // Reject must also remove the cell from `detection.cells`. The
        // CorrectionRecord alone is just an audit-trail entry; the Sidebar
        // Total + bin counts read from `detection.cells` directly (via
        // `ResultsSidebar.rawCells`), so without this mutation the rejected
        // cell would keep counting. Matches the `.removed` path in
        // `EditableOverlay → handleEdit`. Keep ("accept") deliberately leaves
        // `detection.cells` untouched — the user kept the detection; only
        // the audit trail records that it's been triaged.
        actionInFlight = true
        Task { @MainActor in
            defer { actionInFlight = false }
            var removedIndex: Int? = nil
            var removedCell: DetectedCell? = nil
            var storage: DetectionRecord.CellsStorageSnapshot? = nil
            if action == .reject {
                var cells = await state.loadCells(for: item.detection)
                if let i = cells.firstIndex(where: { $0.id == item.cell.id }) {
                    removedCell = cells[i]
                    cells.remove(at: i)
                    removedIndex = i
                    storage = await Task.detached(priority: .userInitiated) {
                        DetectionRecord.makeStorageSnapshot(cells)
                    }.value
                }
            }

            let result = state.repos.commitCellEdit(
                storage: storage,
                corrections: [CorrectionSpec(kind: kind, cell: item.cell)],
                detection: item.detection,
                image: item.image)
            guard let c = result.corrections.first else { return }

            lastAction = UndoableAction(action: action,
                                        correction: c,
                                        candidate: item.candidate,
                                        detection: item.detection,
                                        removedCell: action == .reject ? removedCell : nil,
                                        removedIndex: removedIndex,
                                        cursorBefore: actionIndex)

            suppressNextRebuild = true
            NotificationCenter.default.post(name: .ccCorrectionsChanged,
                                            object: item.image.id,
                                            userInfo: ["reviewDelta": result.reviewCountDelta])
            if requestedIndex != nil {
                if let latestIndex = queue.firstIndex(where: { $0.id == item.id }) {
                    _ = withAnimation(Tokens.Motion.easeFast) { queue.remove(at: latestIndex) }
                }
                cursor = min(cursor, max(0, queue.count - 1))
                if queue.isEmpty { rebuild() }
            } else {
                advance()
            }
        }
    }

    /// Reverse the most recent Reject/Keep: delete its audit-trail correction,
    /// re-insert a rejected cell at its original index, and return the cursor to
    /// where it was so the card reappears for re-triage.
    private func undoLastAction() {
        guard let undo = lastAction else { return }
        // Restore a rejected cell into detection.cells at its original slot.
        var restoredCells: [DetectedCell]? = nil
        if undo.action == .reject, let cell = undo.removedCell {
            var cells = undo.detection.cells
            if !cells.contains(where: { $0.id == cell.id }) {
                let insertAt = min(undo.removedIndex ?? cells.count, cells.count)
                cells.insert(cell, at: insertAt)
                restoredCells = cells
            }
        }
        guard let image = undo.candidate.image else { return }
        let delta = state.repos.undoReviewCorrection(
            undo.correction,
            candidate: undo.candidate,
            restoredCells: restoredCells,
            detection: undo.detection,
            image: image)
        lastAction = nil

        // Rebuild so the restored cell reappears, then land the cursor on it so
        // the user sees exactly what they just un-rejected (the queue is sorted
        // by confidence, so its index isn't necessarily cursorBefore).
        // suppressNextRebuild guards the notification round-trip.
        suppressNextRebuild = true
        NotificationCenter.default.post(name: .ccCorrectionsChanged,
                                        object: image.id,
                                        userInfo: ["reviewDelta": delta])
        rebuild(preservingCursor: false)
        if let cell = undo.removedCell, let idx = queue.firstIndex(where: { $0.cell.id == cell.id }) {
            cursor = idx
        } else {
            cursor = min(undo.cursorBefore, max(queue.count - 1, 0))
        }
    }

    private func advance() {
        if cursor + 1 >= queue.count {
            // Fetch the next small page. Already-triaged rows disappear from
            // the predicate, so no offset bookkeeping or duplicate cards.
            rebuild()
        } else {
            withAnimation(Tokens.Motion.ease) { cursor += 1 }
        }
        editingDiameter = nil
    }

    /// Full rebuild from the store. `preservingCursor` keeps the user near
    /// their current position when the queue changes underneath them
    /// (e.g. a correction landed from a different surface). When false,
    /// resets to the head of the queue.
    private func rebuild(preservingCursor: Bool = false) {
        let cutoff = Self.reviewCutoff
        // Try to stay anchored to whatever cell the user is currently looking
        // at when we're preserving the cursor. If that cell has been triaged
        // (vanished from the new queue), fall back to the same index clamped.
        let anchorId: UUID? = preservingCursor && queue.indices.contains(cursor)
            ? queue[cursor].cell.id
            : nil
        let previousIndex = cursor

        // Fix (researcher #3) — badge/queue count mismatch:
        //
        // The sidebar badge (AppState.reviewQueueCount ←
        // Repositories.uncorrectedCellCount) counts the uncorrected
        // low-confidence cells of EVERY stored detection. This rebuild used to
        // dedupe by `image.fileName` (Pass-16), keeping only the most recent
        // import per file. So when the same file was imported more than once
        // (the "11 ImageRecord rows share an MD5" case), the badge counted all
        // copies while the queue showed only one — the badge could read
        // "hundreds" while the tab showed "nothing to review" if that single
        // most-recent copy happened to be fully triaged.
        //
        // Iterate the exact same set the badge counts (all detections, no
        // fileName dedupe) so the count in the sidebar and the number of cards
        // in the queue can never drift apart — the invariant this file's header
        // documents. (Deduping BOTH the badge and the queue is the nicer long-
        // term behavior but must also change Repositories.uncorrectedCellCount;
        // see the audit's recommendations.)
        _ = cutoff // membership is materialized at the canonical 0.65 cutoff
        var items: [ReviewItem] = []
        for candidate in state.repos.pendingReviewCandidates(limit: 96) {
            guard let detection = candidate.detection,
                  let image = candidate.image,
                  let batch = image.batch else { continue }
            items.append(ReviewItem(
                candidate: candidate,
                cell: candidate.fallbackCell,
                image: image,
                detection: detection,
                pxPerUm: batch.pxPerUm,
                batchName: batch.displayName
            ))
        }
        queue = items

        if preservingCursor {
            if let id = anchorId, let newIdx = items.firstIndex(where: { $0.cell.id == id }) {
                cursor = newIdx
            } else {
                cursor = min(previousIndex, items.count)
            }
        } else {
            cursor = 0
        }
    }
}

// MARK: — Item model

private struct ReviewItem: Identifiable {
    var id: UUID { candidate.id }
    let candidate: ReviewCandidateRecord
    let cell: DetectedCell
    let image: ImageRecord
    let detection: DetectionRecord
    let pxPerUm: Double
    let batchName: String
}

// MARK: — Tiled curator

private struct ReviewGridTile: View {
    let item: ReviewItem
    let thresholds: [Double]
    let palette: OverlayPalette
    let isBusy: Bool
    let onReject: () -> Void
    let onKeep: () -> Void

    @State private var loaded: NSImage? = nil
    @State private var loadTask: Task<Void, Never>? = nil

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                Rectangle().fill(Tokens.bgSunken)
                if let loaded { crop(loaded) } else { AppSpinner() }
            }
            .frame(height: 150)
            .clipped()

            VStack(alignment: .leading, spacing: 7) {
                HStack {
                    Text(String(format: "%.1f µm", item.cell.diameter))
                        .font(.system(size: 11.5, weight: .semibold, design: .monospaced))
                        .foregroundStyle(Tokens.text)
                    Spacer()
                    Text("\(Int(item.cell.confidence * 100))%")
                        .font(.system(size: 10.5, design: .monospaced))
                        .foregroundStyle(Tokens.warning)
                }
                Text(item.image.fileName)
                    .font(.system(size: 10)).foregroundStyle(Tokens.textTertiary)
                    .lineLimit(1).truncationMode(.middle)
                HStack(spacing: 6) {
                    Button(action: onReject) {
                        Label("Reject", systemImage: "xmark").frame(maxWidth: .infinity)
                    }.appButton(.danger, size: .sm)
                        .disabled(isBusy)
                    Button(action: onKeep) {
                        Label("Keep", systemImage: "checkmark").frame(maxWidth: .infinity)
                    }.appButton(.standard, size: .sm)
                        .disabled(isBusy)
                }
            }.padding(9)
        }
        .background(Tokens.bgElevated)
        .clipShape(RoundedRectangle(cornerRadius: Tokens.Radius.md))
        .overlay(RoundedRectangle(cornerRadius: Tokens.Radius.md)
            .strokeBorder(Tokens.border, lineWidth: 0.5))
        .onAppear(perform: load)
        .onDisappear { loadTask?.cancel() }
    }

    private func crop(_ image: NSImage) -> some View {
        GeometryReader { geometry in
            let rect = computeCropRect(widthPx: item.image.widthPx,
                                       heightPx: item.image.heightPx,
                                       cell: item.cell,
                                       canvasSize: geometry.size)
            let scale = max(geometry.size.width / rect.width,
                            geometry.size.height / rect.height)
            ZStack {
                Image(nsImage: image)
                    .resizable().interpolation(.medium)
                    .frame(width: CGFloat(item.image.widthPx) * scale,
                           height: CGFloat(item.image.heightPx) * scale)
                    .offset(x: -rect.minX * scale, y: -rect.minY * scale)
                    .frame(width: geometry.size.width, height: geometry.size.height,
                           alignment: .topLeading)
                    .clipped()
                Canvas { context, _ in
                    let index = BinMath.binIndex(for: item.cell.diameter,
                                                 thresholds: thresholds)
                    let color = palette.overlayColor(forBin: index)
                    if let contour = item.cell.contourPx, contour.count >= 3 {
                        var path = Path()
                        let first = contour[0]
                        path.move(to: CGPoint(x: (first.x - rect.minX) * scale,
                                              y: (first.y - rect.minY) * scale))
                        for point in contour.dropFirst() {
                            path.addLine(to: CGPoint(x: (point.x - rect.minX) * scale,
                                                     y: (point.y - rect.minY) * scale))
                        }
                        path.closeSubpath()
                        context.fill(path, with: .color(color.opacity(0.32)))
                        context.stroke(path, with: .color(Tokens.danger),
                                       style: StrokeStyle(lineWidth: 2))
                    } else {
                        let radius = item.cell.diameterPx * scale / 2
                        let circle = CGRect(x: (item.cell.cx - rect.minX) * scale - radius,
                                            y: (item.cell.cy - rect.minY) * scale - radius,
                                            width: radius * 2, height: radius * 2)
                        context.fill(Path(ellipseIn: circle), with: .color(color.opacity(0.32)))
                        context.stroke(Path(ellipseIn: circle), with: .color(Tokens.danger),
                                       style: StrokeStyle(lineWidth: 2))
                    }
                }
            }
        }
    }

    private func load() {
        guard loaded == nil else { return }
        let url = item.image.thumbURL
        loadTask = Task {
            // Grid tiles deliberately use the import-time 256 px thumbnail.
            // Loading 96 separate 1800 px Review previews caused avoidable
            // decode and memory pressure while scrolling the curator.
            let image = await Task.detached(priority: .utility) {
                ImageLoader.cachedThumbnail(at: url)
            }.value
            guard !Task.isCancelled else { return }
            loaded = image
        }
    }
}

// MARK: — Single card

private struct ReviewCardView: View {
    @Bindable var state: AppState
    let item: ReviewItem
    let thresholds: [Double]
    let palette: OverlayPalette
    @Binding var editingDiameter: Double?

    @Environment(AppTheme.self) private var theme
    @State private var loaded: NSImage? = nil
    @State private var detectionCells: [DetectedCell] = []
    // B1-6: store task reference so we can cancel on disappear
    @State private var loadTask: Task<Void, Never>? = nil

    private var binIdx: Int {
        let d = editingDiameter ?? item.cell.diameter
        return BinMath.binIndex(for: d, thresholds: thresholds)
    }
    private var binLabel: String {
        let bins = BinMath.bins(from: thresholds)
        guard bins.indices.contains(binIdx) else { return "—" }
        return bins[binIdx].label
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ZStack {
                Rectangle().fill(Tokens.bgSunken)
                if let nsImage = loaded {
                    cropView(nsImage: nsImage)
                } else {
                    AppSpinner()
                }
            }
            .frame(height: 320)
            .clipShape(RoundedRectangle(cornerRadius: Tokens.Radius.lg, style: .continuous))

            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .center, spacing: 10) {
                    TagLabel(text: binLabel, style: .accent)
                    Text(formatDiameter(editingDiameter ?? item.cell.diameter))
                        .font(.system(size: 13.5, weight: .semibold, design: .monospaced))
                        .foregroundStyle(Tokens.text)
                    Spacer()
                    confidenceBar
                }

                if let d = editingDiameter {
                    diameterSlider(current: d)
                }

                Text(item.image.fileName)
                    .font(.system(size: 11))
                    .foregroundStyle(Tokens.textTertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .padding(14)
        }
        .background(
            RoundedRectangle(cornerRadius: Tokens.Radius.lg, style: .continuous)
                .fill(Tokens.bgElevated)
        )
        .overlay(
            RoundedRectangle(cornerRadius: Tokens.Radius.lg, style: .continuous)
                .strokeBorder(Tokens.border, lineWidth: 0.5)
        )
        .shadow(color: .black.opacity(0.05), radius: 8, y: 2)
        .onAppear(perform: load)
        .onDisappear { loadTask?.cancel() }
    }

    private var confidenceBar: some View {
        HStack(spacing: 6) {
            ZStack(alignment: .leading) {
                Capsule().fill(Tokens.bgSunken).frame(width: 80, height: 6)
                Capsule().fill(confidenceColor)
                    .frame(width: max(2, 80 * item.cell.confidence), height: 6)
            }
            Text("\(Int(item.cell.confidence * 100))%")
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(Tokens.textSecondary)
        }
    }

    private var confidenceColor: Color {
        if item.cell.confidence < 0.35 { return Tokens.danger }
        if item.cell.confidence < 0.55 { return Tokens.warning }
        return theme.accentColor
    }

    private func diameterSlider(current: Double) -> some View {
        HStack(spacing: 10) {
            Text("µm")
                .font(.system(size: 10.5, weight: .medium))
                .foregroundStyle(Tokens.textTertiary)
            Slider(value: Binding(
                get: { editingDiameter ?? item.cell.diameter },
                set: { editingDiameter = $0 }
            ), in: max(2, item.cell.diameter * 0.3)...(item.cell.diameter * 2.5))
            .controlSize(.small)
            Text(formatDiameter(current))
                .font(.system(size: 11.5, design: .monospaced))
                .foregroundStyle(Tokens.text)
                .frame(width: 56, alignment: .trailing)
        }
        .padding(.horizontal, 10).padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: Tokens.Radius.md, style: .continuous)
                .fill(Tokens.bgSunken)
        )
    }

    private func cropView(nsImage: NSImage) -> some View {
        GeometryReader { geo in
            // Coordinate transforms used below:
            //   1) image-pixel space  → the source NSImage (cx/cy, contourPx[].x/y)
            //   2) crop-window space  → translate by (-cropRect.minX, -cropRect.minY)
            //   3) view space         → multiply by `scale` (uniform aspect-fit)
            // For any image-pixel point p, the view-space point is:
            //   v = (p - cropRect.origin) * scale
            let cropRect = computeCropRect(
                widthPx: item.image.widthPx,
                heightPx: item.image.heightPx,
                cell: item.cell,
                canvasSize: geo.size
            )
            let scale = min(geo.size.width / cropRect.width, geo.size.height / cropRect.height)
            let renderedW = cropRect.width * scale
            let renderedH = cropRect.height * scale

            ZStack {
                Image(nsImage: nsImage)
                    .resizable()
                    .interpolation(.high)
                    .frame(width: CGFloat(item.image.widthPx) * scale,
                            height: CGFloat(item.image.heightPx) * scale)
                    .offset(x: -cropRect.minX * scale, y: -cropRect.minY * scale)
                    .frame(width: renderedW, height: renderedH, alignment: .topLeading)
                    .clipped()

                // Contour / circle overlay: bin-colored fill for the target cell
                // and de-emphasized strokes for neighbors caught in the crop.
                Canvas { ctx, _ in
                    let thresholds = self.thresholds
                    let targetId = item.cell.id
                    let targetCell = detectionCells.first(where: { $0.id == targetId }) ?? item.cell

                    // 1) Neighbors first (drawn under the target so the target ring
                    //    stays visually on top).
                    for c in detectionCells where c.id != targetId {
                        guard cellIntersectsCropRect(c, cropRect: cropRect) else { continue }
                        let idx = BinMath.binIndex(for: c.diameter, thresholds: thresholds)
                        let col = palette.overlayColor(forBin: idx)
                        if let contour = c.contourPx, contour.count >= 3 {
                            let poly = makePolyPath(contour, cropRect: cropRect, scale: scale)
                            ctx.fill(poly, with: .color(col.opacity(0.12)))
                            ctx.stroke(poly,
                                       with: .color(col.opacity(0.55)),
                                       style: StrokeStyle(lineWidth: 0.8))
                        } else {
                            let rect = circleRect(for: c, cropRect: cropRect, scale: scale)
                            ctx.stroke(Path(ellipseIn: rect),
                                       with: .color(col.opacity(0.55)),
                                       style: StrokeStyle(lineWidth: 0.8))
                        }
                    }

                    // 2) Target cell — bin-colored fill at 0.35 alpha (Review is
                    //    about scrutinizing this one) plus a thin red ring just
                    //    outside the contour so it's unmistakable.
                    let targetDiameter = editingDiameter ?? targetCell.diameter
                    let idx = BinMath.binIndex(for: targetDiameter, thresholds: thresholds)
                    let col = palette.overlayColor(forBin: idx)

                    if let contour = targetCell.contourPx, contour.count >= 3 {
                        let poly = makePolyPath(contour, cropRect: cropRect, scale: scale)
                        ctx.fill(poly, with: .color(col.opacity(0.35)))
                        ctx.stroke(poly, with: .color(col), style: StrokeStyle(lineWidth: 1.5))
                        // Outer red ring: re-stroke a slightly offset (dilated) copy.
                        // Cheap approximation — stroke the same path with a thicker
                        // red, with a transparent core, so it reads as a "halo".
                        ctx.stroke(poly,
                                   with: .color(Tokens.danger.opacity(0.9)),
                                   style: StrokeStyle(lineWidth: 2.5))
                        // Repaint the inner crisp colored stroke on top of the halo.
                        ctx.stroke(poly, with: .color(col), style: StrokeStyle(lineWidth: 1.2))
                    } else {
                        // Legacy fallback: circle from diameter (uses live edit diameter).
                        let activeDiameterPx = targetDiameter * item.pxPerUm
                        let cx = (targetCell.cx - cropRect.minX) * scale
                        let cy = (targetCell.cy - cropRect.minY) * scale
                        let r = activeDiameterPx * scale / 2
                        let rect = CGRect(x: cx - r, y: cy - r, width: r * 2, height: r * 2)
                        let path = Path(ellipseIn: rect)
                        ctx.fill(path, with: .color(col.opacity(0.35)))
                        ctx.stroke(path, with: .color(col), style: StrokeStyle(lineWidth: 1.5))
                        // Outer red highlight ring just beyond the circle.
                        let ringRect = rect.insetBy(dx: -3, dy: -3)
                        ctx.stroke(Path(ellipseIn: ringRect),
                                   with: .color(Tokens.danger.opacity(0.9)),
                                   style: StrokeStyle(lineWidth: 1.5))
                    }
                }
                .frame(width: renderedW, height: renderedH)

                // Fix (researcher #3): size-scale reference so the reviewer can
                // judge the cell's real dimensions. Sits at the crop's
                // bottom-left, matching the main viewer's ScaleBar affordance.
                reviewScaleBar(pxPerUm: item.pxPerUm, scale: scale, availableWidth: renderedW)
                    .padding(8)
                    .frame(width: renderedW, height: renderedH, alignment: .bottomLeading)
            }
            .frame(width: geo.size.width, height: geo.size.height)
        }
    }

    /// Fix (researcher #3): adaptive scale bar for the review crop. `scale` maps
    /// source pixels → view points; `item.pxPerUm` maps µm → source pixels. The
    /// bar length targets ~a third of the crop width, snapped to a human-friendly
    /// µm value so the reviewer gets an honest size reference at any zoom.
    @ViewBuilder
    private func reviewScaleBar(pxPerUm: Double, scale: Double, availableWidth: Double) -> some View {
        if pxPerUm > 0, scale > 0, availableWidth > 60 {
            let targetUm = (availableWidth * 0.33) / (pxPerUm * scale)
            let niceUm = Self.niceScaleLength(targetUm)
            let barPt = max(6, niceUm * pxPerUm * scale)
            HStack(spacing: 6) {
                Rectangle()
                    .fill(.white)
                    .frame(width: barPt, height: 2)
                Text(Self.formatScaleLabel(niceUm))
                    .font(.system(size: 9.5, weight: .medium, design: .monospaced))
                    .foregroundStyle(.white)
            }
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(
                RoundedRectangle(cornerRadius: 4)
                    .fill(.black.opacity(0.55))
            )
        }
    }

    /// Largest "nice" µm length not exceeding `target` (falls back to the
    /// smallest candidate for very high-magnification crops).
    private static func niceScaleLength(_ target: Double) -> Double {
        let candidates: [Double] = [1, 2, 5, 10, 20, 25, 50, 100, 200, 500]
        var chosen = candidates.first ?? 1
        for c in candidates where c <= target { chosen = c }
        return chosen
    }

    private static func formatScaleLabel(_ um: Double) -> String {
        um >= 1 ? String(format: "%.0f µm", um) : String(format: "%.1f µm", um)
    }

    /// Build a view-space `Path` from image-pixel contour points.
    /// Transform: view = (px - cropRect.origin) * scale.
    private func makePolyPath(_ contour: [CGPoint], cropRect: CGRect, scale: Double) -> Path {
        var poly = Path()
        let first = contour[0]
        poly.move(to: CGPoint(
            x: (Double(first.x) - cropRect.minX) * scale,
            y: (Double(first.y) - cropRect.minY) * scale))
        for i in 1..<contour.count {
            let p = contour[i]
            poly.addLine(to: CGPoint(
                x: (Double(p.x) - cropRect.minX) * scale,
                y: (Double(p.y) - cropRect.minY) * scale))
        }
        poly.closeSubpath()
        return poly
    }

    /// Fallback circle rect (view space) for legacy cells without contours.
    private func circleRect(for c: DetectedCell, cropRect: CGRect, scale: Double) -> CGRect {
        let cx = (c.cx - cropRect.minX) * scale
        let cy = (c.cy - cropRect.minY) * scale
        let r = c.diameterPx * scale / 2
        return CGRect(x: cx - r, y: cy - r, width: r * 2, height: r * 2)
    }

    /// Cheap "does this cell's bbox overlap the crop window" test — used to
    /// skip drawing neighbors that fall entirely outside the visible crop.
    private func cellIntersectsCropRect(_ c: DetectedCell, cropRect: CGRect) -> Bool {
        let r = c.diameterPx / 2
        let bb = CGRect(x: c.cx - r, y: c.cy - r, width: c.diameterPx, height: c.diameterPx)
        return bb.intersects(cropRect)
    }

    private func load() {
        guard loaded == nil else { return }
        let record = item.image
        let url = record.storedURL
        let detection = item.detection
        // Decode only the visible card's source image/cells. Opening Review no
        // longer materializes every blob in the 96-item page.
        loadTask = Task {
            async let cells = state.loadCells(for: detection)
            let ns = await Task.detached(priority: .userInitiated) {
                ImageLoader.cachedReviewPreview(at: url)
            }.value
            let decoded = await cells
            guard !Task.isCancelled else { return }
            self.loaded = ns
            self.detectionCells = decoded
        }
    }

    private func formatDiameter(_ d: Double) -> String {
        String(format: "%.1f µm", d)
    }
}

// MARK: — Crop math

/// Window centered on the cell, big enough (~5× the cell diameter on the short
/// axis) to give context. The shape matches the visible canvas aspect ratio so
/// the aspect-fit scale doesn't waste half the card on letterboxing.
///
/// If the cell is near an image edge, the window slides so the cell stays
/// visible (we never pad with empty space — we just slide).
///
/// All math is in image-pixel space.
private func computeCropRect(widthPx: Int, heightPx: Int, cell: DetectedCell, canvasSize: CGSize) -> CGRect {
    // ~5× diameter context on the short axis. Pass-16: was 1.8× (too tight).
    let contextFactor: Double = 5.0
    // Minimum px window so tiny cells still render at a sensible size.
    let minWindowPx: Double = 240
    let shortPx = max(cell.diameterPx * contextFactor, minWindowPx)

    let canvasAspect: Double = (canvasSize.width > 0 && canvasSize.height > 0)
        ? Double(canvasSize.width / canvasSize.height)
        : 1.0
    // Build a rectangle with the canvas aspect, anchored to the short axis.
    var w: Double
    var h: Double
    if canvasAspect >= 1 {
        h = shortPx
        w = shortPx * canvasAspect
    } else {
        w = shortPx
        h = shortPx / canvasAspect
    }
    // Don't ask for a window larger than the source image.
    w = min(w, Double(widthPx))
    h = min(h, Double(heightPx))

    // Center on the cell; then slide so the rect stays inside the image.
    var x = cell.cx - w / 2
    var y = cell.cy - h / 2
    x = max(0, min(x, Double(widthPx) - w))
    y = max(0, min(y, Double(heightPx) - h))
    return CGRect(x: x, y: y, width: w, height: h)
}
