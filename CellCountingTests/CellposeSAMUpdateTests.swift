import Foundation
import Testing
@testable import CellCounting

/// Cellpose 4.2.1.1: the exact-version check behind "Update Cellpose-SAM",
/// the Cellpose-SAM model rows, and the runtime each result records.
@MainActor
struct CellposeSAMUpdateTests {
    private func temporary() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("cp4-update-\(UUID())")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private static let runtime = DetectorRuntimeInfo(
        schema: 1, cellposeVersion: "4.2.1.1", torchVersion: "2.12.0", torchvisionVersion: "0.27.0",
        numpyVersion: "2.4.6", opencvVersion: "4.13.0.92", opencvDistribution: "opencv-python-headless",
        pythonVersion: "3.12.13", device: "mps", modelDtype: "bfloat16", requestedModel: "cpsam_v2",
        weightsFile: "cpsam_v2", weightsSizeBytes: 1_234_567_890, weightsModified: "2026-05-01T10:00:00Z",
        weightsSHA256: String(repeating: "ab", count: 32),
        accel: "active (cellpose 4.2.1.1): extend_centers, steps_interp, no_flow_rgb",
        accelPatches: ["extend_centers", "steps_interp", "no_flow_rgb"])

    // MARK: — Exact-version check

    @Test func onlyThePinnedVersionCountsAsCurrent() {
        #expect(CellposeSAMRuntime.pinnedCellposeVersion == "4.2.1.1")
        #expect(CellposeSAMRuntime.status(isInstalled: true, version: "4.2.1.1") == .current)
        for older in ["4.1.1", "4.2.1", "4.0.8", "4.2.1.2"] {
            #expect(CellposeSAMRuntime.status(isInstalled: true, version: older)
                    == .updateAvailable(installed: older))
        }
        #expect(CellposeSAMRuntime.status(isInstalled: true, version: nil) == .updateAvailable(installed: nil))
        #expect(CellposeSAMRuntime.status(isInstalled: false, version: "4.1.1") == .notInstalled)
    }

    @Test func cachedStatusReadsOnlyPreferences() throws {
        let suite = "CellposeSAMUpdateTests-\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        #expect(CellposeSAMRuntime.importableCacheKey == Cellpose4Availability.importableCacheKey)
        #expect(CellposeSAMRuntime.cachedStatus(defaults: defaults) == .notInstalled)
        defaults.set(true, forKey: CellposeSAMRuntime.importableCacheKey)
        // Installed by an earlier app version, not probed yet: offer nothing.
        #expect(CellposeSAMRuntime.cachedStatus(defaults: defaults) == .checking)
        defaults.set("4.1.1", forKey: CellposeSAMRuntime.installedVersionCacheKey)
        #expect(CellposeSAMRuntime.cachedStatus(defaults: defaults) == .updateAvailable(installed: "4.1.1"))
        defaults.set(CellposeSAMRuntime.unreadableVersion, forKey: CellposeSAMRuntime.installedVersionCacheKey)
        #expect(CellposeSAMRuntime.cachedStatus(defaults: defaults) == .updateAvailable(installed: nil))
        defaults.set("4.2.1.1", forKey: CellposeSAMRuntime.installedVersionCacheKey)
        #expect(CellposeSAMRuntime.cachedStatus(defaults: defaults) == .current)
        defaults.set(false, forKey: CellposeSAMRuntime.importableCacheKey)
        #expect(CellposeSAMRuntime.cachedStatus(defaults: defaults) == .notInstalled)
        #expect(!CellposeSAMRuntime.needsUpdate(modelId: "cpsam_v2", status: .checking))
    }

    @Test func installedVersionIsReadFromTheDistInfoFolder() throws {
        let venv = try temporary(); defer { try? FileManager.default.removeItem(at: venv) }
        let site = venv.appendingPathComponent("lib/python3.12/site-packages", isDirectory: true)
        let fm = FileManager.default
        for name in ["cellpose-4.1.1.dist-info", "cellpose_omni-1.0.6.dist-info", "numpy-2.4.6.dist-info"] {
            try fm.createDirectory(at: site.appendingPathComponent(name), withIntermediateDirectories: true)
        }
        #expect(CellposeSAMRuntime.installedVersion(venv: venv) == "4.1.1")
        // Two Cellpose records: a damaged install, so the version is unknown.
        try fm.createDirectory(at: site.appendingPathComponent("cellpose-4.2.1.1.dist-info"),
                               withIntermediateDirectories: true)
        #expect(CellposeSAMRuntime.installedVersion(venv: venv) == nil)
        try fm.removeItem(at: site.appendingPathComponent("cellpose-4.1.1.dist-info"))
        #expect(CellposeSAMRuntime.installedVersion(venv: venv) == "4.2.1.1")
        #expect(CellposeSAMRuntime.installedVersion(venv: venv.appendingPathComponent("missing")) == nil)
        #expect(CellposeSAMRuntime.version(fromDistInfo: "cellpose-4.2.1.1.dist-info") == "4.2.1.1")
        #expect(CellposeSAMRuntime.version(fromDistInfo: "cellpose_omni-1.0.6.dist-info") == nil)
        #expect(CellposeSAMRuntime.version(fromDistInfo: "cellpose-.dist-info") == nil)

        let suite = "CellposeSAMUpdateTests-\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        #expect(CellposeSAMRuntime.refreshCachedVersion(venv: venv, defaults: defaults) == "4.2.1.1")
        #expect(defaults.string(forKey: CellposeSAMRuntime.installedVersionCacheKey) == "4.2.1.1")
        CellposeSAMRuntime.refreshCachedVersion(venv: venv.appendingPathComponent("missing"), defaults: defaults)
        #expect(defaults.string(forKey: CellposeSAMRuntime.installedVersionCacheKey) == CellposeSAMRuntime.unreadableVersion)
        CellposeSAMRuntime.forgetCachedVersion(defaults: defaults)
        #expect(defaults.string(forKey: CellposeSAMRuntime.installedVersionCacheKey) == nil)
    }

    @Test func pinnedPackagesAreTheTestedSet() throws {
        let expected = ["cellpose==4.2.1.1", "torch==2.12.0", "torchvision==0.27.0",
                        "opencv-python-headless==4.13.0.92", "numpy>=2,<3", "scipy==1.17.1",
                        "scikit-image==0.26.0", "tifffile==2026.5.15", "pillow"]
        #expect(CellposeSAMRuntime.pinnedPackages == expected)
        #expect(!CellposeSAMRuntime.pinnedPackages.contains { $0.hasPrefix("numpy<") })
        // The bundled installer script installs the same set.
        if let url = PythonRuntime.bundledInstallCp4ScriptURL() {
            let script = try String(contentsOf: url, encoding: .utf8)
            #expect(script.contains("CC_PIP_PACKAGES='" + expected.joined(separator: " ") + "'"))
        }
    }

    @Test func v2NeedsTheUpdateOnOlderInstallsOnly() {
        let old = CellposeSAMRuntime.Status.updateAvailable(installed: "4.1.1")
        #expect(CellposeSAMRuntime.needsUpdate(modelId: "cpsam_v2", status: old))
        #expect(!CellposeSAMRuntime.needsUpdate(modelId: "cpsam", status: old))
        #expect(!CellposeSAMRuntime.needsUpdate(modelId: "cpsam_v2", status: .current))
        #expect(!CellposeSAMRuntime.needsUpdate(modelId: "cpsam_v2", status: .notInstalled))
    }

    // MARK: — Model rows

    @Test func cellposeSAMIsTheDefaultV2IsRealAndDINOIsUnavailable() throws {
        let rows = ModelCatalog.cellpose4
        #expect(rows.first?.id == "cpsam")
        #expect(CellposeSAMDetectionService.resolvedModelName("not-a-cp4-id", fallback: "also-not") == "cpsam")
        let cpsam = try #require(rows.first { $0.id == "cpsam" })
        #expect(cpsam.isSelectable && cpsam.name == "Cellpose-SAM")
        let v2 = try #require(rows.first { $0.id == "cpsam_v2" })
        #expect(v2.isSelectable)
        #expect(v2.desc.contains("revised"))
        #expect(v2.desc.contains("1.2 GB"))
        for id in ["cpdino", "cpdino-vitb"] {
            let row = try #require(rows.first { $0.id == id })
            #expect(!row.isSelectable && !row.comingSoon)
            #expect(row.unavailableReason == "Needs the dinov3 package, which Cellographer does not install.")
            // Saved results and settings that name them still resolve.
            #expect(CellposeSAMDetectionService.isKnownModelId(id))
        }
        let members = EnsembleDownloader.eligibleMembers(from: ModelCatalog.all)
        #expect(!members.contains { $0.unavailableReason != nil })
        #expect(members.contains { $0.id == "cpsam_v2" })
    }

    @Test func activateRefusesAnUnavailableModel() {
        let state = AppState(repos: Repositories(inMemory: true))
        let before = state.activeModelId
        state.activate("cpdino")
        #expect(state.activeModelId == before)
        #expect(!state.showInstallCellpose4)
    }

    // MARK: — Sidecar runtime block

    @Test func runtimeBlockDecodesBesideNumericImageStats() throws {
        let json = Data("""
        {"width": 4, "height": 3, "cells": [],
         "image_stats": {"focus_score": 0.5, "note": "text is not a statistic",
           "runtime": {"schema": 1, "cellpose_version": "4.2.1.1", "torch_version": "2.12.0",
                       "device": "mps", "model_dtype": "bfloat16", "weights_file": "cpsam",
                       "weights_size_bytes": 1234, "weights_mtime": "2026-05-01T10:00:00Z",
                       "weights_sha256": "ab", "accel": "not used", "accel_patches": [],
                       "a_later_field": {"nested": true}}}}
        """.utf8)
        let decoded = try SidecarPayload.decodeSync(stdout: json, exitCode: 0)
        #expect(decoded.imageStats == ["focus_score": 0.5])
        let runtime = try #require(decoded.runtime)
        #expect(runtime.cellposeVersion == "4.2.1.1" && runtime.torchVersion == "2.12.0")
        #expect(runtime.weightsSizeBytes == 1234 && runtime.weightsModified == "2026-05-01T10:00:00Z")
        #expect(runtime.accel == "not used" && runtime.accelPatches == [])
        #expect(try SidecarPayload.decodeResult(stdout: json, exitCode: 0).runtime == runtime)

        // A damaged block never fails the result; it is just not recorded.
        let damaged = Data(#"{"width":1,"height":1,"cells":[],"image_stats":{"focus_score":1,"runtime":{"weights_size_bytes":"x"}}}"#.utf8)
        let kept = try SidecarPayload.decodeSync(stdout: damaged, exitCode: 0)
        #expect(kept.runtime == nil && kept.imageStats == ["focus_score": 1])
        let none = try SidecarPayload.decodeSync(stdout: Data(#"{"width":1,"height":1,"cells":[]}"#.utf8), exitCode: 0)
        #expect(none.imageStats == nil && none.runtime == nil)
    }

    // MARK: — Provenance

    private func savedImage(runSettings: AnalysisRunSettings) -> (Repositories, ImageRecord) {
        let repos = Repositories(inMemory: true)
        let batch = repos.createBatch(displayName: "Runtime", modelId: "cpsam_v2", pxPerUm: 2, thresholds: [20, 30])
        let image = ImageRecord(fileName: "source.tif", originalPath: "/source.tif", widthPx: 20, heightPx: 20)
        repos.attach(image: image, to: batch)
        repos.saveDetection([DetectedCell(cx: 10, cy: 10, diameter: 5, diameterPx: 10)],
                            detectorId: "CellposeSAMDetectionService/cpsam_v2", for: image,
                            imageStats: [:], runSettings: runSettings)
        return (repos, image)
    }

    private var probedSettings: AnalysisRunSettings {
        var settings = AnalysisRunSettings()
        settings.modelId = "cpsam_v2"
        settings.modelName = "Cellpose-SAM v2"
        settings.modelFamily = ModelFamily.cellpose4.rawValue
        settings.detectorVersion = "4.1.1"          // the background probe's answer
        settings.weightsSHA256 = "probed-cpsam-hash" // always ~/.cellpose/models/cpsam
        return settings
    }

    @Test func provenanceOutputsUseTheRecordedRuntime() throws {
        let runtime = Self.runtime
        let (repos, image) = savedImage(runSettings: probedSettings.recording(runtime))
        let metadata = ProvenanceMetadata.capture(for: image, state: AppState(repos: repos))
        #expect(metadata.detectorVersion == "4.2.1.1")
        #expect(metadata.weightsHash == runtime.weightsSHA256)
        #expect(metadata.detectorRuntime == runtime)

        let header = metadata.asCSVHeader
        let sha = try #require(runtime.weightsSHA256)
        for line in ["# detector_version: 4.2.1.1", "# weights_hash: \(sha)",
                     "# cellpose_version: 4.2.1.1", "# torch_version: 2.12.0",
                     "# torchvision_version: 0.27.0", "# numpy_version: 2.4.6",
                     "# opencv_version: 4.13.0.92 (opencv-python-headless)",
                     "# python_version: 3.12.13", "# device: mps", "# model_dtype: bfloat16",
                     "# requested_model: cpsam_v2", "# weights_file: cpsam_v2",
                     "# weights_size_bytes: 1234567890", "# weights_modified: 2026-05-01T10:00:00Z",
                     "# cellpose_accel: active (cellpose 4.2.1.1): extend_centers, steps_interp, no_flow_rgb"] {
            #expect(header.contains(line + "\n"), "missing \(line)")
        }
        #expect(!header.contains("probed-cpsam-hash"))
        #expect(!header.contains("4.1.1"))
        // Same "# key: value" shape as every other header line.
        for line in header.split(separator: "\n") {
            #expect(line.hasPrefix("# ") && line.contains(": "))
        }

        let json = try #require(try JSONSerialization.jsonObject(with: metadata.asJSON) as? [String: Any])
        let block = try #require(json["detectorRuntime"] as? [String: Any])
        #expect(block["cellpose_version"] as? String == "4.2.1.1")
        #expect(block["weights_file"] as? String == "cpsam_v2")

        #expect(metadata.asMarkdown.contains("- Runtime: cellpose 4.2.1.1 · torch 2.12.0 · numpy 2.4.6"))
        let footer = PDFReportGenerator.provenanceFooterLines(metadata)
        #expect(footer.contains { $0.hasPrefix("detector: Cellpose-SAM@4.2.1.1 · torch 2.12.0 · numpy 2.4.6") })
        #expect(footer.contains { $0.contains("mps · bfloat16 · accel active") })
    }

    @Test func olderResultsKeepTheProbedValues() {
        let (repos, image) = savedImage(runSettings: probedSettings)
        let metadata = ProvenanceMetadata.capture(for: image, state: AppState(repos: repos))
        #expect(metadata.detectorVersion == "4.1.1")
        #expect(metadata.weightsHash == "probed-cpsam-hash")
        #expect(metadata.detectorRuntime == nil)
        let header = metadata.asCSVHeader
        #expect(header.contains("# detector_version: 4.1.1\n"))
        #expect(!header.contains("# cellpose_version:"))
        #expect(!header.contains("# torch_version:"))
        #expect(!metadata.asMarkdown.contains("- Runtime:"))
        // Cellpose 4.1.1 ran cpsam for "cpsam_v2"; the export says so.
        #expect(header.contains("# model_note: Cellpose 4.1.1 does not include cpsam_v2; it ran cpsam (Cellpose-SAM) for this result\n"))
        #expect(metadata.asMarkdown.contains("- Note: Cellpose 4.1.1 does not include cpsam_v2"))
    }

    @Test func substitutionNoteOnlyForOlderCellposeWithoutARuntime() {
        let note = ProvenanceMetadata.substitutedModelNote
        #expect(note("cpsam_v2", "4.1.1", nil) != nil)
        #expect(note("cpdino", "4.0.8", nil) != nil)
        #expect(note("cpsam_v2", nil, nil)?.contains("if Cellpose 4.1 or older ran this result") == true)
        #expect(note("cpsam_v2", "4.2.1.1", nil) == nil)
        #expect(note("cpsam", "4.1.1", nil) == nil)
        #expect(note("cpsam_v2", "4.1.1", Self.runtime) == nil)
    }

    @Test func recordingReplacesOrClearsTheRuntimeButNeverChangesInputs() {
        var saved = probedSettings
        saved.detectorRuntime = Self.runtime
        // A run that reported nothing must not inherit the saved run's runtime.
        let unreported = saved.recording(nil)
        #expect(unreported.detectorRuntime == nil)
        #expect(unreported.detectorVersion == "4.1.1" && unreported.weightsSHA256 == "probed-cpsam-hash")
        let reported = probedSettings.recording(Self.runtime)
        #expect(reported.detectorVersion == "4.2.1.1")
        #expect(reported.weightsSHA256 == Self.runtime.weightsSHA256)
        #expect(reported.hasSameInputs(as: probedSettings))
        #expect(unreported.hasSameInputs(as: reported))
    }
}
