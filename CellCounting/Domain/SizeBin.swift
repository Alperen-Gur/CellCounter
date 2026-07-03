import Foundation

struct SizeBin: Identifiable, Hashable {
    let id = UUID()
    let min: Double
    let max: Double
    let label: String
}

enum BinMath {
    /// Given thresholds like [20, 30] return bins: <20, 20–30, >30.
    /// Thresholds are sorted ascending defensively so an out-of-order edit
    /// (e.g. [35, 30]) can never produce empty/negative-width bins.
    static func bins(from thresholds: [Double]) -> [SizeBin] {
        let thresholds = thresholds.sorted()
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
        let thresholds = thresholds.sorted()
        for (i, t) in thresholds.enumerated() {
            if diameter < t { return i }
        }
        return thresholds.count
    }
}
