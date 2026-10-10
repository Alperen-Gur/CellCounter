import Foundation

extension Double {
    /// Compact decimal string that drops a trailing ".0": whole values render
    /// as integers ("20"), fractional values keep one decimal place ("20.5").
    /// Single source of truth for the size-threshold / calibration display
    /// formatting used across bins, the results panel, exports, and provenance.
    var trimmedString: String {
        guard isFinite else { return "—" }
        // Imported settings can contain finite values outside Int's range.
        // Converting those with Int(self) traps while rendering Review/Results.
        if let whole = Int(exactly: self) { return String(whole) }
        if abs(self) >= 1e15 { return String(format: "%.6g", self) }
        return String(format: "%.1f", self)
    }
}
