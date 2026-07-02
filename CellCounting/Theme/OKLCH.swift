import SwiftUI
import AppKit

struct OKLCH {
    let l: Double
    let c: Double
    let h: Double
    let alpha: Double

    init(_ l: Double, _ c: Double, _ h: Double, alpha: Double = 1) {
        self.l = l
        self.c = c
        self.h = h
        self.alpha = alpha
    }

    var srgb: (r: Double, g: Double, b: Double, a: Double) {
        let hRad = h * .pi / 180
        let a = c * cos(hRad)
        let b = c * sin(hRad)

        let l_ = l + 0.3963377774 * a + 0.2158037573 * b
        let m_ = l - 0.1055613458 * a - 0.0638541728 * b
        let s_ = l - 0.0894841775 * a - 1.2914855480 * b

        let lc = l_ * l_ * l_
        let mc = m_ * m_ * m_
        let sc = s_ * s_ * s_

        var r = 4.0767416621 * lc - 3.3077115913 * mc + 0.2309699292 * sc
        var g = -1.2684380046 * lc + 2.6097574011 * mc - 0.3413193965 * sc
        var bl = -0.0041960863 * lc - 0.7034186147 * mc + 1.7076147010 * sc

        r = linearToSRGB(r)
        g = linearToSRGB(g)
        bl = linearToSRGB(bl)

        return (
            min(max(r, 0), 1),
            min(max(g, 0), 1),
            min(max(bl, 0), 1),
            alpha
        )
    }

    private func linearToSRGB(_ x: Double) -> Double {
        let v = min(max(x, 0), 1)
        if v <= 0.0031308 { return 12.92 * v }
        return 1.055 * pow(v, 1.0 / 2.4) - 0.055
    }
}

extension Color {
    init(_ oklch: OKLCH) {
        let s = oklch.srgb
        self.init(.sRGB, red: s.r, green: s.g, blue: s.b, opacity: s.a)
    }

    static func oklch(_ l: Double, _ c: Double, _ h: Double, alpha: Double = 1) -> Color {
        Color(OKLCH(l, c, h, alpha: alpha))
    }
}

extension Color {
    /// Parses a CSS-style hex string ("#4db3a8" or "4db3a8"). Returns nil on bad input.
    init?(hex raw: String) {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.hasPrefix("#") { s.removeFirst() }
        guard s.count == 6, let v = UInt32(s, radix: 16) else { return nil }
        let r = Double((v >> 16) & 0xFF) / 255.0
        let g = Double((v >> 8)  & 0xFF) / 255.0
        let b = Double( v        & 0xFF) / 255.0
        self = Color(red: r, green: g, blue: b)
    }
}

extension NSColor {
    convenience init(_ oklch: OKLCH) {
        let s = oklch.srgb
        self.init(srgbRed: s.r, green: s.g, blue: s.b, alpha: s.a)
    }

    static func dynamic(light: OKLCH, dark: OKLCH) -> NSColor {
        NSColor(name: nil, dynamicProvider: { appearance in
            let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            return NSColor(isDark ? dark : light)
        })
    }
}
