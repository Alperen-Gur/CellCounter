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

    // Size-bin perceptual ramp (5 stops, colorblind-safe viridis-ish)
    static let bin1 = Color(OKLCH(0.45, 0.14, 280))
    static let bin2 = Color(OKLCH(0.58, 0.13, 230))
    static let bin3 = Color(OKLCH(0.68, 0.11, 180))
    static let bin4 = Color(OKLCH(0.78, 0.13, 105))
    static let bin5 = Color(OKLCH(0.82, 0.16, 60))

    static let bins: [Color] = [bin1, bin2, bin3, bin4, bin5]

    /// Returns the hardcoded Viridis color for index `i`. Prefer `paletteColor(_:)` in UI code.
    static func binColor(_ i: Int) -> Color {
        bins[max(0, min(i, bins.count - 1))]
    }

    /// Returns the bin color for index `i` using the currently selected palette from UserDefaults.
    /// Views that honour the user's palette preference should call this instead of `binColor(_:)`.
    static func paletteColor(_ i: Int) -> Color {
        let palette = UserDefaults.standard.string(forKey: "cc-bin-palette") ?? "viridis"
        let ramp = PaletteManager.colors(for: palette)
        let idx = max(0, min(i, ramp.count - 1))
        return ramp[idx]
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

// MARK: - PaletteManager

/// Central palette registry — mirrors the palette list in AppearanceSection.
enum PaletteManager {
    static func colors(for id: String) -> [Color] {
        switch id {
        case "coral":
            return [
                Color(OKLCH(0.42, 0.10, 30)), Color(OKLCH(0.55, 0.13, 30)),
                Color(OKLCH(0.68, 0.15, 30)), Color(OKLCH(0.78, 0.13, 30)),
                Color(OKLCH(0.86, 0.09, 30))
            ]
        case "blues":
            return [
                Color(OKLCH(0.30, 0.13, 260)), Color(OKLCH(0.45, 0.13, 250)),
                Color(OKLCH(0.60, 0.12, 230)), Color(OKLCH(0.72, 0.10, 210)),
                Color(OKLCH(0.84, 0.08, 200))
            ]
        case "magma":
            return [
                Color(OKLCH(0.18, 0.08, 295)), Color(OKLCH(0.38, 0.16, 10)),
                Color(OKLCH(0.58, 0.18, 30)),  Color(OKLCH(0.76, 0.14, 60)),
                Color(OKLCH(0.93, 0.06, 80))
            ]
        case "inferno":
            return [
                Color(OKLCH(0.16, 0.07, 280)), Color(OKLCH(0.36, 0.17, 10)),
                Color(OKLCH(0.57, 0.19, 35)),  Color(OKLCH(0.78, 0.15, 65)),
                Color(OKLCH(0.96, 0.06, 85))
            ]
        case "plasma":
            return [
                Color(OKLCH(0.35, 0.18, 285)), Color(OKLCH(0.48, 0.20, 330)),
                Color(OKLCH(0.62, 0.18, 0)),   Color(OKLCH(0.76, 0.15, 45)),
                Color(OKLCH(0.90, 0.12, 85))
            ]
        case "cividis":
            return [
                Color(OKLCH(0.32, 0.04, 235)), Color(OKLCH(0.46, 0.06, 220)),
                Color(OKLCH(0.60, 0.07, 195)), Color(OKLCH(0.74, 0.09, 105)),
                Color(OKLCH(0.88, 0.09, 90))
            ]
        case "greys":
            return [
                Color(OKLCH(0.20, 0, 0)), Color(OKLCH(0.40, 0, 0)),
                Color(OKLCH(0.58, 0, 0)), Color(OKLCH(0.75, 0, 0)),
                Color(OKLCH(0.90, 0, 0))
            ]
        case "rdylgn":
            return [
                Color(OKLCH(0.52, 0.20, 25)),  Color(OKLCH(0.68, 0.18, 50)),
                Color(OKLCH(0.86, 0.14, 95)),  Color(OKLCH(0.72, 0.15, 140)),
                Color(OKLCH(0.55, 0.17, 145))
            ]
        default: // "viridis"
            return Tokens.bins
        }
    }
}
