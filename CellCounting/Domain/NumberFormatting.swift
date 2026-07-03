import Foundation

extension Double {
    /// Compact decimal string that drops a trailing ".0": whole values render
    /// as integers ("20"), fractional values keep one decimal place ("20.5").
    /// Single source of truth for the size-threshold / calibration display
    /// formatting used across bins, the results panel, exports, and provenance.
    var trimmedString: String {
        truncatingRemainder(dividingBy: 1) == 0
            ? String(Int(self))
            : String(format: "%.1f", self)
    }
}
