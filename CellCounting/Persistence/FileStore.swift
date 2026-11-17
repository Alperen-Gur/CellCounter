import Foundation

/// Owns the on-disk layout. All file operations that aren't covered by
/// SwiftData go through here.
///
/// Two roots, deliberately kept apart:
/// - `appRoot` (normally `~/Library/Application Support/CellCounter/`) holds
///   app-wide resources: Python runtimes, model checkpoints (`Models/`),
///   analysis protocols (`Protocols/`) and OMERO profiles.
/// - `library` holds one library's data: the SwiftData store, copied images,
///   display PNGs, thumbnails, embeddings, exports and the analysis job queue.
///
/// The Default Library is `appRoot` itself, so existing installs keep their
/// store and images exactly where they were. Other libraries are separate
/// `<name>.cellcounterlibrary` folders (see `LibraryLayout`). The library is
/// chosen once per process (`LibrarySelection`); switching relaunches the app.
struct FileStore {
    static let shared = FileStore(resolution: LibrarySelection.resolveForCurrentProcess())

    /// How the roots below were chosen (environment, preference or default).
    let resolution: LibraryResolution

    /// App-wide resources. Never library data.
    var appRoot: URL { resolution.appRoot }
    /// The library this process opened.
    var library: LibraryLayout { resolution.library }
    var libraryRoot: URL { library.root }

    /// Resolve the app-wide location without reading preferences, creating,
    /// migrating or opening a library. Headless CLI/MCP startup uses only the
    /// runtime below it.
    static func appLocation() -> URL {
        LibrarySelection.appRootForCurrentProcess()
    }

    init(resolution: LibraryResolution) {
        self.resolution = resolution
        let fm = FileManager.default
        let appRoot = resolution.appRoot

        // Best-effort migration from a previous sandboxed install. We turned
        // off App Sandbox in pass 10; before that the data lived under
        // ~/Library/Containers/alguer.CellCounting/Data/Library/Application Support/CellCounter/.
        // If the new (unsandboxed) root is empty and the legacy root has
        // content, move it over so users don't lose their store. Never under
        // an environment override or in a test process.
        let legacyRoot = fm.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Containers/alguer.CellCounting/Data/Library/Application Support/CellCounter", isDirectory: true)
        if resolution.usesPreferences
            && LibrarySelection.samePath(appRoot, LibrarySelection.standardAppRoot())
            && fm.fileExists(atPath: legacyRoot.path)
            && !fm.fileExists(atPath: appRoot.path) {
            // Try move first (cheap, atomic if on the same volume); fall back
            // to copy if move fails (e.g. cross-volume or permissions).
            do {
                try fm.createDirectory(at: appRoot.deletingLastPathComponent(),
                                       withIntermediateDirectories: true)
                try fm.moveItem(at: legacyRoot, to: appRoot)
            } catch {
                try? fm.copyItem(at: legacyRoot, to: appRoot)
            }
        }

        try? fm.createDirectory(at: appRoot, withIntermediateDirectories: true)
        try? fm.createDirectory(at: modelsDir, withIntermediateDirectories: true)
        // The Default Library's root is `appRoot`, created above. Any other
        // library was verified to exist during resolution; its root is never
        // created here, so a missing drive is not replaced by an empty folder.
        library.createSubdirectoriesIfRootExists()
    }

    // MARK: - Library data (resolves against the open library)

    /// SwiftData store of the open library.
    var storeURL: URL { library.storeURL }
    /// Persisted analysis job queue of the open library.
    var analysisJobsURL: URL { library.analysisJobsURL }
    var imagesDir: URL { library.imagesDir }
    /// Lossless, flattened PNGs for vendor containers that AppKit cannot read.
    /// The untouched source remains in `imagesDir` for detection/quantification.
    var displayImagesDir: URL { library.displayImagesDir }
    var thumbsDir: URL { library.thumbsDir }
    var exportsDir: URL { library.exportsDir }
    /// Reusable prompt-model image embeddings. Safe to delete; regenerated on demand.
    var embeddingsDir: URL { library.embeddingsDir }

    // MARK: - App-wide resources

    /// Model checkpoints (fine-tuned and trained models). Shared by all libraries.
    var modelsDir: URL { appRoot.appendingPathComponent("Models", isDirectory: true) }
    /// Analysis protocol files (`*.ccproto.json`). Shared by all libraries.
    var protocolsDir: URL { appRoot.appendingPathComponent("Protocols", isDirectory: true) }

    /// Writeable Python sidecar root.
    ///
    /// The .app bundle is read-only inside the sandbox, so the venv and the
    /// per-model `*_detect.py` helpers are mirrored here on first install.
    /// See `CellposeAvailability.swift` for the full post-install layout.
    var pythonDir: URL { appRoot.appendingPathComponent("python", isDirectory: true) }
    var pythonVenvDir: URL { pythonDir.appendingPathComponent("venv", isDirectory: true) }
    var pythonInstallScriptURL: URL { pythonDir.appendingPathComponent("install_python.sh") }

    /// `~/.../CellCounter/python/bin/python3` once the installer has finished.
    var pythonInterpreterURL: URL {
        pythonVenvDir.appendingPathComponent("bin/python3")
    }

    /// Pass-13: empty file CellposeInstaller writes at install start and removes
    /// only on a clean exit-0 finish. Any presence at app launch (or before a
    /// detection run) means the previous install was interrupted — see
    /// `CellposeAvailability.detect()` for how the read side treats it.
    ///
    /// Pass-18 (Lane K3): intentionally NOT factored into a generic
    /// `sentinelURL(for: ModelFamily)` helper. The pair below
    /// (`cellpose4InstallIncompleteSentinel`) is the symmetric 4.x mirror, and
    /// the duplication is two 2-line property accessors at a fixed pair of
    /// known filenames — the indirection would cost more in readability at
    /// the 10+ call-sites in Services/Detection than the 2 lines of code save.
    var installIncompleteSentinel: URL {
        pythonDir.appendingPathComponent(".cc-install-incomplete")
    }

    // MARK: - Pass-16: Cellpose 4.x (CPSAM) sidecar
    //
    // The 4.x install lives ENTIRELY beside the 3.x install, in a sibling
    // venv (`venv4/`) and with its own install script + its own incomplete-
    // install sentinel. The two are independent: removing or reinstalling
    // either one never touches the other.

    /// Writeable venv root for the Cellpose-SAM (4.x) install.
    var pythonVenv4Dir: URL {
        pythonDir.appendingPathComponent("venv4", isDirectory: true)
    }

    /// Staged copy of `scripts/install_python_cp4.sh`.
    var pythonInstallCp4ScriptURL: URL {
        pythonDir.appendingPathComponent("install_python_cp4.sh")
    }

    /// Interpreter inside the cp4 venv.
    var pythonInterpreter4URL: URL {
        pythonVenv4Dir.appendingPathComponent("bin/python3")
    }

    /// Mirror of `installIncompleteSentinel` for the cp4 install. Written on
    /// install start, removed only on a clean exit-0 finish. Presence means
    /// the last cp4 install was interrupted — `Cellpose4Availability.detect()`
    /// uses it the same way the 3.x path does.
    var cellpose4InstallIncompleteSentinel: URL {
        pythonDir.appendingPathComponent(".cc-install-incomplete-cp4")
    }

    /// Default user-visible exports folder (Documents/CellCounter exports).
    var defaultUserExports: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
            .appendingPathComponent("CellCounter exports", isDirectory: true)
    }

    func imageURL(for imageId: UUID, extension ext: String = "tif") -> URL {
        library.imageURL(for: imageId, extension: ext)
    }

    func thumbURL(for imageId: UUID) -> URL {
        library.thumbURL(for: imageId)
    }

    func displayImageURL(for imageId: UUID) -> URL {
        library.displayImageURL(for: imageId)
    }
}
