import Foundation

enum BatchRowStatus: String {
    case done, running, queued, error
}

struct BatchImageRow: Identifiable, Hashable {
    let id = UUID()
    var name: String
    var status: BatchRowStatus
    var count: Int?
    var meanDiameter: Double?
    var binDistributionNorm: [Double]?     // 0…100, length = 5
    var seed: Int
}
