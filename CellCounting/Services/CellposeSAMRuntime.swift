import Foundation

/// The Cellpose-SAM (`venv4/`) package set CellCounter installs, and how an
/// existing install compares with it.
///
/// Exactly `pinnedCellposeVersion` is "installed". Any other importable
/// Cellpose 4.x is "installed, update available": analyses keep running on it
/// until the user chooses **Update Cellpose-SAM** in Models. Nothing here
/// upgrades anything by itself.
nonisolated enum CellposeSAMRuntime {
    static let pinnedCellposeVersion = "4.2.1.1"

    /// The tested set, as `pip install` arguments. Keep in sync with
    /// `CC_PIP_PACKAGES` in `scripts/install_python_cp4.sh`.
    static let pinnedPackages: [String] = [
        "cellpose==4.2.1.1",
        "torch==2.12.0",
        "torchvision==0.27.0",
        "opencv-python-headless==4.13.0.92",
        "numpy>=2,<3",
        "scipy==1.17.1",
        "scikit-image==0.26.0",
        "tifffile==2026.5.15",
        "pillow",
    ]

    /// Models only the pinned Cellpose provides (4.1.1 knew only `cpsam`).
    static let modelsNeedingPinnedVersion: Set<String> = ["cpsam_v2"]

    /// Same key as `Cellpose4Availability.importableCacheKey`.
    static let importableCacheKey = "cc-cellpose4-importable"
    /// The installed Cellpose version, written by the off-main install probe.
    static let installedVersionCacheKey = "cc-cellpose4-version"
    /// Stored when the probe found Cellpose importable but no single version.
    static let unreadableVersion = "unreadable"

    nonisolated enum Status: Equatable, Sendable {
        case notInstalled
        /// Installed, version not probed yet (e.g. the first launch after
        /// upgrading the app). Offers nothing until the probe answers.
        case checking
        case current
        /// Importable, but not the pinned version. `installed` is nil when
        /// the version could not be read.
        case updateAvailable(installed: String?)
    }

    static func status(isInstalled: Bool, version: String?) -> Status {
        guard isInstalled else { return .notInstalled }
        return version == pinnedCellposeVersion ? .current : .updateAvailable(installed: version)
    }

    /// Cached snapshot for views: reads preferences only, never the disk.
    static func cachedStatus(defaults: UserDefaults = .standard) -> Status {
        guard defaults.object(forKey: importableCacheKey) as? Bool == true else { return .notInstalled }
        guard let stored = defaults.string(forKey: installedVersionCacheKey) else { return .checking }
        return status(isInstalled: true, version: stored == unreadableVersion ? nil : stored)
    }

    /// Whether `modelId` cannot run until Cellpose-SAM is updated.
    static func needsUpdate(modelId: String, status: Status) -> Bool {
        guard modelsNeedingPinnedVersion.contains(modelId) else { return false }
        if case .updateAvailable = status { return true }
        return false
    }

    // MARK: — Installed version (filesystem only)

    /// "4.1.1" for `cellpose-4.1.1.dist-info`; nil for anything else
    /// (`cellpose_omni-…` included).
    static func version(fromDistInfo name: String) -> String? {
        let prefix = "cellpose-", suffix = ".dist-info"
        let lower = name.lowercased()
        guard lower.hasPrefix(prefix), lower.hasSuffix(suffix),
              name.count > prefix.count + suffix.count else { return nil }
        return String(name.dropFirst(prefix.count).dropLast(suffix.count))
    }

    /// The Cellpose version pip recorded in `venv/lib/python3.*/site-packages`.
    /// Nil when there is none, or more than one (a damaged install). Reads two
    /// directory listings and runs no Python; call it off the main actor.
    static func installedVersion(venv: URL) -> String? {
        let fm = FileManager.default
        let lib = venv.appendingPathComponent("lib", isDirectory: true)
        guard let pythons = try? fm.contentsOfDirectory(atPath: lib.path) else { return nil }
        var versions: Set<String> = []
        for python in pythons where python.hasPrefix("python3") {
            let site = lib.appendingPathComponent(python, isDirectory: true)
                .appendingPathComponent("site-packages", isDirectory: true)
            guard let entries = try? fm.contentsOfDirectory(atPath: site.path) else { continue }
            for entry in entries {
                if let version = version(fromDistInfo: entry) { versions.insert(version) }
            }
        }
        return versions.count == 1 ? versions.first : nil
    }

    /// Reads the installed version and caches it for `cachedStatus`. Call it
    /// when Cellpose was found importable; an unreadable version is stored as
    /// such, so it reads as "update available", not "still checking".
    @discardableResult
    static func refreshCachedVersion(venv: URL, defaults: UserDefaults = .standard) -> String? {
        let version = installedVersion(venv: venv)
        defaults.set(version ?? unreadableVersion, forKey: installedVersionCacheKey)
        return version
    }

    static func forgetCachedVersion(defaults: UserDefaults = .standard) {
        defaults.removeObject(forKey: installedVersionCacheKey)
    }

    // MARK: — Import check

    /// Exit 0 when `import cellpose` gives 4.x, 2 for an older Cellpose, 1
    /// when the import fails.
    static let importCheckCode = """
    import sys
    try:
        import cellpose
        v = getattr(cellpose, 'version', None) or ''
        if not isinstance(v, str):
            v = str(v)
        major = int(v.split('.')[0]) if v else 0
        if major >= 4:
            sys.exit(0)
        sys.exit(2)
    except Exception:
        sys.exit(1)
    """

    /// Runs the import check in `pythonURL`. Off the main actor only.
    static func isImportable(pythonURL: URL) -> Bool {
        ModelProbeRunner.run(pythonURL: pythonURL, code: importCheckCode)
    }
}
