import SwiftUI
import AppKit
import UniformTypeIdentifiers

struct LocalDiagnosticsSheet: View {
    let state: AppState
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var session = LocalPerformanceSession.shared
    @State private var sessionMinutes = 30
    @State private var includeState = false
    @State private var includeTimings = false
    @State private var draft: String?
    @State private var reviewed = false
    @State private var saving = false
    @State private var message = ""
    private let limit = 64 * 1024
    private var validDraft: Bool { guard let draft else { return false }; return !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && draft.utf8.count <= limit }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Local diagnostics & performance").font(.title2.bold())
                Spacer()
                Button("Close") { dismiss() }.disabled(saving)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Reports are prepared only on request. Nothing is uploaded automatically. The basic report contains the app version and platform. Images, measurements, names, paths, IDs, logs and crash dumps are excluded.")
                    Text("Benchmark real workflows").font(.headline)
                    Text("Start recording, then use your real images and normal analysis, queue, review and export controls. Return here to stop and prepare a report. Only fixed operation categories and numeric summaries are retained, in memory, for the session limit you choose. A crash or app exit loses unsaved results.")
                    Text(session.active ? "Real-workflow timing is recording." : "Timing is stopped.").accessibilityAddTraits(.updatesFrequently)
                    Picker("Session limit", selection: $sessionMinutes) { Text("10 minutes").tag(10); Text("30 minutes").tag(30); Text("2 hours").tag(120) }.disabled(session.active || saving)
                    HStack {
                        Button("Start recording") { session.start(minutes: sessionMinutes) }.disabled(session.active || saving)
                        Button("Stop") { session.stop() }.disabled(!session.active || saving)
                        Button("Erase timings and draft") { session.clear(); draft = nil; reviewed = false; message = "Recorded timings and draft erased." }.disabled(saving)
                    }
                    Text("No synthetic data or automatic reanalysis is used. Normal analysis uses your chosen settings and saves normal results. Timings can reveal workload characteristics; inspect them before sharing.").font(.callout)
                    if let text = draft {
                        Text("Inspect and redact the report. Only this editable text is exported; prepared reports do not update automatically.").font(.headline)
                        TextEditor(text: Binding(get: { draft ?? "" }, set: { draft = String($0.prefix(65536)); reviewed = false; message = "" }))
                            .font(.system(size: 12, design: .monospaced))
                            .autocorrectionDisabled()
                            .frame(minHeight: 280)
                            .disabled(saving)
                            .accessibilityLabel("Editable diagnostic report")
                        if text.utf8.count > limit || text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { Text("The report must contain text and fit within 64 KiB.").foregroundStyle(.red) }
                        Toggle("I inspected this text and removed anything I do not want to share.", isOn: $reviewed).disabled(saving)
                        HStack {
                            Button("Export reviewed text…", action: save).disabled(!reviewed || !validDraft || saving)
                            Button("Discard draft") { draft = nil; reviewed = false; message = "" }.disabled(saving)
                        }
                        Text("Anything you add may contain personal information. Your chosen export destination may be synced by other software. No automatic draft backup is made, and CellCounter does not share the exported file.").font(.callout)
                    } else {
                        Toggle("Include optional state summary (approximate counts and status flags)", isOn: $includeState)
                        Toggle("Include recorded real-workflow timings", isOn: $includeTimings)
                        Button("Prepare editable preview", action: generate)
                    }
                    if !message.isEmpty { Text(message).accessibilityLabel(message) }
                }
            }
        }
        .padding(24).frame(minWidth: 650, idealWidth: 700, minHeight: 600, idealHeight: 730)
        .interactiveDismissDisabled(saving)
        .onDisappear { draft = nil; reviewed = false; message = "" }
    }
    private func band(_ count: Int) -> String {
        switch count { case ..<0: return "unknown"; case 0: return "0"; case 1...10: return "1–10"; case 11...100: return "11–100"; case 101...1000: return "101–1,000"; default: return "over 1,000" }
    }
    private func generate() {
        let raw = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "unknown"
        let version = raw.range(of: #"^\d{1,4}\.\d{1,4}\.\d{1,4}$"#, options: .regularExpression) != nil ? raw : "unknown"
        var lines = ["CellCounter local diagnostics · format 1", "", "Application version: \(version)", "Platform: macOS", "", "Prepared locally on request. Recording requires explicit opt-in. No automatic uploads.", "Excluded: images, measurements, names, IDs, paths, logs, crash dumps, device identifiers, network details and timestamps."]
        if includeState {
            lines += ["", "Optional state snapshot (cached; may be stale or incomplete):", "Library images: \(band(state.libraryImageCount))", "Library batches: \(band(state.libraryBatchCount))", "Review candidates: \(band(state.reviewQueueCount))", "Review index building: \(state.isReviewIndexing ? "yes" : "no")", "Review index error present: \(state.reviewIndexError != nil ? "yes" : "no")", "Detection error present: \(state.lastDetectionError != nil ? "yes" : "no")"]
        }
        if includeTimings { lines += ["", LocalPerformanceRecorder.shared.report()] }
        lines += ["", "This report does not reproduce a crash or diagnose its cause.", ""]
        draft = lines.joined(separator: "\n"); reviewed = false; message = ""
    }
    private func save() {
        guard !saving, reviewed, validDraft, let text = draft else { return }
        saving = true
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "CellCounter-diagnostics.txt"
        panel.allowedContentTypes = [.plainText]
        panel.canCreateDirectories = true
        panel.begin { response in
            defer { saving = false }
            guard response == .OK, let url = panel.url else { message = "Export cancelled. Nothing was saved."; return }
            do { try text.write(to: url, atomically: true, encoding: .utf8); message = "Reviewed text saved. Nothing was uploaded." }
            catch { message = "Could not save the report. The editable draft is still available; choose a writable destination and retry." }
        }
    }
}

struct LocalTimingIndicator: View {
    @ObservedObject private var session = LocalPerformanceSession.shared
    var body: some View {
        if session.active {
            Button("Local timing is recording · Stop") { session.stop() }
                .buttonStyle(.borderedProminent).padding(12)
        }
    }
}
