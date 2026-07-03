import Foundation

struct SizeBin: Identifiable, Hashable {
    let id = UUID()
    let min: Double
    let max: Double
    let label: String
}

enum BinMath {
    /// Given thresholds like [20, 30] return bins: <20, 20–30, >30.
    static func bins(from thresholds: [Double]) -> [SizeBin] {
        guard let first = thresholds.first, let last = thresholds.last else {
            return [SizeBin(min: 0, max: .infinity, label: "all")]
        }
        var out: [SizeBin] = []
        out.append(SizeBin(min: 0, max: first, label: "< \(first.trimmedString) µm"))
        for i in 0..<(thresholds.count - 1) {
            let a = thresholds[i], b = thresholds[i+1]
            out.append(SizeBin(min: a, max: b, label: "\(a.trimmedString)–\(b.trimmedString) µm"))
        }
        out.append(SizeBin(min: last, max: .infinity, label: "> \(last.trimmedString) µm"))
        return out
    }

    static func binIndex(for diameter: Double, thresholds: [Double]) -> Int {
        for (i, t) in thresholds.enumerated() {
            if diameter < t { return i }
        }
        return thresholds.count
    }
}
