import Foundation

/// What actually ran for one detection, as a Cellpose sidecar reports it in
/// `image_stats.runtime` (`python/_cellpose_runtime.py`): package versions
/// from the process that ran, the device and parameter dtype of the loaded
/// model, the requested model, the weights file and its checksum, and the
/// speed-patch status.
///
/// Stored with the result's run settings (`AnalysisRunSettings.detectorRuntime`,
/// so it travels with `runSettingsData` into mask versions and archives) and
/// printed in every provenance output. Every field is optional: a sidecar
/// leaves out what it could not read, and results saved before this existed
/// have none at all.
nonisolated struct DetectorRuntimeInfo: Codable, Hashable, Sendable {
    var schema: Int?
    var cellposeVersion: String?
    var torchVersion: String?
    var torchvisionVersion: String?
    var numpyVersion: String?
    var opencvVersion: String?
    var opencvDistribution: String?
    var pythonVersion: String?
    var device: String?
    var modelDtype: String?
    var requestedModel: String?
    var weightsFile: String?
    var weightsSizeBytes: Int64?
    /// UTC, ISO 8601, as the sidecar read it from the file.
    var weightsModified: String?
    var weightsSHA256: String?
    /// `_cellpose_accel` status line, or "not used".
    var accel: String?
    var accelPatches: [String]?

    /// The sidecar's snake_case names, also used when stored.
    nonisolated enum CodingKeys: String, CodingKey {
        case schema
        case cellposeVersion = "cellpose_version"
        case torchVersion = "torch_version"
        case torchvisionVersion = "torchvision_version"
        case numpyVersion = "numpy_version"
        case opencvVersion = "opencv_version"
        case opencvDistribution = "opencv_distribution"
        case pythonVersion = "python_version"
        case device
        case modelDtype = "model_dtype"
        case requestedModel = "requested_model"
        case weightsFile = "weights_file"
        case weightsSizeBytes = "weights_size_bytes"
        case weightsModified = "weights_mtime"
        case weightsSHA256 = "weights_sha256"
        case accel
        case accelPatches = "accel_patches"
    }

    /// `(key, value)` pairs for the CSV header, in a fixed order, missing
    /// values left out. The checksum is not repeated here: it is the
    /// `weights_hash` line.
    var provenanceFields: [(key: String, value: String)] {
        var fields: [(key: String, value: String)] = []
        func add(_ key: String, _ value: String?) {
            guard let value, !value.isEmpty else { return }
            fields.append((key, Self.oneLine(value)))
        }
        add("cellpose_version", cellposeVersion)
        add("torch_version", torchVersion)
        add("torchvision_version", torchvisionVersion)
        add("numpy_version", numpyVersion)
        add("opencv_version", opencvVersion.map { version in
            opencvDistribution.map { "\(version) (\($0))" } ?? version
        })
        add("python_version", pythonVersion)
        add("device", device)
        add("model_dtype", modelDtype)
        add("requested_model", requestedModel)
        add("weights_file", weightsFile)
        add("weights_size_bytes", weightsSizeBytes.map { String($0) })
        add("weights_modified", weightsModified)
        add("cellpose_accel", accel)
        return fields
    }

    /// `# key: value` lines, matching the other provenance header lines.
    var csvHeaderLines: [String] {
        provenanceFields.map { "# \($0.key): \($0.value)" }
    }

    /// Short summary for the report and the PDF footer, e.g.
    /// "cellpose 4.2.1.1 · torch 2.12.0 · numpy 2.4.6 · mps · bfloat16 · accel active".
    var summary: String { summary(includingCellpose: true) }

    /// `summary`, optionally without the Cellpose version (for a line that
    /// already names it as the detector version).
    func summary(includingCellpose: Bool) -> String {
        var parts: [String] = []
        if includingCellpose, let cellposeVersion { parts.append("cellpose \(cellposeVersion)") }
        if let torchVersion { parts.append("torch \(torchVersion)") }
        if let numpyVersion { parts.append("numpy \(numpyVersion)") }
        if let opencvVersion { parts.append("opencv \(opencvVersion)") }
        if let pythonVersion { parts.append("python \(pythonVersion)") }
        if let device { parts.append(device) }
        if let modelDtype { parts.append(modelDtype) }
        if let accel {
            // "active (cellpose 4.2.1.1): …" → "accel active"; "not used" stays whole.
            let state = accel.hasPrefix("not used") ? "not used"
                : accel.split(separator: " ").first.map(String.init) ?? accel
            parts.append("accel \(state)")
        }
        return Self.oneLine(parts.joined(separator: " · "))
    }

    /// Header values must stay on their own line.
    private static func oneLine(_ value: String) -> String {
        value.components(separatedBy: .newlines).joined(separator: " ")
    }
}
