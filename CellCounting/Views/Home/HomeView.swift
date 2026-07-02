import SwiftUI
import UniformTypeIdentifiers
import AppKit

// MARK: — HomeView

struct HomeView: View {
    @Bindable var state: AppState
    @Environment(AppTheme.self) private var theme

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 32) {
                DropZone(state: state)
                ShortcutsGrid(state: state)
                RecentsSection(state: state)
            }
            .padding(.horizontal, 40)
            .padding(.top, 32)
            .padding(.bottom, 40)
        }
        .frame(maxWidth: 980)
        .frame(maxWidth: .infinity)
        // ⌘D — Choose images (primary CTA)
        // ⌘⇧D — Choose folder
        .overlay(
            Group {
                Button("") { homeChooseImages(state: state) }
                    .keyboardShortcut("d", modifiers: [.command])
                    .hidden()
                    .allowsHitTesting(false)
                    .disabled(!state.canRunDetection)
                Button("") { homeChooseFolder(state: state) }
                    .keyboardShortcut("d", modifiers: [.command, .shift])
                    .hidden()
                    .allowsHitTesting(false)
                    .disabled(!state.canRunDetection)
            }
        )
        // Surface detection failures (no model installed, sidecar crash, etc.)
        // as a system alert so the user never silently lands in an empty Results screen.
        .alert("Detection failed",
               isPresented: $state.showDetectionError,
               actions: { Button("OK", role: .cancel) {} },
               message: { Text(state.lastDetectionError ?? "Unknown error.") })
    }
}

// MARK: — Home shortcut helpers (free functions to keep struct lean)

private func homeChooseImages(state: AppState) {
    presentOpenPanel(allowedExtensions: Array(ImageLoader.supported), allowFolders: false, allowMultiple: true) { urls in
        Task { @MainActor in
            guard !urls.isEmpty else { return }
            // Always import — when conditions exist the in-view picker may not be
            // available (cmd-D is a global shortcut), so go straight to analyze.
            // The user can tag the batch later from Batch view.
            state.importAndAnalyze(urls: urls)
        }
    }
}

private func homeChooseFolder(state: AppState) {
    presentOpenPanel(allowedExtensions: Array(ImageLoader.supported), allowFolders: true, allowMultiple: false) { urls in
        Task { @MainActor in
            guard let folder = urls.first else { return }
            let files: [URL]
            if let enumerator = FileManager.default.enumerator(at: folder,
                                                                includingPropertiesForKeys: [.isRegularFileKey],
                                                                options: [.skipsHiddenFiles]) {
                files = enumerator.compactMap { $0 as? URL }
                    .filter { ImageLoader.supported.contains($0.pathExtension.lowercased()) }
            } else { files = [] }
            guard !files.isEmpty else { return }
            state.importAndAnalyze(urls: files)
        }
    }
}

// MARK: — Drop Zone

private struct DropZone: View {
    @Bindable var state: AppState
    @Environment(AppTheme.self) private var theme
    @State private var isOver = false
    /// Pending import — set when a drop/picker fires; cleared when picker decides.
    @State private var pendingURLs: [URL]? = nil

    var body: some View {
        ZStack {
            dropZoneContent

            // Inline condition picker shown after a drop/pick fires.
            // Optional & dismissable — "Skip" leaves the batch's condition nil.
            if let urls = pendingURLs {
                ConditionPickerOverlay(
                    state: state,
                    onCancel: { pendingURLs = nil },
                    onPick: { condition in
                        pendingURLs = nil
                        state.importAndAnalyze(urls: urls, condition: condition)
                    })
                .transition(.opacity.combined(with: .move(edge: .top)))
                .zIndex(10)
            }
        }
        .frame(minHeight: 320)
        .animation(Tokens.Motion.ease, value: isOver)
        .animation(Tokens.Motion.ease, value: pendingURLs != nil)
        .onDrop(of: [.fileURL], isTargeted: $isOver) { providers in
            handleDrop(providers: providers)
            return true
        }
    }

    @ViewBuilder
    private var dropZoneContent: some View {
        ZStack {
            RoundedRectangle(cornerRadius: Tokens.Radius.xxl, style: .continuous)
                .fill(
                    RadialGradient(
                        colors: isOver
                            ? [theme.accentSoft, Tokens.bg]
                            : [Tokens.bgSunken, Tokens.bg],
                        center: .center,
                        startRadius: 0,
                        endRadius: 240
                    )
                )

            RoundedRectangle(cornerRadius: Tokens.Radius.xxl, style: .continuous)
                .strokeBorder(
                    isOver ? theme.accentColor : Tokens.borderStrong,
                    style: StrokeStyle(lineWidth: 1.5, dash: [6, 4])
                )

            VStack(spacing: 0) {
                PetriDishIllustration(isOver: isOver)
                    .frame(width: 110, height: 110)
                    .padding(.bottom, 18)

                Text("Drop microscope images here")
                    .font(.system(size: 21, weight: .semibold))
                    .tracking(-0.21)
                    .foregroundStyle(Tokens.text)

                Text("One image, a folder, or a whole batch — we'll detect and size every cell.")
                    .font(.system(size: 13.5))
                    .foregroundStyle(Tokens.textSecondary)
                    .multilineTextAlignment(.center)
                    .padding(.top, 6)
                    .padding(.bottom, 18)

                HStack(spacing: 8) {
                    Button {
                        chooseImages()
                    } label: {
                        HStack(spacing: 6) {
                            Icon("image", size: 13)
                            Text("Choose images…")
                        }
                    }
                    .appButton(.primary, size: .lg)
                    .disabled(!state.canRunDetection)
                    .help(state.canRunDetection
                          ? "Pick one or more images to analyze."
                          : "The active model isn't installed. Open Models to install it.")

                    Button {
                        chooseFolder()
                    } label: {
                        HStack(spacing: 6) {
                            Icon("folder", size: 13)
                            Text("Choose folder…")
                        }
                    }
                    .appButton(.standard, size: .lg)
                    .disabled(!state.canRunDetection)
                    .help(state.canRunDetection
                          ? "Pick a folder of images to analyze."
                          : "The active model isn't installed. Open Models to install it.")
                }
            }
            .padding(32)
        }
    }

    // MARK: actions

    /// Route every import through the condition picker. If there are no
    /// saved conditions at all, fall through and import without prompting.
    private func beginImport(urls: [URL]) {
        guard !urls.isEmpty else { return }
        if state.repos.conditions().isEmpty {
            state.importAndAnalyze(urls: urls)
        } else {
            pendingURLs = urls
        }
    }

    private func chooseImages() {
        presentOpenPanel(allowedExtensions: Array(ImageLoader.supported),
                         allowFolders: false,
                         allowMultiple: true) { urls in
            Task { @MainActor in
                beginImport(urls: expand(urls: urls))
            }
        }
    }

    private func chooseFolder() {
        presentOpenPanel(allowedExtensions: Array(ImageLoader.supported),
                         allowFolders: true,
                         allowMultiple: false) { urls in
            Task { @MainActor in
                beginImport(urls: expand(urls: urls))
            }
        }
    }

    private func handleDrop(providers: [NSItemProvider]) {
        let group = DispatchGroup()
        var collected: [URL] = []
        let lock = NSLock()

        for provider in providers {
            guard provider.canLoadObject(ofClass: URL.self) else { continue }
            group.enter()
            _ = provider.loadObject(ofClass: URL.self) { item, _ in
                defer { group.leave() }
                if let url = item as? URL {
                    lock.lock(); collected.append(url); lock.unlock()
                }
            }
        }

        group.notify(queue: .main) {
            let expanded = expand(urls: collected)
            Task { @MainActor in
                beginImport(urls: expanded)
            }
        }
    }

    /// Recursively walks folders, filters by supported extensions.
    private func expand(urls: [URL]) -> [URL] {
        var out: [URL] = []
        let fm = FileManager.default
        for url in urls {
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: url.path, isDirectory: &isDir) else { continue }
            if isDir.boolValue {
                let keys: [URLResourceKey] = [.isRegularFileKey]
                if let enumerator = fm.enumerator(at: url, includingPropertiesForKeys: keys,
                                                  options: [.skipsHiddenFiles]) {
                    for case let child as URL in enumerator {
                        if ImageLoader.supported.contains(child.pathExtension.lowercased()) {
                            out.append(child)
                        }
                    }
                }
            } else {
                if ImageLoader.supported.contains(url.pathExtension.lowercased()) {
                    out.append(url)
                }
            }
        }
        return out
    }
}

// MARK: — Condition picker overlay (pass 6)

/// Inline picker shown after the user drops/picks files. Lets them tag the
/// new batch with an inhibitor condition or skip — never blocks import.
private struct ConditionPickerOverlay: View {
    @Bindable var state: AppState
    let onCancel: () -> Void
    let onPick: (String?) -> Void

    @Environment(AppTheme.self) private var theme
    @State private var conditions: [ConditionRecord] = []
    @State private var showingNew = false
    @State private var newName: String = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Tag this batch")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(Tokens.text)
                    Text("Which condition is this? Used by Compare to pool batches across treatments.")
                        .font(.system(size: 11.5))
                        .foregroundStyle(Tokens.textTertiary)
                }
                Spacer(minLength: 0)
                Button { onCancel() } label: { Icon("x", size: 12) }
                    .appButton(.ghost, size: .sm)
            }

            // Chip-row of available conditions.
            HStack(spacing: 6) {
                ForEach(conditions, id: \.id) { c in
                    Button {
                        onPick(c.name)
                    } label: {
                        HStack(spacing: 6) {
                            Circle()
                                .fill(Color(hex: c.color) ?? theme.accentColor)
                                .frame(width: 8, height: 8)
                            Text(c.name)
                                .font(.system(size: 12, weight: .medium))
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(
                            RoundedRectangle(cornerRadius: Tokens.Radius.md, style: .continuous)
                                .fill(Tokens.bgElevated))
                        .overlay(
                            RoundedRectangle(cornerRadius: Tokens.Radius.md, style: .continuous)
                                .strokeBorder(Tokens.borderStrong, lineWidth: 0.5))
                        .foregroundStyle(Tokens.text)
                    }
                    .buttonStyle(.plain)
                }

                if showingNew {
                    HStack(spacing: 4) {
                        TextField("New condition…", text: $newName)
                            .textFieldStyle(.plain)
                            .font(.system(size: 12))
                            .frame(width: 120)
                        Button("Add") {
                            let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
                            guard !trimmed.isEmpty else { return }
                            // Cycle a palette-ish hue so new conditions get distinct colors.
                            let palette = ["#4db3a8", "#d97757", "#7b88e0", "#c074b8", "#e0b04d"]
                            let color = palette[conditions.count % palette.count]
                            state.repos.createCondition(name: trimmed, color: color)
                            newName = ""
                            showingNew = false
                            refresh()
                        }
                        .appButton(.primary, size: .sm)
                        Button("Cancel") { showingNew = false; newName = "" }
                            .appButton(.ghost, size: .sm)
                    }
                    .padding(.horizontal, 8).padding(.vertical, 3)
                    .background(
                        RoundedRectangle(cornerRadius: Tokens.Radius.md, style: .continuous)
                            .fill(Tokens.bgElevated))
                } else {
                    Button { showingNew = true } label: {
                        HStack(spacing: 4) {
                            Icon("plus", size: 11)
                            Text("New condition…").font(.system(size: 12))
                        }
                    }
                    .appButton(.ghost, size: .sm)
                }

                Spacer(minLength: 0)

                Button { onPick(nil) } label: {
                    Text("Skip — no condition").font(.system(size: 12))
                }
                .appButton(.standard, size: .sm)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: Tokens.Radius.lg, style: .continuous)
                .fill(Tokens.bg))
        .overlay(
            RoundedRectangle(cornerRadius: Tokens.Radius.lg, style: .continuous)
                .strokeBorder(theme.accentColor.opacity(0.4), lineWidth: 1))
        .shadow(color: .black.opacity(0.18), radius: 14, y: 6)
        .padding(14)
        .onAppear { refresh() }
    }

    private func refresh() {
        conditions = state.repos.conditions()
    }
}

// MARK: — Petri-dish illustration

private struct PetriDishIllustration: View {
    let isOver: Bool
    @Environment(AppTheme.self) private var theme

    private let dots: [(x: CGFloat, y: CGFloat, w: CGFloat, h: CGFloat, opacity: Double)] = [
        (0.32, 0.24, 6, 6, 0.7),
        (0.58, 0.38, 4, 4, 0.5),
        (0.28, 0.55, 5, 5, 0.6),
        (0.62, 0.62, 6, 6, 0.65),
        (0.48, 0.45, 7, 7, 0.55),
        (0.72, 0.30, 4, 4, 0.45),
    ]

    var body: some View {
        Canvas { ctx, size in
            let bgGrad = Gradient(colors: [Tokens.bg, Tokens.bgSunken, Color.black.opacity(0.08)])
            ctx.fill(
                Path(ellipseIn: CGRect(origin: .zero, size: size)),
                with: .radialGradient(bgGrad,
                                      center: CGPoint(x: size.width/2, y: size.height/2),
                                      startRadius: 0,
                                      endRadius: size.width/2)
            )

            ctx.stroke(
                Path(ellipseIn: CGRect(origin: .zero, size: size).insetBy(dx: 0.75, dy: 0.75)),
                with: .color(Tokens.textTertiary),
                lineWidth: 1.5
            )

            let inset1: CGFloat = 10
            ctx.stroke(
                Path(ellipseIn: CGRect(origin: .zero, size: size).insetBy(dx: inset1, dy: inset1)),
                with: .color(Tokens.textTertiary.opacity(0.5)),
                style: StrokeStyle(lineWidth: 1, dash: [4, 3])
            )

            let inset2: CGFloat = 22
            ctx.stroke(
                Path(ellipseIn: CGRect(origin: .zero, size: size).insetBy(dx: inset2, dy: inset2)),
                with: .color(Tokens.textTertiary.opacity(0.35)),
                style: StrokeStyle(lineWidth: 1, dash: [4, 3])
            )

            for d in dots {
                let x = d.x * size.width - d.w/2
                let y = d.y * size.height - d.h/2
                ctx.fill(
                    Path(ellipseIn: CGRect(x: x, y: y, width: d.w, height: d.h)),
                    with: .color(isOver
                        ? Color(OKLCH(0.685, 0.155, 30)).opacity(d.opacity)
                        : Color(OKLCH(0.685, 0.155, 195)).opacity(d.opacity))
                )
            }
        }
        .animation(Tokens.Motion.ease, value: isOver)
    }
}

// MARK: — Shortcuts grid

private struct ShortcutsGrid: View {
    @Bindable var state: AppState
    @Environment(AppTheme.self) private var theme

    var body: some View {
        let columns = Array(repeating: GridItem(.flexible(), spacing: 10), count: 4)
        LazyVGrid(columns: columns, spacing: 10) {
            ShortcutTile(icon: "ruler", label: "Calibrate scale", sub: "px / µm") {
                state.showCalibration = true
            }
            ShortcutTile(icon: "cpu", label: state.activeModelName, sub: "Active model") {
                state.view = .models
            }
            ShortcutTile(icon: "sparkles", label: "Fine-tune…", sub: "Train on your cells") {
                state.view = .fineTune
            }
            ShortcutTile(icon: "settings", label: "Settings", sub: "Bins, palette, paths") {
                state.view = .settings
            }
        }
    }
}

private struct ShortcutTile: View {
    let icon: String
    let label: String
    let sub: String
    let action: () -> Void

    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 6) {
                Icon(icon, size: 18)
                    .foregroundStyle(Tokens.textSecondary)
                    .frame(width: 24, height: 24)

                VStack(alignment: .leading, spacing: 1) {
                    Text(label)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Tokens.text)
                        .lineLimit(1)
                    Text(sub)
                        .font(.system(size: 11.5))
                        .foregroundStyle(Tokens.textTertiary)
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: Tokens.Radius.lg, style: .continuous)
                    .fill(hovered ? Tokens.hover : Tokens.bgElevated)
            )
            .overlay(
                RoundedRectangle(cornerRadius: Tokens.Radius.lg, style: .continuous)
                    .strokeBorder(Tokens.border, lineWidth: 0.5)
            )
            .offset(y: hovered ? -1 : 0)
            .animation(Tokens.Motion.easeFast, value: hovered)
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
    }
}

// MARK: — Recents section

private struct RecentsSection: View {
    @Bindable var state: AppState
    @Environment(AppTheme.self) private var theme

    var body: some View {
        // Derive Recent rows from `state.recentBatchIds` (an @Observable mirror
        // on AppState) so SwiftUI re-renders when batches are added/deleted.
        let real: [BatchRecord] = state.recentBatchIds.compactMap { state.repos.batch(id: $0) }
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                Text("RECENT")
                    .font(.system(size: 13, weight: .semibold))
                    .tracking(0.04 * 13)
                    .foregroundStyle(Tokens.textSecondary)
                Spacer()
                if !real.isEmpty {
                    Button {
                        state.view = .batch
                    } label: {
                        Text("Show all")
                            .font(.system(size: 12))
                            .foregroundStyle(theme.accentColor)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.bottom, 12)

            VStack(spacing: 1) {
                if real.isEmpty {
                    VStack(spacing: 6) {
                        Text("No analyses yet")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(Tokens.textSecondary)
                        Text("Drop an image or folder above to get started.")
                            .font(.system(size: 12))
                            .foregroundStyle(Tokens.textTertiary)
                    }
                    .padding(.vertical, 36)
                    .frame(maxWidth: .infinity)
                } else {
                    ForEach(Array(real.enumerated()), id: \.element.id) { idx, batch in
                        RecentRow(batch: batch,
                                  isFirst: idx == 0,
                                  isLast: idx == real.count - 1) {
                            state.openBatch(batch)
                        }
                    }
                }
            }
            .background(
                RoundedRectangle(cornerRadius: Tokens.Radius.lg, style: .continuous)
                    .fill(Tokens.bgElevated)
            )
            .overlay(
                RoundedRectangle(cornerRadius: Tokens.Radius.lg, style: .continuous)
                    .strokeBorder(Tokens.border, lineWidth: 0.5)
            )
            .clipShape(RoundedRectangle(cornerRadius: Tokens.Radius.lg, style: .continuous))
        }
    }
}

private struct RecentRow: View {
    let batch: BatchRecord
    let isFirst: Bool
    let isLast: Bool
    let action: () -> Void

    @State private var hovered = false
    // Thumbnail is loaded off-main and cached; previously body hit disk per row.
    @State private var thumb: NSImage? = nil
    @State private var thumbLoaded: Bool = false

    private var firstImage: ImageRecord? {
        batch.images.sorted(by: { $0.importedAt < $1.importedAt }).first
    }

    private var thumbSeed: Int {
        abs(batch.id.uuidString.hashValue) % 1000
    }

    private var subtitle: String {
        let n = batch.images.count
        let cells = batch.totalCells
        let imgWord = n == 1 ? "image" : "images"
        return "\(cells) cells · \(n) \(imgWord)"
    }

    /// An empty batch (0 images) is a transient artefact — cleanup deletes
    /// these on sight, but in the brief window before that we disable the row
    /// so a tap can't strand the user in ResultsView's empty state.
    private var isEmpty: Bool { batch.images.isEmpty }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 14) {
                Group {
                    if let nsImg = thumb {
                        Image(nsImage: nsImg)
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                    } else {
                        ThumbDots(seed: thumbSeed)
                    }
                }
                .frame(width: 48, height: 48)
                .clipShape(RoundedRectangle(cornerRadius: Tokens.Radius.md, style: .continuous))
                .onAppear {
                    guard !thumbLoaded, let img = firstImage else { return }
                    thumbLoaded = true
                    let url = img.thumbURL
                    Task.detached(priority: .utility) {
                        let ns = NSImage(contentsOf: url)
                        await MainActor.run { thumb = ns }
                    }
                }

                VStack(alignment: .leading, spacing: 2) {
                    Text(batch.displayName)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Tokens.text)
                        .lineLimit(1)
                    Text(subtitle)
                        .font(.system(size: 11.5))
                        .foregroundStyle(Tokens.textTertiary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                Text(batch.totalCells.formatted())
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(Tokens.textSecondary)

                Text(RelativeDateFormatter.string(from: batch.createdAt))
                    .font(.system(size: 11.5))
                    .foregroundStyle(Tokens.textTertiary)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(hovered ? Tokens.hover : Color.clear)
        }
        .buttonStyle(.plain)
        .disabled(isEmpty)
        .opacity(isEmpty ? 0.55 : 1)
        .help(isEmpty ? "This batch has no images yet." : "")
        .onHover { hovered = $0 && !isEmpty }
        .overlay(alignment: .top) {
            if !isFirst {
                Rectangle()
                    .fill(Tokens.divider)
                    .frame(height: 0.5)
            }
        }
    }
}

private struct SampleRecentRow: View {
    let batch: RecentBatch
    let isFirst: Bool
    let isLast: Bool

    @State private var hovered = false

    var body: some View {
        HStack(spacing: 14) {
            ThumbDots(seed: batch.seed)
                .frame(width: 48, height: 48)
                .clipShape(RoundedRectangle(cornerRadius: Tokens.Radius.md, style: .continuous))

            VStack(alignment: .leading, spacing: 2) {
                Text(batch.name)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Tokens.text)
                    .lineLimit(1)
                Text("\(batch.count) cells · 12 images")
                    .font(.system(size: 11.5))
                    .foregroundStyle(Tokens.textTertiary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Text(batch.count.formatted())
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(Tokens.textSecondary)

            Text(batch.when)
                .font(.system(size: 11.5))
                .foregroundStyle(Tokens.textTertiary)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(hovered ? Tokens.hover : Color.clear)
        .onHover { hovered = $0 }
        .overlay(alignment: .top) {
            if !isFirst {
                Rectangle()
                    .fill(Tokens.divider)
                    .frame(height: 0.5)
            }
        }
    }
}

// MARK: — Relative date helper

private enum RelativeDateFormatter {
    static func string(from date: Date) -> String {
        let cal = Calendar.current
        let now = Date()
        let secs = now.timeIntervalSince(date)

        if secs < 60 { return "Just now" }
        if secs < 3600 {
            let m = Int(secs / 60)
            return "\(m) minute\(m == 1 ? "" : "s") ago"
        }
        if secs < 3600 * 6 {
            let h = Int(secs / 3600)
            return "\(h) hour\(h == 1 ? "" : "s") ago"
        }
        let tf = DateFormatter()
        tf.dateFormat = "HH:mm"
        if cal.isDateInToday(date) {
            return "Today, \(tf.string(from: date))"
        }
        if cal.isDateInYesterday(date) {
            return "Yesterday, \(tf.string(from: date))"
        }
        let df = DateFormatter()
        let sameYear = cal.component(.year, from: date) == cal.component(.year, from: now)
        df.dateFormat = sameYear ? "MMM d" : "MMM d, yyyy"
        return df.string(from: date)
    }
}

// MARK: — ProcessingView
//
// The progress bar is driven purely by `state.processingProgress`, the preview
// shows the actual image thumbnail when available, and a stuck-state watchdog
// surfaces a Cancel hint after ~20s of no movement.

struct ProcessingView: View {
    @Bindable var state: AppState
    @Environment(AppTheme.self) private var theme

    @State private var thumb: NSImage? = nil
    @State private var nowTick: Date = Date()
    @State private var tickTimer: Timer? = nil

    /// Seconds since AppState last received a cellpose log line. If both
    /// progress AND stage lines have been quiet for a long time we surface
    /// the "looks stuck" hint. Cellpose CPU runs are LONG (60–120s on a
    /// 5 MP image) so the threshold is generous.
    private var secondsSinceActivity: TimeInterval {
        let lastSignal = max(state.lastStageUpdateAt.timeIntervalSinceReferenceDate, 0)
        return nowTick.timeIntervalSinceReferenceDate - lastSignal
    }
    private var looksStuck: Bool {
        // 90s of zero stderr signals from the subprocess = legitimately stuck.
        // Cellpose itself emits tqdm bars + log lines every few seconds during
        // inference, so 90s of silence almost always means the subprocess died
        // or is wedged.
        secondsSinceActivity > 90
    }

    private var modelLabel: String {
        let name = state.activeModelName
        // Pass-14: prefer the device the subprocess actually reported via its
        // "using device: <name>" log line; fall back to the user-toggle guess
        // only until that line arrives.
        let device: String
        if !state.processingDevice.isEmpty {
            device = state.processingDevice
        } else {
            device = state.useGPU ? "GPU" : "CPU"
        }
        return "\(name) · \(device)"
    }

    private var stage: String {
        if looksStuck {
            return "Detection is taking longer than expected…"
        }
        let live = state.processingStageLine
        if !live.isEmpty {
            return live
        }
        if state.processingProgress <= 0 {
            return "Starting detector…"
        }
        return "Detecting cells…"
    }

    var body: some View {
        VStack(spacing: 24) {
            previewArea
                .frame(width: 420, height: 280)
                .clipShape(RoundedRectangle(cornerRadius: Tokens.Radius.xl, style: .continuous))
                .shadow(color: .black.opacity(0.12), radius: 12, y: 4)
                .transition(.opacity.combined(with: .offset(y: 6)))

            CircularProgress(pct: state.processingProgress)
                .frame(width: 80, height: 80)

            VStack(spacing: 4) {
                Text(stage)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(looksStuck ? Tokens.danger : Tokens.text)
                    .animation(nil, value: stage)

                Text(modelLabel)
                    .font(.system(size: 12))
                    .foregroundStyle(Tokens.textTertiary)
            }

            if looksStuck {
                Text("If this doesn't move for another minute, cancel and check the Models tab — the Python install may be incomplete.")
                    .font(.system(size: 11.5))
                    .foregroundStyle(Tokens.textTertiary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 360)
            }

            Button {
                // Pass-14: narrow this to terminateDetectionTasks() so Cancel
                // kills only the detection subprocess, not a concurrent
                // install. willTerminate still uses terminateAll() at quit.
                ChildProcessTracker.shared.terminateDetectionTasks()
                state.processingProgress = 0
                state.view = .home
            } label: { Text("Cancel") }
                .appButton(.standard)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear {
            loadThumb()
            // Seed lastStageUpdateAt so the watchdog timer starts fresh.
            state.lastStageUpdateAt = Date()
            nowTick = Date()
            tickTimer?.invalidate()
            tickTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { _ in
                Task { @MainActor in nowTick = Date() }
            }
        }
        // Reload thumbnail via .task(id:) — SwiftUI cancels the prior run for
        // us if currentImageIdx changes again before the load completes, and
        // it doesn't fire from inside a render pass like onChange did.
        .task(id: state.currentImageIdx) { await loadThumbAsync() }
        .onDisappear { tickTimer?.invalidate(); tickTimer = nil }
    }

    @ViewBuilder
    private var previewArea: some View {
        ZStack {
            if let img = thumb {
                Image(nsImage: img)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: 420, height: 280)
                    .clipped()
                    .overlay(Color.black.opacity(0.12))
            } else {
                LinearGradient(
                    colors: [Tokens.bgSunken, Tokens.bgElevated],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
                Icon("image", size: 28)
                    .foregroundStyle(Tokens.textQuaternary)
            }
        }
    }

    private func loadThumb() {
        Task { await loadThumbAsync() }
    }

    private func loadThumbAsync() async {
        guard let url = state.currentImage?.thumbURL else {
            if thumb != nil { thumb = nil }
            return
        }
        let img = await Task.detached(priority: .utility) {
            NSImage(contentsOf: url)
        }.value
        thumb = img
    }
}

// MARK: — Circular progress ring

private struct CircularProgress: View {
    let pct: Double
    @Environment(AppTheme.self) private var theme

    private let radius: CGFloat = 32
    private var circumference: CGFloat { 2 * .pi * radius }

    var body: some View {
        ZStack {
            Circle()
                .strokeBorder(Tokens.border, lineWidth: 3)

            Circle()
                .trim(from: 0, to: CGFloat(pct))
                .stroke(
                    theme.accentColor,
                    style: StrokeStyle(lineWidth: 3, lineCap: .round)
                )
                .rotationEffect(.degrees(-90))
                .animation(.linear(duration: 0.1), value: pct)

            Text("\(Int(pct * 100))%")
                .font(.system(size: 13, weight: .semibold, design: .monospaced))
                .foregroundStyle(Tokens.text)
                .contentTransition(.numericText())
                .animation(Tokens.Motion.ease, value: pct)
        }
    }
}
