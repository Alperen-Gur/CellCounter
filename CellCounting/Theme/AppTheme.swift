import SwiftUI
import Observation

enum ThemeMode: String, Codable, CaseIterable {
    case system, light, dark
}

struct AccentChoice: Identifiable, Equatable {
    let id: String
    let name: String
    let hue: Double
    var hex: String { id }

    static let coral  = AccentChoice(id: "#e89177", name: "Coral",  hue: 30)
    static let teal   = AccentChoice(id: "#4db3a8", name: "Teal",   hue: 195)
    static let indigo = AccentChoice(id: "#9a88e3", name: "Indigo", hue: 280)
    static let slate  = AccentChoice(id: "#76a0e8", name: "Slate",  hue: 245)

    static let all: [AccentChoice] = [.coral, .teal, .indigo, .slate]
}

@Observable
final class AppTheme {
    var mode: ThemeMode {
        didSet { UserDefaults.standard.set(mode.rawValue, forKey: "cc-theme") }
    }
    var accent: AccentChoice {
        didSet { UserDefaults.standard.set(accent.id, forKey: "cc-accent") }
    }

    init() {
        let savedMode = UserDefaults.standard.string(forKey: "cc-theme").flatMap(ThemeMode.init(rawValue:))
        let savedAccentId = UserDefaults.standard.string(forKey: "cc-accent")
        self.mode = savedMode ?? .light
        self.accent = AccentChoice.all.first(where: { $0.id == savedAccentId }) ?? .coral
    }

    var colorScheme: ColorScheme? {
        switch mode {
        case .system: return nil
        case .light:  return .light
        case .dark:   return .dark
        }
    }

    // Accent-derived colors (depend on hue + light/dark)
    var accentColor: Color       { Color(OKLCH(0.685, 0.155, accent.hue)) }
    var accentHover: Color       { Color(OKLCH(0.625, 0.155, accent.hue)) }
    var accentSoft: Color        { Color(OKLCH(0.685, 0.155, accent.hue, alpha: 0.12)) }
    var accentSoftDark: Color    { Color(OKLCH(0.685, 0.155, accent.hue, alpha: 0.20)) }
    var accentSofter: Color      { Color(OKLCH(0.685, 0.155, accent.hue, alpha: 0.06)) }
    var accentSofterDark: Color  { Color(OKLCH(0.685, 0.155, accent.hue, alpha: 0.10)) }
    var focusRing: Color         { Color(OKLCH(0.685, 0.155, accent.hue, alpha: 0.35)) }

    /// Selected nav-item tint
    func selected(for scheme: ColorScheme) -> Color {
        scheme == .dark ? accentSoftDark : accentSoft
    }

    func accentSoftAdaptive(for scheme: ColorScheme) -> Color {
        scheme == .dark ? accentSoftDark : accentSoft
    }
    func accentSofterAdaptive(for scheme: ColorScheme) -> Color {
        scheme == .dark ? accentSofterDark : accentSofter
    }
}
