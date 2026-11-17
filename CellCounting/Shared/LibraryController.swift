import AppKit
import Darwin
import Observation
import SwiftData
import SwiftUI
import UniformTypeIdentifiers

/// One entry of File ▸ Open Recent Library.
struct RecentLibrary: Identifiable, Equatable {
    let url: URL
    let name: String
    let isArchive: Bool
    let isAvailable: Bool
    var id: String { url.path }

    var menuTitle: String {
        var title = name
        if isArchive { title += " (Archive)" }
        let parent = url.deletingLastPathComponent().lastPathComponent
        if !parent.isEmpty && parent != "/" { title += " — \(parent)" }
        if !isAvailable { title += " (not available)" }
        return title
    }
}

/// The data library this process opened, and switching to another one.
///
/// `FileStore.shared` and the SwiftData container are chosen once per
/// process, so switching saves, remembers the new choice, launches a fresh
/// instance of the app and quits this one. The new instance waits for this
/// one to exit before it opens anything (`LibraryRelaunch`).
@Observable @MainActor
final class LibraryController {
    let resolution: LibraryResolution
    /// "Default Library", or the library's manifest/folder name.
    let displayName: String
    /// A library produced by "Archive Batch…".
    let isArchive: Bool
    /// Why the requested library could not be opened at launch, if it could not.
    var startupNotice: String?
    /// The safety copy made before this launch upgraded the library's
    /// database; shown once until dismissed.
    var upgradeBackupURL: URL?
    /// Message for the library alert.
    var alertMessage: String?
    private(set) var recentLibraries: [RecentLibrary] = []
    private(set) var isSwitching = false
    private(set) var switchingTargetName = ""

    @ObservationIgnored private let preferences: LibraryPreferences
    @ObservationIgnored private var volumeObservers: [NSObjectProtocol] = []

    init(resolution: LibraryResolution? = nil, defaults: UserDefaults = .standard) {
        let resolution = resolution ?? FileStore.shared.resolution
        self.resolution = resolution
        self.preferences = LibraryPreferences(defaults: defaults, isEnabled: resolution.usesPreferences)
        let manifest = resolution.library.readManifest()
        self.isArchive = manifest?.kind == .batchArchive
        self.displayName = resolution.isDefaultLibrary
            ? LibrarySelection.defaultLibraryName
            : resolution.library.displayName
        self.startupNotice = resolution.notice
        self.switchingUnavailableReason = Self.switchingUnavailableReason(
            for: resolution.source, environment: ProcessInfo.processInfo.environment)
        refreshRecentLibraries()
        // A recent library on an external drive becomes available (or not)
        // when the drive is connected or ejected.
        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didMountNotification, NSWorkspace.didUnmountNotification] {
            volumeObservers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor [weak self] in self?.refreshRecentLibraries() }
            })
        }
    }

    var libraryRoot: URL { resolution.library.root }
    var isDefaultLibrary: Bool { resolution.isDefaultLibrary }
    /// "Archive" for batch archives, otherwise "Library".
    var kindLabel: String { isArchive ? "Archive" : "Library" }

    /// e.g. "Keratinocytes 2026 · 212 images". Uses the count AppState
    /// already keeps; no extra store work.
    func summary(imageCount: Int) -> String {
        "\(displayName) · \(imageCount) image\(imageCount == 1 ? "" : "s")"
    }

    // MARK: - Availability

    /// Non-nil when this process can never switch library.
    let switchingUnavailableReason: String?

    nonisolated static func switchingUnavailableReason(for source: LibraryResolution.Source,
                                                       environment: [String: String]) -> String? {
        switch source {
        case .testProcess:
            return "Libraries cannot be switched while CellCounter is running tests."
        case .environment where LibrarySelection.dataRootOverride(environment) == nil:
            return "Libraries cannot be switched because \(LibrarySelection.dataRootVariable) is not an absolute path."
        default:
            return nil
        }
    }

    /// Non-nil while work is running that a relaunch would interrupt.
    func busyReason(_ state: AppState) -> String? {
        if state.isPreparingImport { return "Images are being imported." }
        let jobs = state.jobScheduler
        if jobs.activeCount > 0 || jobs.activeJobId != nil || jobs.previewItemId != nil {
            return "An analysis is running or queued. Pause or cancel it under Processing jobs first."
        }
        if TrainingService.isTrainingActive { return "A model is being trained." }
        if state.preparingLibraryMigration { return "Library data is being copied into a project." }
        let workbench = state.workbenchSession
        if workbench.hasActiveWorkers || workbench.busy { return "The Workbench is still working." }
        if !workbench.canRefreshWithoutDiscardingEdits {
            return "The Workbench has unsaved changes. Save or discard them first."
        }
        return nil
    }

    private func ensureCanSwitch(_ state: AppState) -> Bool {
        guard !isSwitching else { return false }
        if let reason = switchingUnavailableReason {
            alertMessage = reason
            return false
        }
        if let reason = busyReason(state) {
            alertMessage = "CellCounter cannot switch library right now. \(reason)"
            return false
        }
        return true
    }

    // MARK: - Menu actions

    func presentNewLibrary(state: AppState) {
        guard ensureCanSwitch(state) else { return }
        let panel = NSSavePanel()
        panel.title = "New Library"
        panel.message = "A library keeps its own images, analyses and database. Use one per project or per year."
        panel.prompt = "Create"
        panel.nameFieldLabel = "Library name:"
        panel.nameFieldStringValue = "Untitled Library"
        panel.canCreateDirectories = true
        if let type = UTType(filenameExtension: LibraryLayout.packageExtension) {
            panel.allowedContentTypes = [type]
        }
        let copyBox = NSButton(checkboxWithTitle: "Copy calibration presets, size-bin presets and conditions from “\(displayName)”",
                               target: nil, action: nil)
        copyBox.state = .on
        copyBox.sizeToFit()
        let accessory = NSView(frame: NSRect(x: 0, y: 0, width: copyBox.frame.width + 40, height: copyBox.frame.height + 20))
        copyBox.setFrameOrigin(NSPoint(x: 20, y: 10))
        accessory.addSubview(copyBox)
        panel.accessoryView = accessory

        guard panel.runModal() == .OK, let chosen = panel.url else { return }
        let url = LibraryCreator.normalizedURL(for: chosen)
        let name = (url.lastPathComponent as NSString).deletingPathExtension
        do {
            let starter = copyBox.state == .on
                ? try LibraryStarterContent.capture(from: state.repos.context)
                : LibraryStarterContent.fresh
            try LibraryCreator.create(at: url, name: name, starter: starter)
        } catch {
            alertMessage = "The library could not be created. \(error.localizedDescription)"
            return
        }
        switchTo(url, isDefault: false, state: state)
    }

    func presentOpenLibrary(state: AppState) {
        guard ensureCanSwitch(state) else { return }
        let panel = NSOpenPanel()
        panel.title = "Open Library"
        panel.message = "Choose a CellCounter library (.\(LibraryLayout.packageExtension)) or a batch archive."
        panel.prompt = "Open"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        open(url, state: state)
    }

    /// Opens any folder the user picked, explaining refusals in plain language.
    func open(_ url: URL, state: AppState) {
        if LibrarySelection.samePath(url, resolution.appRoot) {
            switchTo(resolution.appRoot, isDefault: true, state: state)
            return
        }
        guard LibraryLayout.isLibrary(at: url) else {
            alertMessage = Self.notALibraryMessage(for: url)
            return
        }
        switchTo(url, isDefault: false, state: state)
    }

    nonisolated static func notALibraryMessage(for url: URL) -> String {
        if let parent = LibraryCreator.enclosingLibrary(of: url) {
            return "“\(url.lastPathComponent)” is a folder inside the library “\(LibraryLayout(root: parent).displayName)”. Choose the library folder itself: \(parent.path)"
        }
        var isDirectory: ObjCBool = false
        if !FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) {
            return "“\(url.lastPathComponent)” could not be found at \(url.path). If it is on an external or network drive, connect the drive and try again."
        }
        return "“\(url.lastPathComponent)” is not a CellCounter library. A library is a folder made with File ▸ New Library… or Archive Batch…, and it contains a database file named store.sqlite. To add the images in this folder to the open library, use Choose folder… in the Library overview instead."
    }

    func openRecent(_ recent: RecentLibrary, state: AppState) {
        guard ensureCanSwitch(state) else { return }
        guard LibraryLayout.isLibrary(at: recent.url) else {
            refreshRecentLibraries()
            alertMessage = Self.notALibraryMessage(for: recent.url)
            return
        }
        open(recent.url, state: state)
    }

    func openDefaultLibrary(state: AppState) {
        guard ensureCanSwitch(state) else { return }
        switchTo(resolution.appRoot, isDefault: true, state: state)
    }

    func showLibraryInFinder() {
        NSWorkspace.shared.activateFileViewerSelecting([libraryRoot])
    }

    func clearRecentLibraries() {
        preferences.clearRecentLibraries()
        refreshRecentLibraries()
    }

    func refreshRecentLibraries() {
        recentLibraries = preferences.recentLibraryURLs
            .filter { !LibrarySelection.samePath($0, libraryRoot) && !LibrarySelection.samePath($0, resolution.appRoot) }
            .map { url in
                let layout = LibraryLayout(root: url)
                let available = LibraryLayout.isLibrary(at: url)
                let manifest = available ? layout.readManifest() : nil
                let fallbackName = url.pathExtension.lowercased() == LibraryLayout.packageExtension
                    ? (url.lastPathComponent as NSString).deletingPathExtension : url.lastPathComponent
                let name = manifest?.name.trimmingCharacters(in: .whitespacesAndNewlines)
                return RecentLibrary(url: url, name: (name?.isEmpty == false ? name : nil) ?? fallbackName,
                                     isArchive: manifest?.kind == .batchArchive, isAvailable: available)
            }
    }

    // MARK: - Switching

    /// Saves, remembers `target`, launches a new instance and quits this one.
    /// Nothing is remembered or quit unless the new instance was launched.
    func switchTo(_ target: URL, isDefault: Bool, state: AppState) {
        guard ensureCanSwitch(state) else { return }
        guard !LibrarySelection.samePath(target, libraryRoot) else {
            alertMessage = "“\(displayName)” is already open."
            return
        }
        isSwitching = true
        switchingTargetName = isDefault ? LibrarySelection.defaultLibraryName : LibraryLayout(root: target).displayName
        Task { @MainActor in
            do {
                try await state.saveForLibrarySwitch()
            } catch {
                isSwitching = false
                alertMessage = "Your changes could not be saved, so the library was not switched. \(error.localizedDescription)"
                return
            }
            if let reason = busyReason(state) {
                isSwitching = false
                alertMessage = "CellCounter cannot switch library right now. \(reason)"
                return
            }

            let previousPreference = preferences.currentLibraryPath
            preferences.setCurrentLibrary(target, isDefaultLibrary: isDefault)

            let configuration = NSWorkspace.OpenConfiguration()
            configuration.createsNewApplicationInstance = true
            configuration.activates = true
            configuration.addsToRecentItems = false
            let underOverride = resolution.source == .environment
            configuration.arguments = LibraryRelaunch.arguments(
                previousProcess: getpid(),
                expectedDataRoot: underOverride ? resolution.appRoot.path : nil)
            let environment = LibraryRelaunch.environment(for: resolution, target: target, targetIsDefault: isDefault)
            if !environment.isEmpty { configuration.environment = environment }

            do {
                _ = try await NSWorkspace.shared.openApplication(at: Bundle.main.bundleURL, configuration: configuration)
            } catch {
                preferences.restoreCurrentLibraryPath(previousPreference)
                refreshRecentLibraries()
                isSwitching = false
                alertMessage = "CellCounter could not restart with the other library, so “\(displayName)” stays open. \(error.localizedDescription)"
                return
            }
            // Final save for anything that landed while the new instance
            // started; it waits for this process to exit before opening files.
            try? state.repos.context.save()
            NSApp.terminate(nil)
            // Only reached if termination was cancelled. The other library is
            // already open in the new instance; say so instead of hanging.
            isSwitching = false
            alertMessage = "The other library opened in a new CellCounter window, but this one could not quit. Quit this window (⌘Q) so only one library stays open."
        }
    }
}

/// File-menu commands for libraries. Kept apart from `AppKeyboardCommands`,
/// which owns the Workbench "Microscopy Project" commands.
struct LibraryCommands: Commands {
    let state: AppState

    var body: some Commands {
        CommandGroup(after: .newItem) {
            Divider()
            Button("New Library…") { libraries.presentNewLibrary(state: state) }
                .disabled(!canSwitch)
            Button("Open Library…") { libraries.presentOpenLibrary(state: state) }
                .disabled(!canSwitch)
            Menu("Open Recent Library") {
                ForEach(libraries.recentLibraries) { recent in
                    Button(recent.menuTitle) { libraries.openRecent(recent, state: state) }
                        .disabled(!recent.isAvailable || !canSwitch)
                }
                if !libraries.recentLibraries.isEmpty { Divider() }
                Button("Clear Menu") { libraries.clearRecentLibraries() }
                    .disabled(libraries.recentLibraries.isEmpty)
            }
            .disabled(libraries.switchingUnavailableReason != nil)
            Button("Open Default Library") { libraries.openDefaultLibrary(state: state) }
                .disabled(!canSwitch || libraries.isDefaultLibrary)
            Button("Show Library in Finder") { libraries.showLibraryInFinder() }
        }
    }

    private var libraries: LibraryController { state.libraries }
    /// While an import, analysis or training runs the items stay enabled and
    /// explain why switching has to wait (see `busyReason`), rather than
    /// being greyed out without a reason.
    private var canSwitch: Bool {
        !KeyboardShortcutContext.hasOverlay(state) && !KeyboardShortcutContext.hasNativeSheet
            && libraries.switchingUnavailableReason == nil && !libraries.isSwitching
    }
}
