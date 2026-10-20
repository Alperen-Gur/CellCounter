import AppKit
import Foundation
import Observation

nonisolated struct WorkbenchVolumeCell: Identifiable, Sendable {
    let id: Int
    let voxelCount: Int
    let volumeUm3: Double?
    let diameterUm: Double?
    let meanIntensity: Double?
    let centroid: [Double]

    init?(_ value: WorkbenchJSON) {
        guard let id = value["labelId"].integer else { return nil }
        self.id = id
        voxelCount = value["voxelCount"].integer ?? 0
        volumeUm3 = value["volumeUm3"].number
        diameterUm = value["equivalentDiameterUm"].number
        meanIntensity = value["meanIntensity"].number
        centroid = [value["cx"].number ?? 0, value["cy"].number ?? 0, value["cz"].number ?? 0]
    }
}

nonisolated struct WorkbenchSliceContour: Identifiable, Sendable {
    let id: Int
    let loops: [[[Double]]]

    init?(_ value: WorkbenchJSON) {
        guard let id = value["labelId"].integer else { return nil }
        self.id = id
        loops = value["contoursPx"].array.map { loop in
            loop.array.compactMap { point in
                let pair = point.array.compactMap(\.number)
                return pair.count == 2 && pair.allSatisfy(\.isFinite) ? pair : nil
            }
        }
    }
}

@MainActor @Observable
final class WorkbenchVolumeState {
    var imageID = ""
    var timeIndex = 0
    var channel = 0
    var dimensions = [1, 1, 1]
    var timeCount = 1
    var channels = 1
    var inspection: WorkbenchJSON = .null
    var display: WorkbenchJSON?
    var generation = 0
    var viewerStatus = ""
    var cells: [WorkbenchVolumeCell] = []
    var validSupport: WorkbenchJSON = .null
    var selectedLabels: Set<Int> = []
    var isPreview = false
    var displayedParameters: WorkbenchJSON?
    var displayedTime: Int?
    var displayedChannel: Int?

    var method = "otsu"
    var threshold = 128.0
    var polarity = "bright"
    var minVolumeVox = 8
    var minDistanceVox = 3
    var voxelXUm = 1.0
    var voxelYUm = 1.0
    var voxelZUm = 1.0
    var timeStepSeconds = 1.0
    var knownX = false
    var knownY = false
    var knownZ = false
    var knownTime = false

    var crosshair = [0, 0, 0]
    var plane = "xy"
    var sliceImage: NSImage?
    var sliceWidth = 1
    var sliceHeight = 1
    var sliceContours: [WorkbenchSliceContour] = []
    var slicePlane = ""
    var sliceIndex = -1
    var sliceTime = -1
    var sliceChannel = -1
    var editMode = "select"
    var polygon: [[Double]] = []
    var brushRadiusVox = 3.0
    var paintLabel = 1
    var polygonReplaceSelected = false
    var tracks: WorkbenchJSON?
    var trackMaxDistance = 20.0
    var trackUnits = "voxel"
    var trackMaxGapFrames = 0
    var trackSourceTime = 1
    var trackTargetTime = 2
    var trackSourceLabel = 1
    var trackTargetLabel = 1

    var parameters: WorkbenchJSON {
        var values: [String: WorkbenchJSON] = [
            "method": .string(method), "polarity": .string(polarity),
            "minVolumeVox": .number(Double(minVolumeVox)),
            "minDistanceVox": .number(Double(minDistanceVox))
        ]
        if method == "manual" { values["threshold"] = .number(threshold) }
        return .object(values)
    }
    var parametersChanged: Bool {
        displayedParameters != nil && (displayedParameters != parameters ||
            displayedTime != timeIndex || displayedChannel != channel)
    }
    var normalAxis: Int { plane == "xy" ? 2 : (plane == "xz" ? 1 : 0) }
    var index: Int { crosshair[normalAxis] }
    var indexCount: Int { dimensions[normalAxis] }
    var hasSavedAnalysis: Bool {
        inspection["frames"].array.contains {
            $0["timeIndex"].integer == timeIndex && $0["channel"].integer == channel
        }
    }
    var sliceIsCurrent: Bool {
        sliceImage != nil && slicePlane == plane && sliceIndex == index &&
        sliceTime == timeIndex && sliceChannel == channel
    }
    var canEdit: Bool { sliceIsCurrent && hasSavedAnalysis && !isPreview && !parametersChanged }
    var calibrated: Bool {
        ["x", "y", "z"].allSatisfy { inspection["voxelSizeUm"][$0].number != nil }
    }
    var tracksStatus: String { inspection["tracks"]["status"].string ?? "none" }

    func invalidateDisplay() {
        generation += 1
        display = nil
        cells = []
        validSupport = .null
        selectedLabels = []
        isPreview = false
        displayedParameters = nil
        displayedTime = nil
        displayedChannel = nil
        sliceImage = nil
        sliceContours = []
        slicePlane = ""
        sliceIndex = -1
        polygon = []
        editMode = "select"
        tracks = nil
    }

    func configure(for image: WorkbenchImage) {
        guard image.id != imageID else { return }
        invalidateDisplay()
        imageID = image.id
        dimensions = [image.width, image.height, image.zCount]
        channels = image.channels
        timeCount = image.timeCount
        timeIndex = min(timeCount - 1, max(0, image.preferredVolumeSelection["timeIndex"].integer ?? 0))
        channel = min(channels - 1, max(0, image.preferredVolumeSelection["channel"].integer ?? 0))
        crosshair = dimensions.map { max(0, ($0 - 1) / 2) }
        plane = "xy"
        inspection = .null
    }

    func applyInspection(_ value: WorkbenchJSON) {
        inspection = value
        let shape = value["dimensions"].array.compactMap(\.integer)
        if shape.count == 3 && shape.allSatisfy({ $0 > 0 }) { dimensions = shape }
        channels = max(1, value["channels"].integer ?? channels)
        timeCount = max(1, value["timeCount"].integer ?? timeCount)
        channel = min(max(0, channel), channels - 1)
        timeIndex = min(max(0, timeIndex), timeCount - 1)
        crosshair = zip(crosshair, dimensions).map { min(max(0, $0.0), $0.1 - 1) }
        voxelXUm = value["voxelSizeUm"]["x"].number ?? 1
        voxelYUm = value["voxelSizeUm"]["y"].number ?? 1
        voxelZUm = value["voxelSizeUm"]["z"].number ?? 1
        timeStepSeconds = value["timeStepSeconds"].number ?? 1
        knownX = value["voxelSizeUm"]["x"].number != nil
        knownY = value["voxelSizeUm"]["y"].number != nil
        knownZ = value["voxelSizeUm"]["z"].number != nil
        knownTime = value["timeStepSeconds"].number != nil
        if !calibrated { trackUnits = "voxel" }
    }

    func restoreAnalysisParameters() {
        let saved = inspection["frames"].array.first {
            $0["timeIndex"].integer == timeIndex && $0["channel"].integer == channel
        }?["parameters"] ?? .null
        method = saved["method"].string ?? "otsu"
        polarity = saved["polarity"].string ?? "bright"
        threshold = saved["threshold"].number ?? 128
        minVolumeVox = saved["minVolumeVox"].integer ?? 8
        minDistanceVox = saved["minDistanceVox"].integer ?? 3
    }

    func voxelCenter(u: Double, v: Double) -> [Double] {
        let a = floor(u) + 0.5, b = floor(v) + 0.5, fixed = Double(index) + 0.5
        switch plane {
        case "xz": return [a, fixed, b]
        case "yz": return [fixed, a, b]
        default: return [a, b, fixed]
        }
    }
}
