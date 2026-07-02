import Foundation

/// Owns the on-disk layout under `~/Library/Application Support/CellCounter/`.
/// All file operations that aren't covered by SwiftData go through here.
struct FileStore {
    static let shared = FileStore()

    let root: URL

    init() {
        let fm = FileManager.default
        let appSupport = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        self.root = appSupport.appendingPathComponent("CellCounter", isDirectory: true)

        // Best-effort migration from a previous sandboxed install. We turned
        // off App Sandbox in pass 10; before that the data lived under
        // ~/Library/Containers/alguer.CellCounting/Data/Library/Application Support/CellCounter/.
        // If the new (unsandboxed) root is empty and the legacy root has
        // content, move it over so users don't lose their store.
        let legacyRoot = fm.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Containers/alguer.CellCounting/Data/Library/Application Support/CellCounter", isDirectory: true)
        if fm.fileExists(atPath: legacyRoot.path)
            && !fm.fileExists(atPath: self.root.path) {
            // Try move first (cheap, atomic if on the same volume); fall back
            // to copy if move fails (e.g. cross-volume or permissions).
            do {
                try fm.createDirectory(at: self.root.deletingLastPathComponent(),
                                       withIntermediateDirectories: true)
                try fm.moveItem(at: legacyRoot, to: self.root)
            } catch {
                try? fm.copyItem(at: legacyRoot, to: self.root)
            }
        }

        try? fm.createDirectory(at: root, withIntermediateDirectories: true)
        try? fm.createDirectory(at: imagesDir, withIntermediateDirectories: true)
        try? fm.createDirectory(at: thumbsDir, withIntermediateDirectories: true)
        try? fm.createDirectory(at: modelsDir, withIntermediateDirectories: true)
        try? fm.createDirectory(at: exportsDir, withIntermediateDirectories: true)
    }

    var imagesDir: URL  { root.appendingPathComponent("Images", isDirectory: true) }
    var thumbsDir: URL  { root.appendingPathComponent("Thumbnails", isDirectory: true) }
    var modelsDir: URL  { root.appendingPathComponent("Models", isDirectory: true) }
    var exportsDir: URL { root.appendingPathComponent("Exports", isDirectory: true) }

    /// Writeable Python sidecar root.
    ///
    /// The .app bundle is read-only inside the sandbox, so the venv and the
    /// per-model `*_detect.py` helpers are mirrored here on first install.
    /// See `CellposeAvailability.swift` for the full post-install layout.
    var pythonDir: URL { root.appendingPathComponent("python", isDirectory: true) }
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
        imagesDir.appendingPathComponent("\(imageId.uuidString).\(ext)")
    }

    func thumbURL(for imageId: UUID) -> URL {
        thumbsDir.appendingPathComponent("\(imageId.uuidString).jpg")
    }

    /// Pass-11: one-time auto-wipe of the SwiftData store + image/thumb dirs.
    ///
    /// The user reported 702 ghost cells in the Review queue from prior runs
    /// (mock-detector rows) and "recent" rows whose image files no longer exist.
    /// We wipe the on-disk store BEFORE `Repositories()` opens it, so SwiftData
    /// never tries to migrate or read the stale rows under the new schema.
    ///
    /// Preserved: `pythonDir` (venv), `modelsDir` (any custom checkpoints),
    /// `exportsDir` (user-visible export artefacts). Gated by a UserDefaults
    /// flag — fires exactly once per install.
    ///
    /// MUST be called from `CellCountingApp.init` BEFORE building `Repositories`.
    static func runMigrationsIfNeeded() {
        let flagKey = "cc-wiped-pre-clean-v1"
        guard !UserDefaults.standard.bool(forKey: flagKey) else { return }

        let fm = FileManager.default
        let store = FileStore.shared
        let root = store.root

        // 1) Delete store.sqlite + WAL/SHM siblings.
        for suffix in ["", "-wal", "-shm"] {
            let url = root.appendingPathComponent("store.sqlite\(suffix)")
            try? fm.removeItem(at: url)
        }

        // 2/3) Nuke images + thumbnails (recursive).
        try? fm.removeItem(at: store.imagesDir)
        try? fm.removeItem(at: store.thumbsDir)

        // 6) Recreate empty dirs so downstream code doesn't trip on missing paths.
        try? fm.createDirectory(at: store.imagesDir, withIntermediateDirectories: true)
        try? fm.createDirectory(at: store.thumbsDir, withIntermediateDirectories: true)

        // 5) Set the flag so we never run again.
        UserDefaults.standard.set(true, forKey: flagKey)
    }

    /// Free disk-space estimate for the storage root (for the "X MB on disk" footer).
    func diskUsageMB() -> Int {
        var total: Int64 = 0
        if let enumerator = FileManager.default.enumerator(at: root,
                                                            includingPropertiesForKeys: [.fileSizeKey],
                                                            options: [.skipsHiddenFiles]) {
            for case let url as URL in enumerator {
                if let sz = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize {
                    total += Int64(sz)
                }
            }
        }
        return Int(total / (1024 * 1024))
    }
}
