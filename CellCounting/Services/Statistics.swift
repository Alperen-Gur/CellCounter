import Foundation

// MARK: — Mann–Whitney U test
//
// Two-sample non-parametric test of stochastic equality between two diameter
// distributions. We use the normal approximation (z-score), which is exact-in-
// the-limit and good for n >= ~20; in the Compare view we always have hundreds
// of cells per group, so we never need exact-p tables.
//
// Formulas:
//   R1 = sum of ranks for group A (ties averaged)
//   U1 = R1 - n1*(n1+1)/2
//   U2 = n1*n2 - U1
//   U_stat = min(U1, U2)
//   mu_U = n1*n2 / 2
//   sigma_U = sqrt(n1*n2*(n1+n2+1)/12)   // no tie correction; negligible for our N
//   z = (U_stat - mu_U + 0.5) / sigma_U   // continuity correction
//   p_two = 2 * (1 - Phi(|z|))            // Phi via erf
//   rB    = 1 - 2*U1 / (n1*n2)            // rank-biserial effect size

struct MannWhitneyResult {
    let u: Double
    let z: Double
    let pValue: Double
    let n1: Int
    let n2: Int
    let median1: Double
    let median2: Double
    let medianDifference: Double
    let rankBiserial: Double

    var significanceLabel: String {
        if pValue < 0.001 { return "p < 0.001" }
        if pValue < 0.01  { return String(format: "p = %.3f", pValue) }
        if pValue < 0.05  { return String(format: "p = %.3f", pValue) }
        // >= 0.05
        return String(format: "p = %.2f (n.s.)", pValue)
    }

    var effectSizeLabel: String {
        let r = abs(rankBiserial)
        if r < 0.1 { return "negligible" }
        if r < 0.3 { return "small" }
        if r < 0.5 { return "medium" }
        return "large"
    }
}

enum Statistics {

    /// Mann–Whitney U test, two-tailed, with normal approximation.
    /// Returns nil if either array is empty or either has < 3 elements.
    static func mannWhitneyU(_ a: [Double], _ b: [Double]) -> MannWhitneyResult? {
        guard a.count >= 3, b.count >= 3 else { return nil }
        let n1 = a.count
        let n2 = b.count

        // 1) Pool with origin labels, sort, assign average ranks for ties.
        struct Pair { let v: Double; let isA: Bool }
        var pooled: [Pair] = []
        pooled.reserveCapacity(n1 + n2)
        for v in a { pooled.append(Pair(v: v, isA: true)) }
        for v in b { pooled.append(Pair(v: v, isA: false)) }
        pooled.sort { $0.v < $1.v }

        var ranks = [Double](repeating: 0, count: pooled.count)
        var i = 0
        while i < pooled.count {
            var j = i
            while j + 1 < pooled.count && pooled[j + 1].v == pooled[i].v { j += 1 }
            // tied positions [i...j] share average rank (1-based)
            let avg = Double((i + 1) + (j + 1)) / 2.0
            for k in i...j { ranks[k] = avg }
            i = j + 1
        }

        // 2) Sum of ranks for group A.
        var r1: Double = 0
        for k in 0..<pooled.count where pooled[k].isA { r1 += ranks[k] }

        let n1n2 = Double(n1) * Double(n2)
        let u1 = r1 - Double(n1) * Double(n1 + 1) / 2.0
        let u2 = n1n2 - u1
        let uStat = min(u1, u2)

        // 3) Normal approximation.
        let muU = n1n2 / 2.0
        let sigmaU = sqrt(n1n2 * Double(n1 + n2 + 1) / 12.0)

        // Continuity correction: pull |U_stat - mu| toward mu by 0.5.
        // Equivalent to (U_stat - mu + 0.5) since U_stat <= mu by construction.
        let z = sigmaU > 0 ? (uStat - muU + 0.5) / sigmaU : 0
        let p = twoTailedNormalP(z: z)

        let rB = 1.0 - (2.0 * u1) / n1n2

        let m1 = median(a)
        let m2 = median(b)

        return MannWhitneyResult(
            u: uStat,
            z: z,
            pValue: p,
            n1: n1, n2: n2,
            median1: m1, median2: m2,
            medianDifference: m2 - m1,
            rankBiserial: rB)
    }

    // MARK: — helpers

    /// Standard normal CDF via erf.
    static func normalCDF(_ x: Double) -> Double {
        return 0.5 * (1.0 + erf(x / sqrt(2.0)))
    }

    /// Two-tailed p-value for a z-score under the standard normal.
    static func twoTailedNormalP(z: Double) -> Double {
        let p = 2.0 * (1.0 - normalCDF(abs(z)))
        return min(1.0, max(0.0, p))
    }

    static func median(_ xs: [Double]) -> Double {
        guard !xs.isEmpty else { return 0 }
        let s = xs.sorted()
        let n = s.count
        if n % 2 == 1 { return s[n / 2] }
        return (s[n / 2 - 1] + s[n / 2]) / 2.0
    }

    // MARK: — self-test (DEBUG only)

    #if DEBUG
    /// Quick smoke test for the Mann–Whitney implementation.
    /// Returns true on success, false otherwise. Logs to stderr on mismatch.
    @discardableResult
    static func _selfTest() -> Bool {
        var ok = true

        // Case 1: identical distributions → U at mean, z ≈ 0, p ≈ 1.
        // Use 5 copies so n ≥ 3.
        let same: [Double] = [10, 12, 14, 16, 18]
        if let r = mannWhitneyU(same, same) {
            // U1 = R1 - n1*(n1+1)/2. With ties averaged across [1,2],[3,4],...:
            // each A value shares a rank with its B twin → avg rank for pair k
            // is ((2k-1)+2k)/2 = 2k - 0.5. R1 = sum over k=1..5 of (2k - 0.5)
            //                              = (2+4+6+8+10) - 5*0.5 = 30 - 2.5 = 27.5
            // U1 = 27.5 - 5*6/2 = 27.5 - 15 = 12.5
            // U2 = 25 - 12.5 = 12.5 → U_stat = 12.5, mu_U = 12.5 → z ≈ +0.5/σ
            // p should be high (n.s.), median diff = 0.
            if abs(r.medianDifference) > 1e-9 {
                FileHandle.standardError.write(Data("Statistics._selfTest: identical median diff != 0\n".utf8))
                ok = false
            }
            if r.pValue < 0.5 {
                FileHandle.standardError.write(Data("Statistics._selfTest: identical p too low (\(r.pValue))\n".utf8))
                ok = false
            }
        } else {
            FileHandle.standardError.write(Data("Statistics._selfTest: identical case returned nil\n".utf8))
            ok = false
        }

        // Case 2: hand-computable known case. A = [1,2,3], B = [4,5,6].
        // Sorted pooled: 1A(1) 2A(2) 3A(3) 4B(4) 5B(5) 6B(6). No ties.
        // R1 = 1+2+3 = 6. U1 = 6 - 3*4/2 = 6 - 6 = 0. U2 = 9 - 0 = 9. U_stat = 0.
        // mu_U = 9/2 = 4.5. sigma_U = sqrt(3*3*7/12) = sqrt(63/12) ≈ 2.2913.
        // z = (0 - 4.5 + 0.5)/2.2913 ≈ -1.7457.
        // rB = 1 - 2*0/9 = 1.0 (max negative for A < B sense; positive here per formula).
        let aSep: [Double] = [1, 2, 3]
        let bSep: [Double] = [4, 5, 6]
        if let r = mannWhitneyU(aSep, bSep) {
            let expectedU: Double = 0
            let expectedZ: Double = -1.7457431
            let expectedRB: Double = 1.0
            if abs(r.u - expectedU) > 1e-6 {
                FileHandle.standardError.write(Data("Statistics._selfTest: U mismatch \(r.u) vs \(expectedU)\n".utf8))
                ok = false
            }
            if abs(r.z - expectedZ) > 1e-3 {
                FileHandle.standardError.write(Data("Statistics._selfTest: z mismatch \(r.z) vs \(expectedZ)\n".utf8))
                ok = false
            }
            if abs(r.rankBiserial - expectedRB) > 1e-9 {
                FileHandle.standardError.write(Data("Statistics._selfTest: rB mismatch \(r.rankBiserial) vs \(expectedRB)\n".utf8))
                ok = false
            }
            // n = 3 per side is too small for the normal approximation to reach
            // p < 0.05, but the sign of z should be negative and p around ~0.08.
            if r.z >= 0 {
                FileHandle.standardError.write(Data("Statistics._selfTest: expected negative z for A<B\n".utf8))
                ok = false
            }
        } else {
            FileHandle.standardError.write(Data("Statistics._selfTest: separated case returned nil\n".utf8))
            ok = false
        }

        // Case 3: gate — n < 3 should return nil.
        if mannWhitneyU([1, 2], [3, 4, 5]) != nil {
            FileHandle.standardError.write(Data("Statistics._selfTest: small-n gate not enforced\n".utf8))
            ok = false
        }

        return ok
    }
    #endif
}
