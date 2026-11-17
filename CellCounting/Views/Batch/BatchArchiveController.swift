import SwiftUI
import AppKit

/// User-facing flow for "Archive Batch…", "Restore Archived Batch…" and the
/// "Archive or delete this batch?" choice that replaces direct batch deletion.
@MainActor
enum BatchArchiveController {
    private static var isRunning = false

    // MARK: - Remove (archive or delete)

    /// The single entry point for every user-initiated batch removal.
    static func confirmRemoval(of batchId: UUID, state: AppState) {
        guard let batch = state.repos.batch(id: batchId) else { return }
        let alert = NSAlert()
        alert.messageText = "Archive or delete this batch?"
        alert.informativeText = """
        Archiving moves “\(title(of: batch))” — its images, cell outlines and calibration — into a folder you choose, checks the copy, and frees the space in your library. You can restore it at any time.

        Deleting removes the batch permanently. It cannot be undone.
        """
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Archive…")
        let delete = alert.addButton(withTitle: "Delete Permanently")
        delete.hasDestructiveAction = true
        delete.keyEquivalent = ""
        let cancel = alert.addButton(withTitle: "Cancel")
        cancel.keyEquivalent = "\u{1b}"
        switch alert.runModal() {
        case .alertFirstButtonReturn:
            beginArchive(batchId: batchId, state: state)
        case .alertSecondButtonReturn:
            confirmPermanentDeletion(batchId: batchId, state: state)
        default:
            return
        }
    }

    private static func confirmPermanentDeletion(batchId: UUID, state: AppState) {
        guard let batch = state.repos.batch(id: batchId) else { return }
        let images = batch.imageCount
        let alert = NSAlert()
        alert.messageText = "Delete “\(title(of: batch))” permanently?"
        alert.informativeText = "This removes \(images) image\(images == 1 ? "" : "s"), every cell outline and measurement, and the batch calibration from this Mac. It cannot be undone. To keep a copy, cancel and choose Archive instead."
        alert.alertStyle = .critical
        let delete = alert.addButton(withTitle: "Delete Permanently")
        delete.hasDestructiveAction = true
        // No Return shortcut: a permanent delete needs a deliberate click.
        delete.keyEquivalent = ""
        let cancel = alert.addButton(withTitle: "Cancel")
        cancel.keyEquivalent = "\u{1b}"
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        do {
            try state.repos.deleteBatch(batch)
        } catch {
            state.flashExport("The batch could not be deleted: \(error.localizedDescription)", isError: true)
            return
        }
        afterRemoval(of: batchId, state: state)
    }

    private static func afterRemoval(of batchId: UUID, state: AppState) {
        if state.currentBatchId == batchId {
            state.currentBatchId = nil
            if state.view == .batch || state.view == .results { state.view = .home }
        }
        NotificationCenter.default.post(name: .ccLibraryChanged, object: nil)
    }

    // MARK: - Archive

    static func beginArchive(batchId: UUID, state: AppState) {
        guard !isRunning else { NSSound.beep(); return }
        guard let batch = state.repos.batch(id: batchId) else { return }
        let busy: Set<AnalysisJobStatus> = [.queued, .running, .pausing]
        if state.jobScheduler.jobs.contains(where: { $0.batchId == batchId && busy.contains($0.status) }) {
            showMessage("This batch is still being analyzed",
                        "Pause or finish the analysis in the queue before archiving it. Nothing was changed.")
            return
        }
        let folder = BatchArchiveService.defaultArchiveFolder()
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let panel = NSSavePanel()
        panel.title = "Archive Batch"
        panel.message = "The batch, its images, cell outlines and calibration are copied into this folder and checked. Only then is the batch removed from your library."
        panel.prompt = "Archive"
        panel.directoryURL = folder
        panel.nameFieldStringValue = BatchArchiveService.defaultArchiveName(displayName: batch.displayName,
                                                                            name: batch.name)
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false
        panel.canSelectHiddenExtension = false
        panel.begin { response in
            guard response == .OK, var url = panel.url else { return }
            if url.pathExtension.lowercased() != LibraryLayout.packageExtension {
                url.appendPathExtension(LibraryLayout.packageExtension)
            }
            Task { @MainActor in await runArchive(batchId: batchId, to: url, state: state) }
        }
    }

    private static func runArchive(batchId: UUID, to url: URL, state: AppState) async {
        guard !isRunning, let batch = state.repos.batch(id: batchId) else { return }
        isRunning = true
        defer { isRunning = false }
        let name = title(of: batch)
        let model = BatchArchiveProgressModel(title: "Archiving “\(name)”")
        let service = BatchArchiveService(repos: state.repos, exportContext: .live(state))
        service.onProgress = { model.update($0) }
        let task = Task { @MainActor in try await service.archive(batchId: batchId, to: url) }
        model.cancel = { model.isCancelling = true; task.cancel() }
        let sheet = ProgressSheet(model: model)
        sheet.show()
        let result = await task.result
        sheet.close()

        switch result {
        case .success(let archive):
            afterRemoval(of: batchId, state: state)
            let info = archive.manifest.archivedBatch
            let images = info?.imageCount ?? 0
            let cells = info?.cellCount ?? 0
            let alert = NSAlert()
            alert.messageText = "Batch archived"
            alert.informativeText = """
            “\(name)” (\(images) image\(images == 1 ? "" : "s"), \(cells) cells) was saved to \(prettyPath(archive.archiveURL)), checked, and removed from your library.

            To bring it back, choose File > Restore Archived Batch… and select that folder.
            """
            alert.addButton(withTitle: "OK")
            alert.addButton(withTitle: "Show in Finder")
            if alert.runModal() == .alertSecondButtonReturn {
                NSWorkspace.shared.activateFileViewerSelecting([archive.archiveURL])
            }
        case .failure(let error) where error is CancellationError:
            state.flashExport("Archiving cancelled. Nothing was changed.", isError: false)
        case .failure(let error):
            let message = (error as? BatchArchiveError)?.errorDescription
                ?? "\(error.localizedDescription) The incomplete archive was removed and nothing was changed in your library."
            showMessage("The batch could not be archived", message, style: .critical)
        }
    }

    // MARK: - Restore

    static func beginRestore(state: AppState) {
        guard !isRunning else { NSSound.beep(); return }
        let panel = NSOpenPanel()
        panel.title = "Restore Archived Batch"
        panel.message = "Choose a .cellcounterlibrary archive folder. Its batch is copied back into this library; the archive itself is not changed."
        panel.prompt = "Restore"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = false
        let folder = BatchArchiveService.defaultArchiveFolder()
        if FileManager.default.fileExists(atPath: folder.path) { panel.directoryURL = folder }
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            Task { @MainActor in await runRestore(from: url, state: state) }
        }
    }

    private static func runRestore(from url: URL, state: AppState) async {
        guard !isRunning else { return }
        isRunning = true
        defer { isRunning = false }
        let model = BatchArchiveProgressModel(title: "Restoring “\(url.deletingPathExtension().lastPathComponent)”")
        let service = BatchArchiveService(repos: state.repos, exportContext: .live(state))
        service.onProgress = { model.update($0) }
        let task = Task { @MainActor in try await service.restore(from: url) }
        model.cancel = { model.isCancelling = true; task.cancel() }
        let sheet = ProgressSheet(model: model)
        sheet.show()
        let result = await task.result
        sheet.close()

        switch result {
        case .success(let restored):
            let names = restored.batches.map { "“\($0.name)”" }.joined(separator: ", ")
            let images = restored.batches.reduce(0) { $0 + $1.imageCount }
            let alert = NSAlert()
            alert.messageText = restored.batches.count == 1 ? "Batch restored" : "Batches restored"
            alert.informativeText = "\(names) (\(images) image\(images == 1 ? "" : "s")) is back in your library with its outlines, measurements and calibration. The archive folder was not changed."
            alert.addButton(withTitle: "Open Batch")
            alert.addButton(withTitle: "OK")
            if alert.runModal() == .alertFirstButtonReturn, let first = restored.batches.first {
                state.openBatch(id: first.id)
            }
        case .failure(let error) where error is CancellationError:
            state.flashExport("Restore cancelled. Nothing was changed.", isError: false)
        case .failure(let error):
            let message = (error as? BatchArchiveError)?.errorDescription
                ?? "\(error.localizedDescription) Nothing was restored and the archive was not changed."
            showMessage("The batch could not be restored", message, style: .critical)
        }
    }

    // MARK: - Helpers

    private static func title(of batch: BatchRecord) -> String {
        batch.displayName.isEmpty ? batch.name : batch.displayName
    }

    private static func prettyPath(_ url: URL) -> String {
        let home = NSHomeDirectory()
        return url.path.hasPrefix(home) ? "~" + url.path.dropFirst(home.count) : url.path
    }

    private static func showMessage(_ title: String, _ text: String, style: NSAlert.Style = .warning) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = text
        alert.alertStyle = style
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }
}

// MARK: - Progress sheet

@MainActor
@Observable
final class BatchArchiveProgressModel {
    let title: String
    var phase: BatchArchiveService.Phase = .reading
    var fraction: Double?
    var detail = ""
    var isCancelling = false
    @ObservationIgnored var cancel: () -> Void = {}

    init(title: String) { self.title = title }

    var canCancel: Bool { phase.isCancellable && !isCancelling }

    func update(_ progress: BatchArchiveService.Progress) {
        phase = progress.phase
        fraction = progress.fraction
        detail = progress.total > 1 ? "\(progress.completed) of \(progress.total)" : ""
    }
}

private struct BatchArchiveProgressView: View {
    let model: BatchArchiveProgressModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(model.title)
                .font(.headline)
                .lineLimit(2)
            Text(model.isCancelling ? "Cancelling and removing the incomplete copy…" : model.phase.title)
                .font(.subheadline)
                .foregroundStyle(.secondary)
            if let fraction = model.fraction {
                ProgressView(value: fraction)
            } else {
                ProgressView().progressViewStyle(.linear)
            }
            HStack {
                Text(model.detail)
                    .font(.caption)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Cancel") { model.cancel() }
                    .keyboardShortcut(.cancelAction)
                    .disabled(!model.canCancel)
            }
        }
        .padding(20)
        .frame(width: 440)
    }
}

/// Window-modal sheet: the window stays live (progress, Cancel) while the
/// batch being moved cannot be edited underneath the operation.
@MainActor
private final class ProgressSheet {
    private let window: NSWindow
    private weak var parent: NSWindow?

    init(model: BatchArchiveProgressModel) {
        let host = NSHostingController(rootView: BatchArchiveProgressView(model: model))
        window = NSWindow(contentViewController: host)
        window.styleMask = [.titled]
        window.isReleasedWhenClosed = false
        window.title = model.title
    }

    func show() {
        parent = NSApp.mainWindow ?? NSApp.keyWindow
            ?? NSApp.windows.first { $0.isVisible && !($0 is NSPanel) }
        if let parent {
            parent.beginSheet(window)
        } else {
            window.center()
            window.makeKeyAndOrderFront(nil)
        }
    }

    func close() {
        if let parent, window.sheetParent != nil {
            parent.endSheet(window)
        }
        window.orderOut(nil)
    }
}

// MARK: - File menu

struct BatchArchiveCommands: Commands {
    let state: AppState

    var body: some Commands {
        CommandGroup(after: .importExport) {
            Divider()
            Button("Archive Batch…") {
                if let id = archivableBatchId { BatchArchiveController.beginArchive(batchId: id, state: state) }
            }
            .disabled(archivableBatchId == nil)
            Button("Restore Archived Batch…") { BatchArchiveController.beginRestore(state: state) }
                .disabled(isBlocked)
        }
    }

    /// The open batch, when a batch screen is showing it.
    private var archivableBatchId: UUID? {
        guard !isBlocked, state.view == .batch || state.view == .results else { return nil }
        return state.currentBatchId
    }

    private var isBlocked: Bool {
        KeyboardShortcutContext.hasOverlay(state) || KeyboardShortcutContext.hasNativeSheet
    }
}
