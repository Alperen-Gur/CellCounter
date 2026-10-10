import Foundation
import Testing
@testable import CellCounting

struct OmniposeSettingsTests {
    private func run() -> AnalysisRunSettings {
        var value = AnalysisRunSettings()
        value.modelId = "omni-cyto2"
        value.modelFamily = "Omnipose"
        return value
    }

    @Test func olderSavedRunsDecodeWithHistoricalDefaults() throws {
        let encoded = try JSONEncoder().encode(run())
        var object = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        object.removeValue(forKey: "omniposeSettings")
        let old = try JSONDecoder().decode(AnalysisRunSettings.self,
                                          from: JSONSerialization.data(withJSONObject: object))
        #expect(old.omniposeSettings == nil)
        var explicit = old
        explicit.omniposeSettings = .init()
        #expect(old.hasSameInputs(as: explicit))
    }

    @Test @MainActor func savedSettingsReachTheSidecarWithoutChangingConfidence() throws {
        var snapshot = run()
        snapshot.confidence = 0.7
        snapshot.omniposeSettings = .init(maskThreshold: -1, flowThreshold: 0.4, cluster: true)
        let saved = try JSONDecoder().decode(AnalysisRunSettings.self, from: JSONEncoder().encode(snapshot))
        let input = saved.detectionInput(imageURL: URL(fileURLWithPath: "/tmp/cellcounter-image.tif"))
        #expect(input.confidenceThreshold == 0.7)
        #expect(input.omniposeSettings == snapshot.omniposeSettings)
        #expect(input.omniposeSettings.arguments == ["--mask-threshold", "-1.0",
                                                     "--flow-threshold", "0.4", "--cluster"])
    }

    @Test func reconstructionChangesInvalidateOnlyApplicablePreviews() {
        let original = run()
        for changed in [OmniposeSegmentationSettings(maskThreshold: -1),
                        OmniposeSegmentationSettings(flowThreshold: 0.4),
                        OmniposeSegmentationSettings(cluster: true)] {
            var candidate = original
            candidate.omniposeSettings = changed
            #expect(!original.hasSameInputs(as: candidate))
        }
        var ordinary = AnalysisRunSettings()
        let ordinaryBefore = ordinary
        ordinary.omniposeSettings = .init(cluster: true)
        // Stale ensemble references on a direct model are also irrelevant.
        ordinary.ensemblePrimaryId = "omni-cyto2"
        #expect(!ordinary.usesOmnipose)
        ordinary.ensemblePrimaryId = nil
        #expect(ordinaryBefore.hasSameInputs(as: ordinary))

        var ensemble = AnalysisRunSettings()
        ensemble.modelId = "ensemble-2"
        ensemble.modelFamily = "Ensemble"
        ensemble.ensemblePrimaryId = "omni-cyto2"
        #expect(ensemble.usesOmnipose)
        let ensembleBefore = ensemble
        ensemble.omniposeSettings = .init(cluster: true)
        #expect(!ensembleBefore.hasSameInputs(as: ensemble))
    }

    @Test func invalidParametersAreRejectedButNegativeMaskThresholdsAreAllowed() {
        #expect(OmniposeSegmentationSettings(maskThreshold: -1).validationError == nil)
        #expect(OmniposeSegmentationSettings(maskThreshold: .nan).validationError != nil)
        #expect(OmniposeSegmentationSettings(flowThreshold: -0.1).validationError != nil)
        #expect(OmniposeSegmentationSettings(flowThreshold: .infinity).validationError != nil)
    }

    @Test @MainActor func oldProtocolsDecodeAndInvalidReconstructionCannotBeLoaded() throws {
        let protocolValue = AnalysisProtocol(
            name: "Omnipose", appVersion: "1", appBuild: "1",
            model: .init(id: "omni-cyto2", name: "Omnipose cyto2", family: "Omnipose"),
            detection: .init(expectedDiameterUm: 0, channelsCyto: 0, channelsNuclei: 0,
                             confidenceThreshold: 0.5),
            calibration: .init(pxPerUm: 1), sizeBins: .init(thresholdsUm: [20, 30]),
            preprocessing: .init(backgroundSubtract: false, rollingBallRadiusPx: 50,
                                 watershedSplit: false, watershedMinDistanceUm: 8),
            manualMarkerDiameterUm: 20)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        var object = try #require(JSONSerialization.jsonObject(with: encoder.encode(protocolValue)) as? [String: Any])
        var detection = try #require(object["detection"] as? [String: Any])
        detection.removeValue(forKey: "omniposeSettings")
        object["detection"] = detection
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".json")
        defer { try? FileManager.default.removeItem(at: url) }
        try JSONSerialization.data(withJSONObject: object).write(to: url)
        #expect(try AnalysisProtocolStore.load(from: url).detection.omniposeSettings == nil)
        detection["omniposeSettings"] = ["maskThreshold": 0, "flowThreshold": -1, "cluster": false]
        object["detection"] = detection
        try JSONSerialization.data(withJSONObject: object).write(to: url)
        #expect(throws: AnalysisProtocol.LoadError.self) { try AnalysisProtocolStore.load(from: url) }
    }
}
