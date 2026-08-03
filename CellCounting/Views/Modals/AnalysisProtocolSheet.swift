import SwiftUI
import AppKit

/// Save/apply a named, versioned snapshot of the current analysis settings
/// ("analysis protocols" in the task brief). Chrome mirrors
/// `CalibrationSheet`/`InstallCellposeSheet` (blur backdrop + centered card
/// with header/body/footer) so it looks native to CellCounter's existing
/// modal system.
///
/// NOT YET WIRED UP: this view is presented the same way every other
/// `state.showX` sheet is — see `RootView.swift`'s
/// `if state.showCalibration { CalibrationSheet(...) }` blocks. Add a
/// matching block there:
/// ```swift
/// if state.showAnalysisProtocols {
///     AnalysisProtocolSheet(state: state, onClose: { state.showAnalysisProtocols = false })
///         .transition(.opacity.combined(with: .move(edge: .top)))
///         .zIndex(55)
/// }
/// ```
/// plus a menu item / toolbar button that sets `state.showAnalysisProtocols
/// = true` — `AnalysisProtocolCommands.swift` (also in this pass) already
/// provides that as a `Commands` group; wire it in via
/// `.commands { AnalysisProtocolCommands(state: state) }` next to the
/// existing `CommandMenu("Analysis")` block. `RootView.swift` and
/// `CellCountingApp.swift` are outside this agent's ownership for this pass
/// — see the task's file-ownership list — so this view exists and works
/// standalone but isn't reachable from the UI yet.
struct AnalysisProtocolSheet: View {
    @Bindable var state: AppState
    let onClose: () -> Void

    @State private var appeared = false
    @State private var entries: [AnalysisProtocolStore.LibraryEntry] = []
    @State private var newName: String = ""
    @State private var newNotes: String = ""
    @State private var statusMessage: String? = nil
    @State private var statusIsError = false
    @State private var clearWorkItem: DispatchWorkItem? = nil

    var body: some View {
        ZStack {
            Tokens.bgOverlay
                .background(.ultraThinMaterial)
                .ignoresSafeArea()
                .onTapGesture { onClose() }

            VStack(spacing: 0) {
                header
                    .padding(.horizontal, 24)
                    .padding(.top, 20)
                    .padding(.bottom, 16)

                Divider().overlay(Tokens.divider)

                ScrollView {
                    VStack(alignment: .leading, spacing: 22) {
                        saveSection
                        librarySection
                    }
                    .padding(.horizontal, 24)
                    .padding(.vertical, 18)
                }
                .frame(maxHeight: 420)

                footer
            }
            .frame(width: 620)
            .background(Tokens.bg)
            .clipShape(RoundedRectangle(cornerRadius: Tokens.Radius.xl, style: .continuous))
            .shadow(color: .black.opacity(0.22), radius: 60, y: 24)
            .offset(y: appeared ? 0 : -12)
            .opacity(appeared ? 1 : 0)
            .scaleEffect(appeared ? 1 : 0.98)
        }
        .onAppear {
            withAnimation(Tokens.Motion.easeSlow) { appeared = true }
            refresh()
            if newName.isEmpty { newName = defaultProtocolName() }
        }
        .keyboardShortcut(.cancelAction)
    }

    // MARK: — Header

    private var header: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Analysis protocols")
                    .font(.system(size: 18, weight: .bold))
                    .tracking(-0.01 * 18)
                    .foregroundStyle(Tokens.text)
                Text("Save the model, calibration, size bins, and preprocessing as a named file — apply it later so a whole lab runs identical settings, or cite it in a methods section.")
                    .font(.system(size: 12.5))
                    .foregroundStyle(Tokens.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            Button(action: onClose) {
                Icon("x", size: 14)
                    .foregroundStyle(Tokens.textSecondary)
                    .frame(width: 26, height: 26)
                    .background(RoundedRectangle(cornerRadius: Tokens.Radius.md, style: .continuous).fill(Tokens.bgSunken))
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.cancelAction)
        }
    }

    // MARK: — Save current settings

    private var saveSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionHeader(title: "Save current settings")

            Text(currentSettingsSummary)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(Tokens.textTertiary)
                .fixedSize(horizontal: false, vertical: true)

            TextField("Protocol name (e.g. \u{201c}Keratinocyte 10\u{d7} \u{2014} lab standard\u{201d})", text: $newName)
                .textFieldStyle(.plain)
                .font(.system(size: 12.5))
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .background(RoundedRectangle(cornerRadius: Tokens.Radius.sm, style: .continuous).fill(Tokens.bgSunken))
                .overlay(RoundedRectangle(cornerRadius: Tokens.Radius.sm, style: .continuous).strokeBorder(Tokens.borderStrong, lineWidth: 0.5))

            TextField("Notes (optional) \u{2014} instrument, objective, purpose…", text: $newNotes)
                .textFieldStyle(.plain)
                .font(.system(size: 12))
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .background(RoundedRectangle(cornerRadius: Tokens.Radius.sm, style: .continuous).fill(Tokens.bgSunken))
                .overlay(RoundedRectangle(cornerRadius: Tokens.Radius.sm, style: .continuous).strokeBorder(Tokens.borderStrong, lineWidth: 0.5))

            HStack(spacing: 8) {
                Button {
                    saveToLibrary()
                } label: {
                    HStack(spacing: 6) { Icon("plus", size: 12); Text("Save to library") }
                }
                .appButton(.primary, size: .sm)
                .disabled(trimmedName.isEmpty)

                Button {
                    saveAs()
                } label: {
                    HStack(spacing: 6) { Icon("download", size: 12); Text("Save As\u{2026}") }
                }
                .appButton(.standard, size: .sm)
                .disabled(trimmedName.isEmpty)

                Spacer(minLength: 0)

                Button {
                    openFile()
                } label: {
                    HStack(spacing: 6) { Icon("file", size: 12); Text("Open\u{2026}") }
                }
                .appButton(.standard, size: .sm)
            }

            if let statusMessage {
                HStack(spacing: 6) {
                    Icon(statusIsError ? "triangle-alert" : "check", size: 11)
                        .foregroundStyle(statusIsError ? Tokens.danger : Tokens.success)
                    Text(statusMessage)
                        .font(.system(size: 11.5))
                        .foregroundStyle(Tokens.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .transition(.opacity)
            }
        }
        .animation(Tokens.Motion.ease, value: statusMessage)
    }

    private var currentSettingsSummary: String {
        let bins = state.thresholds.map(\.trimmedString).joined(separator: ", ")
        return "Current: \(state.activeModelName) \u{b7} \(String(format: "%.2f", state.pxPerUm)) px/\u{b5}m \u{b7} confidence \u{2265} \(String(format: "%.2f", state.confidence)) \u{b7} bins [\(bins)] \u{b5}m"
    }

    // MARK: — Library

    private var librarySection: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionHeader(title: "Saved protocols")

            if entries.isEmpty {
                Text("No saved protocols yet \u{2014} save the current settings above, or Open\u{2026} a shared .ccproto.json file.")
                    .font(.system(size: 12))
                    .foregroundStyle(Tokens.textTertiary)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 14)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: Tokens.Radius.md, style: .continuous).strokeBorder(Tokens.border, lineWidth: 0.5))
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(entries.enumerated()), id: \.element.id) { idx, entry in
                        AnalysisProtocolRow(
                            entry: entry,
                            onApply: { applyAndFlash(entry.analysisProtocol) },
                            onReveal: { NSWorkspace.shared.activateFileViewerSelecting([entry.url]) },
                            onDelete: { delete(entry) }
                        )
                        if idx < entries.count - 1 {
                            Divider().padding(.horizontal, 14)
                        }
                    }
                }
                .background(RoundedRectangle(cornerRadius: Tokens.Radius.md, style: .continuous).strokeBorder(Tokens.border, lineWidth: 0.5))
            }
        }
    }

    // MARK: — Footer

    private var footer: some View {
        HStack(spacing: 8) {
            Spacer()
            Button("Close", action: onClose)
                .appButton(.standard)
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 14)
        .background(Tokens.bgSunken)
        .overlay(alignment: .top) {
            Divider().frame(maxWidth: .infinity, maxHeight: 0.5)
        }
    }

    // MARK: — Actions

    private var trimmedName: String { newName.trimmingCharacters(in: .whitespacesAndNewlines) }

    private func defaultProtocolName() -> String {
        let f = DateFormatter()
        f.dateFormat = "MMM d, yyyy"
        return "\(state.activeModelName) \u{2014} \(f.string(from: Date()))"
    }

    private func refresh() {
        entries = AnalysisProtocolStore.libraryEntries()
    }

    private func saveToLibrary() {
        guard !trimmedName.isEmpty else { return }
        let snapshot = state.makeAnalysisProtocolSnapshot(name: trimmedName, notes: newNotes)
        do {
            _ = try AnalysisProtocolStore.saveToLibrary(snapshot)
            flash("Saved \u{201c}\(trimmedName)\u{201d} to the protocol library.", isError: false)
            refresh()
        } catch {
            flash(error.localizedDescription, isError: true)
        }
    }

    private func saveAs() {
        guard !trimmedName.isEmpty else { return }
        let snapshot = state.makeAnalysisProtocolSnapshot(name: trimmedName, notes: newNotes)
        let suggested = "\(ExportService.sanitizeFilename(trimmedName)).ccproto.json"
        AnalysisProtocolStore.presentSavePanel(suggestedName: suggested) { url in
            guard let url else { return }
            do {
                try AnalysisProtocolStore.save(snapshot, to: url)
                flash("Saved to \(url.lastPathComponent).", isError: false)
                refresh()
            } catch {
                flash(error.localizedDescription, isError: true)
            }
        }
    }

    private func openFile() {
        AnalysisProtocolStore.presentOpenPanel { url in
            guard let url else { return }
            do {
                let p = try AnalysisProtocolStore.load(from: url)
                applyAndFlash(p)
            } catch {
                flash(error.localizedDescription, isError: true)
            }
        }
    }

    /// Applies `p` to `state` (the actual mutation lives in
    /// `AppState.apply(_:)`) and turns the result into UI feedback — a
    /// blocking alert for an install warning, or a transient inline "Applied"
    /// message when everything (including the model) applied cleanly.
    private func applyAndFlash(_ p: AnalysisProtocol) {
        let warning = state.apply(p)
        if let warning {
            presentWarning(warning, protocolName: p.name)
        } else {
            flash("Applied \u{201c}\(p.name).\u{201d}", isError: false)
        }
    }

    private func delete(_ entry: AnalysisProtocolStore.LibraryEntry) {
        do {
            try AnalysisProtocolStore.deleteFromLibrary(entry.url)
            refresh()
        } catch {
            flash(error.localizedDescription, isError: true)
        }
    }

    private func flash(_ message: String, isError: Bool) {
        statusMessage = message
        statusIsError = isError
        clearWorkItem?.cancel()
        let item = DispatchWorkItem {
            withAnimation(Tokens.Motion.ease) { statusMessage = nil }
        }
        clearWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.0, execute: item)
    }

    /// Blocking alert so an install warning can never be missed or silently
    /// swallowed — matches the `NSAlert` pattern `SettingsView.AboutSection`
    /// already uses for its own important confirmations.
    private func presentWarning(_ message: String, protocolName: String) {
        let alert = NSAlert()
        alert.messageText = "Applied \u{201c}\(protocolName)\u{201d} with a warning"
        alert.informativeText = message
        alert.alertStyle = .warning
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }
}

private struct AnalysisProtocolRow: View {
    let entry: AnalysisProtocolStore.LibraryEntry
    let onApply: () -> Void
    let onReveal: () -> Void
    let onDelete: () -> Void

    @State private var hovering = false

    private var p: AnalysisProtocol { entry.analysisProtocol }

    private var subtitle: String {
        let f = DateFormatter()
        f.dateFormat = "MMM d, yyyy"
        let dateStr = f.string(from: p.createdAt)
        let bins = p.sizeBins.thresholdsUm.map(\.trimmedString).joined(separator: ", ")
        return "\(p.model.name) \u{b7} \(String(format: "%.2f", p.calibration.pxPerUm)) px/\u{b5}m \u{b7} bins [\(bins)] \u{b5}m \u{b7} \(dateStr)"
    }

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(p.name)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Tokens.text)
                Text(subtitle)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(Tokens.textTertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if !p.notes.isEmpty {
                    Text(p.notes)
                        .font(.system(size: 11))
                        .foregroundStyle(Tokens.textSecondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 8)
            if hovering {
                Button(action: onReveal) { Icon("folder", size: 12) }
                    .appButton(.ghost, size: .sm)
                    .help("Reveal in Finder")
                Button(action: onDelete) { Icon("trash", size: 12) }
                    .appButton(.ghost, size: .sm)
                    .help("Delete")
            }
            Button("Apply", action: onApply)
                .appButton(.primary, size: .sm)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(hovering ? Tokens.hover : Color.clear)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .animation(Tokens.Motion.easeFast, value: hovering)
    }
}
