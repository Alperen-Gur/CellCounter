import Darwin
import Foundation

/// Which app-wide folder and which library this process uses, and why.
///
/// Resolution order (see `LibrarySelection.resolve`):
/// 1. `CELLCOUNTER_DATA_ROOT` / `TEST_RUNNER_CELLCOUNTER_DATA_ROOT`, or an
///    XCTest host. Preferences are neither read nor written in this mode.
/// 2. The library remembered in preferences.
/// 3. The Default Library, which is the app-wide folder itself.
nonisolated struct LibraryResolution: Sendable, Equatable {
    nonisolated enum Source: String, Sendable {
        /// `CELLCOUNTER_DATA_ROOT` or `TEST_RUNNER_CELLCOUNTER_DATA_ROOT` is set.
        case environment
        /// Running inside an XCTest host without an explicit data root.
        case testProcess
        /// The library remembered from an earlier "New/Open Library…".
        case remembered
        /// The legacy folder that also holds the app-wide resources.
        case defaultLibrary
    }

    let appRoot: URL
    let library: LibraryLayout
    let source: Source
    /// Plain-language explanation when the requested library could not be
    /// opened and another one was opened instead.
    let notice: String?

    /// Only a normal interactive launch reads or writes the library preference.
    var usesPreferences: Bool { source == .remembered || source == .defaultLibrary }

    /// The Default Library shares its folder with the app-wide resources.
    var isDefaultLibrary: Bool { LibrarySelection.samePath(library.root, appRoot) }
}

/// The remembered library and the "Open Recent Library" list.
///
/// Every accessor is inert when `isEnabled` is false, so tests and benchmarks
/// running under an environment override can never touch real preferences.
nonisolated struct LibraryPreferences {
    static let currentLibraryKey = "cc-library-current-path"
    static let recentLibrariesKey = "cc-library-recent-paths"
    static let maximumRecentLibraries = 8

    let defaults: UserDefaults
    let isEnabled: Bool

    /// The stored preference exactly as written; nil means the Default Library.
    var currentLibraryPath: String? {
        guard isEnabled, let path = defaults.string(forKey: Self.currentLibraryKey),
              path.hasPrefix("/") else { return nil }
        return path
    }

    var currentLibraryURL: URL? {
        currentLibraryPath.map { URL(fileURLWithPath: $0, isDirectory: true) }
    }

    /// Most recent first, at most `maximumRecentLibraries`, no duplicates.
    var recentLibraryURLs: [URL] {
        guard isEnabled else { return [] }
        var seen = Set<String>()
        var result: [URL] = []
        for path in defaults.stringArray(forKey: Self.recentLibrariesKey) ?? [] where path.hasPrefix("/") {
            let url = URL(fileURLWithPath: path, isDirectory: true)
            guard seen.insert(LibrarySelection.comparablePath(url)).inserted else { continue }
            result.append(url)
            if result.count == Self.maximumRecentLibraries { break }
        }
        return result
    }

    /// Remembers the library to open at the next launch. The Default Library
    /// is stored as "no choice", which is exactly the pre-library behaviour.
    func setCurrentLibrary(_ url: URL, isDefaultLibrary: Bool) {
        guard isEnabled else { return }
        if isDefaultLibrary {
            defaults.removeObject(forKey: Self.currentLibraryKey)
        } else {
            defaults.set(url.standardizedFileURL.path, forKey: Self.currentLibraryKey)
            addRecentLibrary(url)
        }
    }

    /// Puts back a value read earlier with `currentLibraryPath`.
    func restoreCurrentLibraryPath(_ path: String?) {
        guard isEnabled else { return }
        if let path { defaults.set(path, forKey: Self.currentLibraryKey) }
        else { defaults.removeObject(forKey: Self.currentLibraryKey) }
    }

    func addRecentLibrary(_ url: URL) {
        guard isEnabled else { return }
        let key = LibrarySelection.comparablePath(url)
        let others = recentLibraryURLs.filter { LibrarySelection.comparablePath($0) != key }
        let paths = ([url] + others).prefix(Self.maximumRecentLibraries).map { $0.standardizedFileURL.path }
        defaults.set(Array(paths), forKey: Self.recentLibrariesKey)
    }

    /// "Clear Menu". The library that is currently remembered stays remembered.
    func clearRecentLibraries() {
        guard isEnabled else { return }
        defaults.removeObject(forKey: Self.recentLibrariesKey)
    }
}

nonisolated enum LibrarySelection {
    static let dataRootVariable = "CELLCOUNTER_DATA_ROOT"
    static let testRunnerDataRootVariable = "TEST_RUNNER_CELLCOUNTER_DATA_ROOT"
    /// Only honoured together with an absolute data-root override. Lets a test
    /// or benchmark run (and a relaunch from one) open a separate library while
    /// app-wide resources stay in the override folder.
    static let libraryRootVariable = "CELLCOUNTER_LIBRARY_ROOT"
    static let defaultLibraryName = "Default Library"

    // MARK: - Environment

    /// True when either data-root variable is present, even if it is unusable.
    /// Any such process is treated as non-interactive and never touches the
    /// library preference.
    static func hasDataRootVariable(_ environment: [String: String]) -> Bool {
        environment[dataRootVariable] != nil || environment[testRunnerDataRootVariable] != nil
    }

    /// The absolute data-root override, or nil.
    static func dataRootOverride(_ environment: [String: String]) -> URL? {
        guard let value = environment[dataRootVariable] ?? environment[testRunnerDataRootVariable],
              value.hasPrefix("/") else { return nil }
        return URL(fileURLWithPath: value, isDirectory: true)
    }

    static func isTestProcess(_ environment: [String: String]) -> Bool {
        environment["XCTestConfigurationFilePath"] != nil || environment["XCTestBundlePath"] != nil
    }

    static func standardAppRoot() -> URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("CellCounter", isDirectory: true)
    }

    /// The app-wide folder. Reads only the environment: no preferences, no disk.
    static func appRoot(environment: [String: String],
                        standardAppRoot: URL,
                        temporaryDirectory: URL,
                        processIdentifier: Int32) -> URL {
        if let override = dataRootOverride(environment) { return override }
        if isTestProcess(environment) {
            return temporaryDirectory.appendingPathComponent("CellCounter-tests-\(processIdentifier)", isDirectory: true)
        }
        return standardAppRoot
    }

    static func appRootForCurrentProcess() -> URL {
        appRoot(environment: ProcessInfo.processInfo.environment,
                standardAppRoot: standardAppRoot(),
                temporaryDirectory: FileManager.default.temporaryDirectory,
                processIdentifier: ProcessInfo.processInfo.processIdentifier)
    }

    // MARK: - Resolution

    static func resolve(environment: [String: String],
                        defaults: UserDefaults,
                        standardAppRoot: URL,
                        temporaryDirectory: URL,
                        processIdentifier: Int32) -> LibraryResolution {
        let appRoot = appRoot(environment: environment, standardAppRoot: standardAppRoot,
                              temporaryDirectory: temporaryDirectory,
                              processIdentifier: processIdentifier)
        let fallback = LibraryLayout(root: appRoot)

        if hasDataRootVariable(environment) {
            if dataRootOverride(environment) != nil,
               let requested = environment[libraryRootVariable], requested.hasPrefix("/") {
                let url = URL(fileURLWithPath: requested, isDirectory: true)
                if samePath(url, appRoot) || LibraryLayout.isLibrary(at: url) {
                    return LibraryResolution(appRoot: appRoot, library: LibraryLayout(root: url),
                                             source: .environment, notice: nil)
                }
                return LibraryResolution(appRoot: appRoot, library: fallback, source: .environment,
                                         notice: unavailableNotice(for: url, fallbackName: "the data folder set by \(dataRootVariable)"))
            }
            return LibraryResolution(appRoot: appRoot, library: fallback, source: .environment, notice: nil)
        }
        if isTestProcess(environment) {
            return LibraryResolution(appRoot: appRoot, library: fallback, source: .testProcess, notice: nil)
        }

        let preferences = LibraryPreferences(defaults: defaults, isEnabled: true)
        guard let remembered = preferences.currentLibraryURL, !samePath(remembered, appRoot) else {
            return LibraryResolution(appRoot: appRoot, library: fallback, source: .defaultLibrary, notice: nil)
        }
        if LibraryLayout.isLibrary(at: remembered) {
            return LibraryResolution(appRoot: appRoot, library: LibraryLayout(root: remembered),
                                     source: .remembered, notice: nil)
        }
        // Keep the preference: when the drive comes back, the next launch
        // opens the library again. Never create anything at the missing path.
        return LibraryResolution(appRoot: appRoot, library: fallback, source: .defaultLibrary,
                                 notice: unavailableNotice(for: remembered, fallbackName: "the \(defaultLibraryName)"))
    }

    static func resolveForCurrentProcess() -> LibraryResolution {
        resolve(environment: ProcessInfo.processInfo.environment,
                defaults: .standard,
                standardAppRoot: standardAppRoot(),
                temporaryDirectory: FileManager.default.temporaryDirectory,
                processIdentifier: ProcessInfo.processInfo.processIdentifier)
    }

    static func unavailableNotice(for url: URL, fallbackName: String) -> String {
        let name = LibraryLayout(root: url).displayName
        var isDirectory: ObjCBool = false
        if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue {
            return "The folder “\(name)” at \(url.path) is not a Cellographer library (it has no store.sqlite), so \(fallbackName) was opened instead."
        }
        return "Cellographer could not find the library “\(name)” at \(url.path). If it is on an external or network drive, connect the drive and choose File ▸ Open Recent Library. \(fallbackName.prefix(1).uppercased() + fallbackName.dropFirst()) is open for now."
    }

    // MARK: - Paths

    /// Path used to decide whether two URLs name the same library.
    static func comparablePath(_ url: URL) -> String {
        url.standardizedFileURL.resolvingSymlinksInPath().path
    }

    static func samePath(_ lhs: URL, _ rhs: URL) -> Bool {
        comparablePath(lhs) == comparablePath(rhs)
    }
}

extension LibraryLayout {
    /// Manifest name, else the folder name without the package extension.
    nonisolated var displayName: String {
        if let name = readManifest()?.name.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty {
            return name
        }
        let folder = root.lastPathComponent
        if root.pathExtension.lowercased() == Self.packageExtension {
            return (folder as NSString).deletingPathExtension
        }
        return folder
    }

    /// Creates the data folders inside an existing library root. Never creates
    /// the root itself, so an unplugged drive is not recreated as an empty
    /// local folder under /Volumes.
    nonisolated func createSubdirectoriesIfRootExists() {
        let fm = FileManager.default
        var isDirectory: ObjCBool = false
        guard fm.fileExists(atPath: root.path, isDirectory: &isDirectory), isDirectory.boolValue else { return }
        for dir in [imagesDir, displayImagesDir, thumbsDir, embeddingsDir, exportsDir] {
            try? fm.createDirectory(at: dir, withIntermediateDirectories: false)
        }
    }
}

/// Command-line handshake between the instance that switches library and the
/// instance it launches.
nonisolated enum LibraryRelaunch {
    /// The new instance waits for this process to exit before opening anything.
    static let waitForProcessArgument = "--cellcounter-wait-for-pid"
    /// Set when the switching instance ran under a data-root override. The new
    /// instance refuses to start unless the same override reached it, so a
    /// relaunch from a test folder can never fall through to the real library.
    static let expectedDataRootArgument = "--cellcounter-expected-data-root"

    nonisolated struct Request: Equatable {
        var previousProcess: Int32?
        var expectedDataRoot: String?
    }

    static func parse(_ arguments: [String]) -> Request {
        var request = Request()
        var index = 0
        while index < arguments.count {
            let argument = arguments[index]
            let value = index + 1 < arguments.count ? arguments[index + 1] : nil
            if argument == waitForProcessArgument, let value, let pid = Int32(value), pid > 0 {
                request.previousProcess = pid
                index += 2
            } else if argument == expectedDataRootArgument, let value, value.hasPrefix("/") {
                request.expectedDataRoot = value
                index += 2
            } else {
                index += 1
            }
        }
        return request
    }

    static func arguments(previousProcess: Int32, expectedDataRoot: String?) -> [String] {
        var result = [waitForProcessArgument, String(previousProcess)]
        if let expectedDataRoot { result += [expectedDataRootArgument, expectedDataRoot] }
        return result
    }

    /// Environment for the new instance when the current one runs under a
    /// data-root override. Empty for a normal launch, which reads preferences.
    static func environment(for resolution: LibraryResolution, target: URL, targetIsDefault: Bool) -> [String: String] {
        guard resolution.source == .environment else { return [:] }
        var environment = [LibrarySelection.dataRootVariable: resolution.appRoot.path]
        if !targetIsDefault { environment[LibrarySelection.libraryRootVariable] = target.standardizedFileURL.path }
        return environment
    }

    /// False when the launch arguments demand a data-root override that is not present.
    static func environmentSatisfies(_ request: Request, environment: [String: String]) -> Bool {
        guard let expected = request.expectedDataRoot else { return true }
        return environment[LibrarySelection.dataRootVariable] == expected
    }

    /// Polls until `pid` has exited. Returns false on timeout.
    @discardableResult
    static func waitForExit(of pid: Int32, timeout: TimeInterval) -> Bool {
        guard pid > 0, pid != getpid() else { return true }
        let deadline = Date().addingTimeInterval(timeout)
        while true {
            if kill(pid, 0) != 0 && errno == ESRCH { return true }
            if Date() >= deadline { return false }
            usleep(50_000)
        }
    }

    /// First thing the app does at launch, before FileStore is touched.
    static func prepareForLaunch(arguments: [String] = CommandLine.arguments,
                                 environment: [String: String] = ProcessInfo.processInfo.environment) {
        let request = parse(arguments)
        guard environmentSatisfies(request, environment: environment) else {
            FileHandle.standardError.write(Data("CellCounter: this relaunch expected \(LibrarySelection.dataRootVariable)=\(request.expectedDataRoot ?? "") and the environment does not match. Quitting without opening any library.\n".utf8))
            exit(78)
        }
        if let pid = request.previousProcess {
            // The previous instance saved before launching us and quits right
            // after. Waiting means the two never run against shared files at
            // the same time; on timeout we continue, because the previous
            // instance had a different library open.
            waitForExit(of: pid, timeout: 10)
        }
    }
}
