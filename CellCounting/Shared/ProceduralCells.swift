import Foundation

/// Deterministic seeded RNG matching the JS prototype's `seededRand`.
struct SeededRNG {
    private var state: Double
    init(_ seed: Int) { self.state = Double(abs(seed) % 233_280) }
    mutating func next() -> Double {
        state = (state * 9301 + 49297).truncatingRemainder(dividingBy: 233_280)
        return state / 233_280
    }
}

/// Mirrors the JSX prototype's `generateCells`. Produces a bimodal distribution
/// of diameters in µm with light overlap rejection.
enum ProceduralCells {
    static func generate(count: Int,
                         seed: Int,
                         width: Double = 1100,
                         height: Double = 720,
                         pxPerUm: Double = 5.2) -> [DetectedCell] {
        var r = SeededRNG(seed)
        var cells: [DetectedCell] = []
        var tries = 0
        let maxTries = count * 20
        while cells.count < count && tries < maxTries {
            tries += 1
            let mode = r.next()
            let d: Double
            if mode < 0.45 { d = 12 + r.next() * 9 }       // small
            else if mode < 0.78 { d = 22 + r.next() * 10 } // mid
            else { d = 32 + r.next() * 18 }                // large
            let px = d * pxPerUm
            let cx = px/2 + r.next() * (width - px)
            let cy = px/2 + r.next() * (height - px)
            // light overlap rejection
            var ok = true
            for c in cells {
                let dx = c.cx - cx, dy = c.cy - cy
                if hypot(dx, dy) < (c.diameterPx + px) * 0.35 { ok = false; break }
            }
            if !ok { continue }
            let confidence = 0.5 + r.next() * 0.5
            cells.append(DetectedCell(cx: cx, cy: cy, diameter: d,
                                      diameterPx: px, confidence: confidence))
        }
        return cells
    }
}
