import Foundation

/// The exact inputs to an analysis. Persisted with jobs and results, independent
/// of preferences edited while another image is being processed.
nonisolated struct AnalysisRunSettings: Codable, Equatable, Sendable {
    var modelId: String = "cp-cyto3"
    var modelName: String = "Cellpose cyto3"
    var modelFamily: String = "Cellpose"
    /// A saved run: the scale this image was segmented at. A job: the scale
    /// for images without one (0 = none); each image is analysed at its own
    /// scale (`ImageScale`, `withScale(_:)`).
    var pxPerUm: Double = 1
    var calibrationSource: String = "manual"
    var confidence: Double = 0.5
    var expectedDiameterUm: Double = 0
    /// Optional for decoding runs saved before Omnipose controls were exposed.
    /// A missing value replays the sidecar's original defaults.
    var omniposeSettings: OmniposeSegmentationSettings?
    var thresholds: [Double] = [20, 30]
    var channels: [Int] = [0, 0]
    var backgroundSubtract: Bool = false
    var rollingBallRadius: Int = 50
    var preprocessingPreset: String = "none"
    var watershedSplit: Bool = false
    var watershedMinDistanceUm: Int = 8
    var useGPU: Bool = true
    var zProjection: String = "max"
    var segmentChannel: Int = 0
    var manualThreshold: Double = 0
    var ensemblePrimaryId: String?
    var ensembleSecondaryId: String?
    var detectorVersion: String?
    var weightsSHA256: String?
    /// What actually ran, as the sidecar reported it (versions, device,
    /// dtype, weights). Nil for runs saved before it was recorded and for
    /// detectors that do not report it. A record, never an input.
    var detectorRuntime: DetectorRuntimeInfo?

    /// These settings with what the sidecar reported for this run. The
    /// reported Cellpose version and weights checksum replace the values
    /// probed before the run, which may describe another environment or
    /// another checkpoint; without a report they stay as they were.
    func recording(_ runtime: DetectorRuntimeInfo?) -> Self {
        var value = self
        value.detectorRuntime = runtime
        if let version = runtime?.cellposeVersion { value.detectorVersion = version }
        if let digest = runtime?.weightsSHA256 { value.weightsSHA256 = digest }
        return value
    }

    /// Whether a run with these settings gives the same result as `other`.
    /// Where a scale came from does not change what the model sees, so
    /// `calibrationSource` is not compared; `ignoringScale` leaves out the
    /// scale too (a job's scale for images without one).
    func hasSameInputs(as other: Self, ignoringScale: Bool = false) -> Bool {
        var lhs = self, rhs = other
        lhs.detectorVersion = nil; rhs.detectorVersion = nil
        lhs.weightsSHA256 = nil; rhs.weightsSHA256 = nil
        lhs.detectorRuntime = nil; rhs.detectorRuntime = nil
        lhs.calibrationSource = ""; rhs.calibrationSource = ""
        if ignoringScale { lhs.pxPerUm = 0; rhs.pxPerUm = 0 }
        // Omnipose parameters affect only an Omnipose run (or its ensemble
        // member). Nil and the historical defaults represent the same input.
        lhs.omniposeSettings = lhs.usesOmnipose ? (lhs.omniposeSettings ?? .init()) : nil
        rhs.omniposeSettings = rhs.usesOmnipose ? (rhs.omniposeSettings ?? .init()) : nil
        return lhs == rhs
    }

    var validationError: String? {
        if !manualThreshold.isFinite || manualThreshold < 0 { return "Enter a nonnegative finite intensity threshold." }
        if modelId.isEmpty { return "Choose a model." }
        // 0 is a job without a scale for images that have none; each image
        // is checked for its own scale before it is analysed.
        if !pxPerUm.isFinite || pxPerUm < 0 { return "Enter a positive pixel scale." }
        if !confidence.isFinite || !(0...1).contains(confidence) { return "Confidence must be between 0 and 1." }
        if !expectedDiameterUm.isFinite || expectedDiameterUm < 0 { return "Expected diameter must be zero (automatic) or positive." }
        if usesOmnipose, let error = (omniposeSettings ?? .init()).validationError { return error }
        if thresholds.isEmpty || thresholds.contains(where: { !$0.isFinite || $0 <= 0 })
            || zip(thresholds, thresholds.dropFirst()).contains(where: { $0 >= $1 }) {
            return "Size boundaries must be positive and increasing."
        }
        if channels.count != 2 || channels.contains(where: { $0 < 0 }) || segmentChannel < 0 { return "Choose valid channels." }
        if !["max", "sum", "mean", "none"].contains(zProjection) { return "Choose a supported Z projection." }
        if rollingBallRadius <= 0 || watershedMinDistanceUm <= 0 { return "Background and split distances must be positive." }
        return nil
    }

    @MainActor static func capture(state: AppState) -> Self {
        var value = Self()
        value.modelId = state.activeModelId
        value.modelName = state.activeModelName
        if value.modelId == EnsembleDownloader.modelId {
            value.ensemblePrimaryId = EnsembleDownloader.primaryId()
            value.ensembleSecondaryId = EnsembleDownloader.secondaryId()
        }
        value.modelFamily = state.models.first(where: { $0.id == state.activeModelId })?.family.rawValue ?? "Custom"
        // The user's default for images without a scale; 0 when not set.
        value.pxPerUm = ImageScale.isUsable(state.pxPerUm) ? state.pxPerUm : 0
        value.calibrationSource = value.pxPerUm > 0 ? ImageScale.defaultSource : ImageScale.unsetSource
        value.confidence = state.confidence
        value.expectedDiameterUm = state.expectedDiameterUm
        if value.usesOmnipose { value.omniposeSettings = state.omniposeSettings }
        value.thresholds = state.thresholds
        value.channels = state.channels.asArray
        value.backgroundSubtract = state.backgroundSubtract
        value.rollingBallRadius = state.rollingBallRadius
        value.preprocessingPreset = state.preprocessingPreset.rawValue
        value.watershedSplit = state.watershedSplit
        value.watershedMinDistanceUm = state.watershedMinDistanceUm
        value.useGPU = state.useGPU
        value.zProjection = ChannelStackSettings.zProjection.rawValue
        value.segmentChannel = ChannelStackSettings.segmentChannel
        value.manualThreshold = UserDefaults.standard.double(forKey: ClassicalDetectionService.manualThresholdKey)
        return value
    }

    /// These settings for one image: its own scale replaces the job's scale
    /// for images without one, so the size hint in pixels follows it too.
    func withScale(_ scale: ImageScale.Resolved?) -> Self {
        var value = self
        if let scale {
            value.pxPerUm = scale.pxPerUm
            value.calibrationSource = scale.source
        }
        return value
    }

    @MainActor var supportsSourceChannels: Bool {
        guard let family = ModelFamily(rawValue: modelFamily) else { return false }
        return [ModelFamily.cellpose, .cellpose4, .classical, .omnipose, .custom].contains(family)
    }

    var usesOmnipose: Bool {
        if modelFamily == "Omnipose" || modelId.hasPrefix("omni-") { return true }
        guard modelFamily == "Ensemble" || modelId == "ensemble-2" else { return false }
        return ensemblePrimaryId?.hasPrefix("omni-") == true
            || ensembleSecondaryId?.hasPrefix("omni-") == true
    }

    @MainActor func sourceURL(for image: ImageRecord) -> URL {
        ImageLoader.isVendorExtension(image.storedURL.pathExtension) && !supportsSourceChannels
            ? image.displayURL : image.storedURL
    }

    @MainActor func detectionInput(imageURL: URL) -> DetectionInput {
        DetectionInput(imageURL: imageURL, modelId: modelId, pxPerUm: pxPerUm,
                       confidenceThreshold: confidence, channels: channels,
                       backgroundSubtract: backgroundSubtract, rollingBallRadius: rollingBallRadius,
                       preprocessingPreset: PreprocessingPreset(rawValue: preprocessingPreset) ?? .none,
                       watershedSplit: watershedSplit, watershedMinDistance: watershedMinDistanceUm,
                       smallThreshold: thresholds.first ?? 20, largeThreshold: thresholds.last ?? 30,
                       useGPU: useGPU, expectedDiameterUm: expectedDiameterUm,
                       omniposeSettings: omniposeSettings ?? .init(),
                       zProjection: zProjection, segmentChannel: segmentChannel,
                       manualThreshold: manualThreshold)
    }
}

nonisolated enum AnalysisTaskPreset: String, CaseIterable, Identifiable, Codable, Sendable {
    case countCells, countNuclei, markerPositive, woundClosure
    var id: String { rawValue }
    var title: String {
        switch self {
        case .countCells: return "Count and size cells"
        case .countNuclei: return "Count nuclei"
        case .markerPositive: return "Measure marker positivity"
        case .woundClosure: return "Measure wound closure"
        }
    }
    var detail: String {
        switch self {
        case .countCells: return "Review masks, counts, and calibrated cell sizes."
        case .countNuclei: return "Segment a nuclear channel; confirm the channel and expected size."
        case .markerPositive: return "Segment cells first, then measure a separate marker channel in Intensity assays."
        case .woundClosure: return "Import a time series, then measure the wound in Area assays. Cell detection is optional."
        }
    }
    var resultsWorkspace: String {
        switch self {
        case .countCells, .countNuclei: return "overview"
        case .markerPositive: return "measurements"
        case .woundClosure: return "assays"
        }
    }
    func applying(to settings: AnalysisRunSettings) -> AnalysisRunSettings {
        var result = settings
        switch self {
        case .countCells: break
        case .countNuclei:
            result.modelId = "cp-nuclei"; result.modelName = "Cellpose nuclei"; result.modelFamily = "Cellpose"
            result.watershedSplit = true
        case .markerPositive: result.watershedSplit = true
        case .woundClosure: break
        }
        return result
    }
}
