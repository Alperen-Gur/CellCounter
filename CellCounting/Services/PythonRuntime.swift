import CryptoKit
import Foundation

/// Centralizes the on-disk layout for the Python sidecar.
///
/// Layout after a successful install (sandbox disabled in pass 10):
///
///     ~/Library/Application Support/CellCounter/
///       python/
///         venv/                    ← created by install_python.sh
///           bin/python3
///         install_python.sh        ← copied from bundle, chmod +x
///         cellpose_detect.py       ← content-matched with the bundle so
///         cellpose_train.py          updates ship without no-op launch writes
///         _preprocessing.py
///         _watershed.py
///         _colony.py
///         stardist_detect.py
///         sam_detect.py
///
/// Bundle layout (read-only, what we copy FROM):
///
///     <App.app>/Contents/Resources/
///       python/*.py                ← copied in by the CopyPythonSidecar
///       scripts/install_python.sh    Run Script build phase.
///
/// We KEEP flat-path fallbacks (Resources/foo.py) so that any future migration
/// back to a synced-group exception set still works without touching code.
enum PythonRuntime {
    /// All Python source files that need to live next to the venv at runtime.
    /// Listed explicitly so we don't accidentally pick up stray junk from
    /// the bundle.
    static let bundledScriptNames: [String] = [
        // One shared operation engine serves the GUI, CLI and MCP.
        "workbench.py",
        "workbench_sdk.py",
        "_workbench_core.py",
        "_workbench_imaging.py",
        "_workbench_classical.py",
        "_workbench_classical_legacy.py",
        "_workbench_store.py",
        "_workbench_indexed.py",
        "_workbench_pages.py",
        "_workbench_catalogues.py",
        "_workbench_schema.py",
        "_workbench_mcp.py",
        "_workbench_workflows.py",
        "_workbench_volume.py",
        "_workbench_metrics.py",
        "_workbench_adaptation.py",
        "_workbench_plugins.py",
        "_workbench_packages.py",
        "_workbench_package2.py",
        "_workbench_models.py",
        "_workbench_model_cards.py",
        "_workbench_model_adapters.py",
        "_workbench_specialist_worker.py",
        "_workbench_discovery.py",
        "_workbench_cellpose_worker.py",
        "_workbench_assays.py",
        "_workbench_assays_area.py",
        "_workbench_neurite.py",
        "_workbench_colony.py",
        "_workbench_assays_specialist.py",
        "_workbench_assay_series.py",
        "_workbench_experiment_layouts.py",
        "_workbench_assays_intensity.py",
        "_workbench_assays_puncta.py",
        "_workbench_preprocessing.py",
        "_workbench_variants.py",
        "_workbench_review.py",
        "_workbench_sources.py",
        "_workbench_lineages.py",
        "_workbench_assay_summary.py",
        "_workbench_jobs.py",
        "_workbench_job_worker.py",
        "_workbench_registration.py",
        "_workbench_support.py",
        "_workbench_exports.py",
        "_workbench_label_import.py",
        "_workbench_comparison.py",
        "_workbench_annotations.py",
        "_workbench_sweeps.py",
        "_workbench_sweep_reports.py",
        "_workbench_composite.py",
        "_workbench_composite_exports.py",
        "_workbench_display_presets.py",
        "_workbench_display_preset_io.py",
        "_workbench_distributed.py",
        "_workbench_distribution_runner.py",
        "_workbench_environment.py",
        "_workbench_host_registry.py",
        "_workbench_runtimes.py",
        "_workbench_plugin_worker.py",
        "_workbench_refresh.py",
        "_workbench_refresh_reports.py",
        "_workbench_recompute.py",
        "_workbench_graphs.py",
        "_workbench_graph_controls.py",
        "_workbench_migration.py",
        "_workbench_native_workspace.py",
        "_workbench_sessions.py",
        "_workbench_library.py",
        "_workbench_temporal.py",
        "_workbench_tracking.py",
        "_workbench_statistics.py",
        "_workbench_statistics_exports.py",
        "_workbench_zarr.py",
        "_workbench_tiled.py",
        "_workbench_omero.py",
        "_workbench_omero_worker.py",
        "_workbench_microscopy_runtime.py",
        "_workbench_workspace.py",
        "_workbench_experiments.py",
        "cellpose_detect.py",
        "cellpose_train.py",
        "_training_dataset.py",
        "_assay_worker.py",
        // Pass-18 (K4): shared helpers for both cellpose detect scripts.
        // Both `cellpose_detect.py` and `cellpose4_detect.py` import this
        // module — if it's missing from the staged dir, neither sidecar runs.
        "_cellpose_common.py",
        "_preprocessing.py",
        "_watershed.py",
        "_colony.py",
        "stardist_detect.py",
        "sam_detect.py",
        // Pass-14 (F3): ImageJ RoiSet exporter.
        "_export_imagej_roi.py",
        // Pass-16: Cellpose-SAM (4.x) sidecar — C1 ships this file.
        // Listed here as a best-effort copy; missing-helpers are non-fatal.
        "cellpose4_detect.py",
        // Omnipose — bacteria / filamentous cells. Runs in its own venv_omni/
        // (see OmniposeDownloader) but the script itself stages here with all
        // the others, because every sidecar resolves via `stagedScriptURL`.
        "omnipose_detect.py",
        // Classical threshold + watershed. No weights, no install step — this
        // file plus scikit-image IS the whole detector, so staging it is what
        // makes the always-available guarantee true.
        "classical_detect.py",
        // Bring-your-own models: loads a user-supplied Cellpose checkpoint or
        // StarDist model directory (see CustomModelDetectionService).
        "custom_detect.py",
        // Vendor-format / Z-stack / multi-channel reader. Imported by
        // `_cellpose_common` and by every assay CLI below, so it has to stage
        // even though nothing invokes it directly.
        "_imageio.py",
        // Bridges vendor containers into a lossless PNG that ImageIO/AppKit
        // can display while detection continues to use the untouched source.
        "image_prepare.py",
        // Intensity assays: % marker-positive, N:C ratio, colocalization,
        // live/dead, transfection efficiency, cell cycle.
        "_assays_intensity.py",
        "intensity_assays.py",
        // Area assays: confluence, scratch-wound closure, spheroid size.
        "_assays_area.py",
        "area_assays_detect.py",
        // Puncta / foci per cell.
        "_assays_puncta.py",
        "puncta_detect.py",
        // Spatial statistics: nearest-neighbour, density, Clark-Evans index.
        "_spatial.py",
        "spatial_stats.py",
        // Cell tracking / migration over a time series.
        "_tracking.py",
        "track_cells.py",
        // Neurite outgrowth.
        "_neurite.py",
        "neurite_outgrowth.py",
    ]

    static func workbenchInterpreter(pythonDirectory: URL) -> URL {
        // Canonical operations have one explicitly installed environment. Model
        // interpreters remain separate and are never silently inherited here.
        pythonDirectory.appendingPathComponent("venv_workbench/bin/python3")
    }

    /// Installed interpreters worth trying for vendor-container preparation.
    /// Prefer the active detector's environment because its optional readers
    /// were installed alongside that model, then fall back across the other
    /// known environments. The helper retries candidates because an optional
    /// reader can be unavailable for one Python minor but present in another.
    static func vendorReaderInterpreters(preferredFamily: ModelFamily?) -> [URL] {
        let base = FileStore.shared.pythonInterpreterURL
        let cp4 = FileStore.shared.pythonInterpreter4URL
        let omni = OmniposeDownloader.interpreter()

        var candidates: [URL] = []
        switch preferredFamily {
        case .cellpose4:
            candidates = [cp4, base]
        case .omnipose:
            candidates = omni.map { [$0, base, cp4] } ?? [base, cp4]
        default:
            candidates = [base, cp4]
            if let omni { candidates.append(omni) }
        }

        var seen = Set<String>()
        return candidates.filter { url in
            guard FileManager.default.isExecutableFile(atPath: url.path) else { return false }
            return seen.insert(url.standardizedFileURL.path).inserted
        }
    }

    /// Errors that surface to the UI when staging fails. These are deliberately
    /// human-readable; CellposeInstaller forwards them verbatim.
    enum StagingError: LocalizedError {
        case installScriptMissing(searched: [String])
        case helperMissing(name: String, searched: [String])

        var errorDescription: String? {
            switch self {
            case .installScriptMissing(let paths):
                return "install_python.sh is not bundled in the app. "
                    + "Tried: \(paths.joined(separator: ", ")). "
                    + "This is a build-time bug — the CopyPythonSidecar Run Script "
                    + "phase did not run or did not copy the script. "
                    + "Clean the build folder and rebuild."
            case .helperMissing(let name, let paths):
                return "\(name) is not bundled in the app. "
                    + "Tried: \(paths.joined(separator: ", "))."
            }
        }
    }

    /// Source URL for a bundled python file. Tries nested first (`python/foo.py`)
    /// then flat (`foo.py`) for forward-compat. The bundle is the ONLY source —
    /// the dev-repo fallback was removed because it was masking the bundling bug.
    static func bundledPythonURL(named name: String) -> URL? {
        let fm = FileManager.default
        guard let resourceURL = Bundle.main.resourceURL else { return nil }
        let nested = resourceURL.appendingPathComponent("python/\(name)")
        if fm.fileExists(atPath: nested.path) { return nested }
        let flat = resourceURL.appendingPathComponent(name)
        if fm.fileExists(atPath: flat.path) { return flat }
        return nil
    }

    private static var workbenchSnapshot: URL?
    private static var workbenchSnapshotRoot: String?

    /// Workers may outlive both the window and this application version. Keep
    /// each complete official runtime in its own immutable, persistent directory
    /// instead of importing from a bundle that an update can replace.
    static func stageWorkbenchSnapshot(pythonDirectory: URL? = nil) throws -> URL {
        let runtimeDirectory = pythonDirectory ?? FileStore.shared.pythonDir
        if let workbenchSnapshot, workbenchSnapshotRoot == runtimeDirectory.path { return workbenchSnapshot }
        let fm = FileManager.default
        let names = bundledScriptNames.filter {
            $0 == "workbench.py" || $0 == "workbench_sdk.py" || $0.hasPrefix("_workbench_")
        }.sorted()
        var files: [(name: String, data: Data)] = []
        var digest = SHA256()
        for name in names {
            guard let source = bundledPythonURL(named: name) else {
                throw StagingError.helperMissing(name: name,
                    searched: [Bundle.main.resourceURL?.path ?? "<no Resources>"])
            }
            let data = try Data(contentsOf: source)
            // Length delimiters prevent different file/name boundaries from
            // producing the same input stream before hashing.
            digest.update(data: Data("\(name.utf8.count):\(name):\(data.count):".utf8))
            digest.update(data: data)
            files.append((name, data))
        }
        let identity = digest.finalize().map { String(format: "%02x", $0) }.joined()
        let root = runtimeDirectory.appendingPathComponent("workbench-runtimes", isDirectory: true)
        try fm.createDirectory(at: root, withIntermediateDirectories: true,
                               attributes: [.posixPermissions: 0o700])
        let canonical = root.appendingPathComponent(identity, isDirectory: true)
        func matches(_ directory: URL) -> Bool {
            files.allSatisfy { file in
                (try? Data(contentsOf: directory.appendingPathComponent(file.name))) == file.data
            }
        }
        if matches(canonical) {
            let script = canonical.appendingPathComponent("workbench.py")
            workbenchSnapshot = script
            workbenchSnapshotRoot = runtimeDirectory.path
            return script
        }
        // Never repair an existing directory in place: an older worker may
        // still be using it. A changed snapshot gets a fresh sibling.
        let destination = fm.fileExists(atPath: canonical.path)
            ? root.appendingPathComponent("\(identity)-\(UUID().uuidString)", isDirectory: true)
            : canonical
        let temporary = root.appendingPathComponent(".stage-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: temporary, withIntermediateDirectories: false,
                               attributes: [.posixPermissions: 0o700])
        defer { try? fm.removeItem(at: temporary) }
        for file in files {
            let path = temporary.appendingPathComponent(file.name)
            try file.data.write(to: path, options: .atomic)
            try fm.setAttributes([.posixPermissions: 0o400], ofItemAtPath: path.path)
        }
        do {
            try fm.moveItem(at: temporary, to: destination)
        } catch {
            // Another application instance can publish the same complete
            // snapshot first. Reuse it only when every module matches.
            guard matches(destination) else { throw error }
        }
        try fm.setAttributes([.posixPermissions: 0o500], ofItemAtPath: destination.path)
        let script = destination.appendingPathComponent("workbench.py")
        workbenchSnapshot = script
        workbenchSnapshotRoot = runtimeDirectory.path
        return script
    }

    /// Source URL for the bundled install script.
    static func bundledInstallScriptURL() -> URL? {
        let fm = FileManager.default
        guard let resourceURL = Bundle.main.resourceURL else { return nil }
        let nested = resourceURL.appendingPathComponent("scripts/install_python.sh")
        if fm.fileExists(atPath: nested.path) { return nested }
        let flat = resourceURL.appendingPathComponent("install_python.sh")
        if fm.fileExists(atPath: flat.path) { return flat }
        return nil
    }

    /// Pass-16: source URL for the bundled Cellpose-SAM (4.x) installer.
    /// Mirrors `bundledInstallScriptURL()` exactly so the same nested→flat
    /// fallback applies if Xcode's synced groups ever skip the file.
    static func bundledInstallCp4ScriptURL() -> URL? {
        let fm = FileManager.default
        guard let resourceURL = Bundle.main.resourceURL else { return nil }
        let nested = resourceURL.appendingPathComponent("scripts/install_python_cp4.sh")
        if fm.fileExists(atPath: nested.path) { return nested }
        let flat = resourceURL.appendingPathComponent("install_python_cp4.sh")
        if fm.fileExists(atPath: flat.path) { return flat }
        return nil
    }

    /// Copy one bundled helper if its bytes or required permissions changed.
    /// Updated files are copied to a sibling temporary path and atomically
    /// replaced, so a crash can never leave a half-written Python module.
    /// Returns true only when the destination was mutated.
    @discardableResult
    static func stageFile(
        source: URL,
        destination: URL,
        permissions: Int? = nil,
        fileManager fm: FileManager = .default
    ) throws -> Bool {
        try fm.createDirectory(
            at: destination.deletingLastPathComponent(),
            withIntermediateDirectories: true)

        if fm.fileExists(atPath: destination.path),
           fm.contentsEqual(atPath: source.path, andPath: destination.path) {
            guard let permissions else { return false }
            let attributes = try? fm.attributesOfItem(atPath: destination.path)
            let existing = (attributes?[.posixPermissions] as? NSNumber)?.intValue
            guard existing != permissions else { return false }
            try fm.setAttributes([.posixPermissions: permissions], ofItemAtPath: destination.path)
            return true
        }

        let temporary = destination.deletingLastPathComponent().appendingPathComponent(
            ".\(destination.lastPathComponent).stage-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: temporary) }
        try fm.copyItem(at: source, to: temporary)
        if let permissions {
            try fm.setAttributes([.posixPermissions: permissions], ofItemAtPath: temporary.path)
        }
        if fm.fileExists(atPath: destination.path) {
            _ = try fm.replaceItemAt(
                destination,
                withItemAt: temporary,
                backupItemName: nil,
                options: [])
        } else {
            try fm.moveItem(at: temporary, to: destination)
        }
        return true
    }

    /// Mirror bundled python helpers + the install script into `FileStore`'s
    /// writable python dir. Re-runnable: byte-identical files are left alone,
    /// while app updates atomically replace stale copies. Returns the directory
    /// the scripts live in.
    ///
    /// Throws `StagingError.installScriptMissing` if the bundle is missing
    /// install_python.sh (the symptom of the synced-group bug we fixed in
    /// pass 10). The previous behavior of silently skipping the script
    /// produced a confusing "permission denied" error downstream.
    @discardableResult
    static func stageScripts() throws -> URL {
        let fm = FileManager.default
        let dir = FileStore.shared.pythonDir
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)

        // *.py helpers — missing helpers are non-fatal individually (we log,
        // but proceed). Most installs only need cellpose_detect.py to work.
        for name in bundledScriptNames {
            guard let src = bundledPythonURL(named: name) else {
                NSLog("[PythonRuntime] WARNING: bundled helper missing: \(name)")
                continue
            }
            let dst = dir.appendingPathComponent(name)
            if try stageFile(source: src, destination: dst, fileManager: fm) {
                NSLog("[PythonRuntime] updated bundled helper: \(name)")
            }
        }

        // Installation uses the canonical transport pin shared with the CLI
        // and Windows host; it must not drift into a Swift or shell constant.
        for name in ["requirements-analysis.txt", "requirements-mcp.txt", "requirements-zarr.txt", "requirements-reporting.txt", "requirements-omero.txt"] {
            guard let source = bundledPythonURL(named: name) else {
                throw StagingError.helperMissing(name: name, searched: ["Resources/python/\(name)"])
            }
            try stageFile(source: source, destination: dir.appendingPathComponent(name), fileManager: fm)
        }

        if let resources = Bundle.main.resourceURL {
            let source = resources.appendingPathComponent("scripts/install_workbench.sh")
            guard fm.fileExists(atPath: source.path) else {
                throw StagingError.helperMissing(name: "install_workbench.sh", searched: [source.path])
            }
            try stageFile(source: source, destination: dir.appendingPathComponent("install_workbench.sh"), permissions: 0o755, fileManager: fm)
        }

        // install_python.sh — REQUIRED. Without it, nothing else matters.
        guard let scriptSrc = bundledInstallScriptURL() else {
            let probed: [String] = {
                guard let res = Bundle.main.resourceURL else { return ["<no Resources>"] }
                return [
                    res.appendingPathComponent("scripts/install_python.sh").path,
                    res.appendingPathComponent("install_python.sh").path,
                ]
            }()
            throw StagingError.installScriptMissing(searched: probed)
        }
        let dst = FileStore.shared.pythonInstallScriptURL
        if try stageFile(
            source: scriptSrc,
            destination: dst,
            permissions: 0o755,
            fileManager: fm) {
            NSLog("[PythonRuntime] updated install_python.sh: \(scriptSrc.path) -> \(dst.path)")
        }

        // Pass-19 hotfix: Pass-18 K4 extracted the shared install logic into
        // `_lib_install.sh`, which `install_python.sh` and `install_python_cp4.sh`
        // both `source` at startup. Without staging this sibling, the wrappers
        // exit immediately on a fresh machine with `_lib_install.sh: No such
        // file or directory`. A field tester hit this on first install.
        if let resourceURL = Bundle.main.resourceURL {
            let libSrcNested = resourceURL.appendingPathComponent("scripts/_lib_install.sh")
            let libSrcFlat = resourceURL.appendingPathComponent("_lib_install.sh")
            let libSrc: URL? = fm.fileExists(atPath: libSrcNested.path) ? libSrcNested
                              : (fm.fileExists(atPath: libSrcFlat.path) ? libSrcFlat : nil)
            if let libSrc {
                let libDst = FileStore.shared.pythonDir.appendingPathComponent("_lib_install.sh")
                do {
                    if try stageFile(
                        source: libSrc,
                        destination: libDst,
                        permissions: 0o755,
                        fileManager: fm) {
                        NSLog("[PythonRuntime] updated _lib_install.sh: \(libSrc.path) -> \(libDst.path)")
                    }
                } catch {
                    NSLog("[PythonRuntime] WARNING: failed to stage _lib_install.sh: \(error)")
                }
            } else {
                NSLog("[PythonRuntime] WARNING: _lib_install.sh missing from bundle — install scripts will fail to source it")
            }
        }

        // Pass-16: stage the cp4 installer alongside the 3.x one. This is a
        // best-effort copy — a missing cp4 script must NOT break the 3.x
        // install flow, since 3.x ships as the default and cp4 is opt-in.
        // Cellpose4Availability surfaces the missing-installer case to the UI.
        if let cp4Src = bundledInstallCp4ScriptURL() {
            let cp4Dst = FileStore.shared.pythonInstallCp4ScriptURL
            do {
                if try stageFile(
                    source: cp4Src,
                    destination: cp4Dst,
                    permissions: 0o755,
                    fileManager: fm) {
                    NSLog("[PythonRuntime] updated install_python_cp4.sh: \(cp4Src.path) -> \(cp4Dst.path)")
                }
            } catch {
                NSLog("[PythonRuntime] WARNING: failed to stage cp4 installer: \(error)")
            }
        } else {
            NSLog("[PythonRuntime] WARNING: install_python_cp4.sh missing from bundle (cp4 install will be unavailable)")
        }

        return dir
    }

    /// Path under FileStore for an installed Python helper, or nil if it has
    /// not been staged yet. Detection services should call this first; if it
    /// returns nil they can fall back to the bundle (read-only is fine for
    /// detection — only the installer needs write access).
    static func stagedScriptURL(named name: String) -> URL? {
        let url = FileStore.shared.pythonDir.appendingPathComponent(name)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }
}
