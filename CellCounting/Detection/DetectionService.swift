import Foundation

struct DetectionInput {
    let imageURL: URL?
    let modelId: String
    let pxPerUm: Double
    let confidenceThreshold: Double
    /// Cellpose channel selection [cyto, nuclei]. Default [0, 0] (grayscale).
    let channels: [Int]
    /// Apply rolling-ball background subtraction before detection.
    let backgroundSubtract: Bool
    /// Rolling-ball radius in pixels for background subtraction.
    let rollingBallRadius: Int
    /// When true, ask the sidecar to run a distance-transform watershed on
    /// the produced mask to split touching cells into separate detections.
    let watershedSplit: Bool
    /// Minimum distance between watershed seed peaks, in MICROMETERS.
    /// Multiplied by `pxPerUm` inside the sidecar. Default 8 µm.
    let watershedMinDistance: Int
    /// Diameter threshold (µm) below which cells are classed "small". Default 20.
    let smallThreshold: Double
    /// Diameter threshold (µm) at or above which cells are classed "large". Default 30.
    let largeThreshold: Double
    /// Use GPU (Apple Neural Engine / Metal) when supported by the sidecar.
    /// False forces CPU. Plumbed through each detector to its sidecar
    /// (Cellpose: `--no-gpu` arg; StarDist/SAM similarly). Default true.
    let useGPU: Bool

    init(imageURL: URL?,
         modelId: String,
         pxPerUm: Double,
         confidenceThreshold: Double,
         channels: [Int] = [0, 0],
         backgroundSubtract: Bool = false,
         rollingBallRadius: Int = 50,
         watershedSplit: Bool = false,
         watershedMinDistance: Int = 8,
         smallThreshold: Double = 20,
         largeThreshold: Double = 30,
         useGPU: Bool = true) {
        self.imageURL = imageURL
        self.modelId = modelId
        self.pxPerUm = pxPerUm
        self.confidenceThreshold = confidenceThreshold
        self.channels = channels
        self.backgroundSubtract = backgroundSubtract
        self.rollingBallRadius = rollingBallRadius
        self.watershedSplit = watershedSplit
        self.watershedMinDistance = watershedMinDistance
        self.smallThreshold = smallThreshold
        self.largeThreshold = largeThreshold
        self.useGPU = useGPU
    }
}

struct DetectionResult {
    let cells: [DetectedCell]
    let imageWidth: Int
    let imageHeight: Int
    /// Per-image QC/colony stats from the Python sidecar.
    /// Keys: "focus_score", "illumination_residual", plus any colony-pipeline keys.
    /// Nil for legacy sidecars that don't emit this block.
    let imageStats: [String: Double]?

    init(cells: [DetectedCell], imageWidth: Int, imageHeight: Int,
         imageStats: [String: Double]? = nil) {
        self.cells = cells
        self.imageWidth = imageWidth
        self.imageHeight = imageHeight
        self.imageStats = imageStats
    }
}

protocol DetectionService {
    func detect(_ input: DetectionInput) async throws -> DetectionResult
}

/// Surfaced when a detection run can't complete. There is no mock fallback —
/// callers are expected to render these to the user.
enum DetectionError: LocalizedError {
    /// The active model id maps to a family whose weights/runtime aren't on disk.
    case modelNotInstalled(modelId: String)
    /// No model is currently active (or the catalog can't find one).
    case noActiveModel
    /// The Python sidecar ran but exited non-zero or produced unparseable output.
    case sidecarFailed(exitCode: Int32, stderr: String)
    /// The caller passed no image URL (or the bytes couldn't be decoded).
    case imageDecodeFailed
    /// Subprocess was terminated by the host (Cancel button, app quit,
    /// ChildProcessTracker.terminateAll). Distinct from .sidecarFailed so the UI
    /// can swallow it silently instead of showing a "detection failed" banner.
    case cancelled
    /// The sidecar emitted a stdout payload larger than the runner will buffer
    /// (e.g. a pathologically dense image yielding hundreds of thousands of
    /// contour polygons). Fail with a clear message rather than holding an
    /// unbounded payload in memory and OOM'ing mid-batch.
    case payloadTooLarge(limitBytes: Int)

    var errorDescription: String? {
        switch self {
        case .modelNotInstalled(let modelId):
            return "Model \(modelId) is not installed. Open Models and install it before running detection."
        case .noActiveModel:
            return "No detection model is selected."
        case .sidecarFailed(let exitCode, let stderr):
            let trimmed = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            let tail = trimmed.isEmpty ? "(no stderr)" : String(trimmed.suffix(400))
            return "Detection sidecar exited with code \(exitCode). \(tail)"
        case .imageDecodeFailed:
            return "Couldn't decode the image bytes for detection."
        case .cancelled:
            return "Detection was cancelled."
        case .payloadTooLarge(let limitBytes):
            let mb = limitBytes / (1024 * 1024)
            return "Detection produced too many objects to process (result exceeded \(mb) MB). "
                + "Try a smaller region or a less dense image."
        }
    }
}
