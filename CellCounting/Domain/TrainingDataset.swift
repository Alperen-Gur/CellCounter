import Foundation
import CoreGraphics
import CryptoKit

/// A value snapshot: later library edits cannot change an in-flight training run.
nonisolated struct TrainingSample: Identifiable, Sendable {
    var id: UUID
    var name: String
    var sourceURL: URL
    var width: Int
    var height: Int
    var cells: [DetectedCell]
    var group: String
    var sourceHash: String
    var zProjection: String = "max"
    var segmentChannel: Int? = nil
    var useRGBLuminance: Bool = false
    var reviewed: Bool = false
    var sourceSettingsKnown: Bool = false
    var detectionID: UUID? = nil
    var detectionRevision: Int = 0
}

nonisolated enum TrainingDatasetError: LocalizedError, Equatable {
    case invalid(String)
    var errorDescription: String? { if case .invalid(let message) = self { return message }; return nil }
}

nonisolated struct TrainingSplit: Codable, Sendable, Equatable {
    var trainPercent: Int = 70
    var validationPercent: Int = 20
    var seed: Int = 42

    func assignments(for samples: [TrainingSample]) throws -> [UUID: String] {
        guard trainPercent > 0, validationPercent > 0,
              trainPercent + validationPercent < 100 else {
            throw TrainingDatasetError.invalid("Training, validation and test must each receive a positive share.")
        }
        guard Set(samples.map(\.id)).count == samples.count else {
            throw TrainingDatasetError.invalid("An image appears more than once in the dataset.")
        }
        let groups = Set(samples.map { $0.group.trimmingCharacters(in: .whitespacesAndNewlines) })
        guard !groups.contains(""), groups.count >= 3 else {
            throw TrainingDatasetError.invalid("Choose at least three independent specimen groups. Images from one specimen stay in the same split.")
        }
        var hashes = Set<String>()
        for sample in samples where !sample.sourceHash.isEmpty {
            guard hashes.insert(sample.sourceHash).inserted else {
                throw TrainingDatasetError.invalid("Duplicate source image: \(sample.name). Remove duplicate copies before splitting.")
            }
        }
        let ordered = groups.sorted {
            let a = Self.key("\(seed):\($0)"); let b = Self.key("\(seed):\($1)")
            return a == b ? $0 < $1 : a < b
        }
        let trainCount = min(ordered.count - 2, max(1, Int((Double(ordered.count * trainPercent) / 100).rounded())))
        let valCount = min(ordered.count - trainCount - 1, max(1, Int((Double(ordered.count * validationPercent) / 100).rounded())))
        var groupSplits: [String: String] = [:]
        for (index, group) in ordered.enumerated() {
            groupSplits[group] = index < trainCount ? "train" : index < trainCount + valCount ? "validation" : "test"
        }
        return Dictionary(uniqueKeysWithValues: samples.map {
            ($0.id, groupSplits[$0.group.trimmingCharacters(in: .whitespacesAndNewlines)]!)
        })
    }

    private static func key(_ text: String) -> String {
        SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}

/// Rasterize reviewed instance contours at pixel centers, in source orientation.
/// Circle/box-only detections are rejected because they do not describe a mask.
nonisolated enum TrainingLabelRasterizer {
    static func labels(width: Int, height: Int, cells: [DetectedCell]) throws -> [UInt32] {
        guard width > 0, height > 0, width <= 65536, height <= 65536,
              width <= 64_000_000 / height else {
            throw TrainingDatasetError.invalid("Training images must contain 1–64 million pixels.")
        }
        guard !cells.isEmpty else { throw TrainingDatasetError.invalid("Each training image needs at least one reviewed cell mask.") }
        var labels = [UInt32](repeating: 0, count: width * height)
        for (index, cell) in cells.enumerated() {
            guard let polygon = cell.contourPx, polygon.count >= 3,
                  polygon.allSatisfy({ $0.x.isFinite && $0.y.isFinite }) else {
                throw TrainingDatasetError.invalid("A cell has no usable outline. Trace its boundary or remove it before training.")
            }
            let minY = max(0, min(height, Int(max(-1, min(Double(height), floor(polygon.map(\.y).min()!))))))
            let maxY = max(0, min(height, Int(max(0, min(Double(height), ceil(polygon.map(\.y).max()!))))))
            var filled = 0
            for y in minY..<maxY {
                let scanY = Double(y) + 0.5
                var intersections: [Double] = []
                for i in polygon.indices {
                    let a = polygon[i]; let b = polygon[(i + 1) % polygon.count]
                    if (a.y <= scanY && b.y > scanY) || (b.y <= scanY && a.y > scanY) {
                        intersections.append(a.x + (scanY - a.y) * (b.x - a.x) / (b.y - a.y))
                    }
                }
                guard intersections.allSatisfy(\.isFinite) else {
                    throw TrainingDatasetError.invalid("A cell outline contains invalid coordinates.")
                }
                intersections.sort()
                var i = 0
                while i + 1 < intersections.count {
                    let first = Int(ceil(max(0, min(Double(width), intersections[i] - 0.5))))
                    let end = Int(ceil(max(0, min(Double(width), intersections[i + 1] - 0.5))))
                    for x in first..<max(first, end) {
                        let position = y * width + x
                        guard labels[position] == 0 else {
                            throw TrainingDatasetError.invalid("Cell outlines overlap. Resolve overlapping masks before training.")
                        }
                        labels[position] = UInt32(index + 1)
                        filled += 1
                    }
                    i += 2
                }
            }
            guard filled > 0 else { throw TrainingDatasetError.invalid("A cell outline contains no image pixels.") }
        }
        return labels
    }
}
