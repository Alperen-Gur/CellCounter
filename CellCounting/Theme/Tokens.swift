import SwiftUI
import AppKit

/// Neutral design tokens — scheme-aware via NSColor dynamic provider.
/// Accent-derived tokens live on `AppTheme` because they depend on the user-chosen hue.
enum Tokens {
    // Backgrounds
    static let bg              = Color(nsColor: .dynamic(
        light: OKLCH(0.985, 0.004, 60),
        dark:  OKLCH(0.165, 0.008, 60)))
    static let bgElevated      = Color(nsColor: .dynamic(
        light: OKLCH(1.0,   0,    0),
        dark:  OKLCH(0.215, 0.008, 60)))
    static let bgSunken        = Color(nsColor: .dynamic(
        light: OKLCH(0.97,  0.005, 60),
        dark:  OKLCH(0.135, 0.008, 60)))
    static let bgToolbar       = Color(nsColor: .dynamic(
        light: OKLCH(0.985, 0.004, 60, alpha: 0.72),
        dark:  OKLCH(0.205, 0.008, 60, alpha: 0.72)))
    static let bgSidebar       = Color(nsColor: .dynamic(
        light: OKLCH(0.965, 0.005, 60, alpha: 0.86),
        dark:  OKLCH(0.185, 0.008, 60, alpha: 0.86)))
    static let bgOverlay       = Color(nsColor: .dynamic(
        light: OKLCH(0.18, 0.01, 60, alpha: 0.32),
        dark:  OKLCH(0.0,  0,    0,  alpha: 0.50)))

    // Text
    static let text            = Color(nsColor: .dynamic(
        light: OKLCH(0.22, 0.01, 60),
        dark:  OKLCH(0.96, 0.005, 60)))
    static let textSecondary   = Color(nsColor: .dynamic(
        light: OKLCH(0.46, 0.01, 60),
        dark:  OKLCH(0.72, 0.008, 60)))
    static let textTertiary    = Color(nsColor: .dynamic(
        light: OKLCH(0.62, 0.01, 60),
        dark:  OKLCH(0.56, 0.008, 60)))
    static let textQuaternary  = Color(nsColor: .dynamic(
        light: OKLCH(0.78, 0.005, 60),
        dark:  OKLCH(0.42, 0.008, 60)))

    // Borders & dividers
    static let border          = Color(nsColor: .dynamic(
        light: OKLCH(0.92, 0.005, 60),
        dark:  OKLCH(0.30, 0.008, 60)))
    static let borderStrong    = Color(nsColor: .dynamic(
        light: OKLCH(0.86, 0.005, 60),
        dark:  OKLCH(0.38, 0.008, 60)))
    static let divider         = Color(nsColor: .dynamic(
        light: OKLCH(0.93, 0.005, 60),
        dark:  OKLCH(0.27, 0.008, 60)))

    // State
    static let hover           = Color(nsColor: .dynamic(
        light: OKLCH(0.94, 0.005, 60),
        dark:  OKLCH(0.26, 0.008, 60)))

    // Status hues
    static let success = Color(OKLCH(0.65, 0.13, 155))
    static let warning = Color(OKLCH(0.78, 0.14, 75))
    static let danger  = Color(OKLCH(0.60, 0.18, 25))

    // Size-bin perceptual ramp (5 stops, colorblind-safe viridis-ish).
    // This raw OKLCH array is the SINGLE source of truth for the bin ramp —
    // both the SwiftUI `bins`/`binColor` below and ExportService's CGColor
    // path derive from it, so the exported PNG/PDF overlays can never drift
    // from the on-screen swatches.
    static let binRamp: [OKLCH] = [
        OKLCH(0.45, 0.14, 280),
        OKLCH(0.58, 0.13, 230),
        OKLCH(0.68, 0.11, 180),
        OKLCH(0.78, 0.13, 105),
        OKLCH(0.82, 0.16, 60),
    ]

    static let bin1 = Color(binRamp[0])
    static let bin2 = Color(binRamp[1])
    static let bin3 = Color(binRamp[2])
    static let bin4 = Color(binRamp[3])
    static let bin5 = Color(binRamp[4])

    static let bins: [Color] = binRamp.map { Color($0) }

    /// Returns the Viridis bin color for index `i` (clamped to the ramp).
    static func binColor(_ i: Int) -> Color {
        bins[max(0, min(i, bins.count - 1))]
    }

    // Radii
    enum Radius {
        static let sm: CGFloat = 6
        static let md: CGFloat = 8
        static let lg: CGFloat = 12
        static let xl: CGFloat = 16
        static let xxl: CGFloat = 22
    }

    // Typography
    enum Font {
        static let mono = "SF Mono"
    }

    // Motion
    enum Motion {
        static let fast: Double = 0.14
        static let medium: Double = 0.24
        static let slow: Double = 0.38
        static let ease = Animation.timingCurve(0.32, 0.72, 0, 1, duration: medium)
        static let easeFast = Animation.timingCurve(0.32, 0.72, 0, 1, duration: fast)
        static let easeSlow = Animation.timingCurve(0.32, 0.72, 0, 1, duration: slow)
    }
}
