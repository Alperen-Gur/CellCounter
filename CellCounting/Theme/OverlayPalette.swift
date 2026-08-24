import SwiftUI
import AppKit

/// User-configurable colors for size bins and the image overlay.
///
/// The palette is a value type so it can be snapshotted for background export
/// work and compared by `CellsCanvas` without consulting `UserDefaults` while
/// rendering hundreds of cells. Hex strings also keep the persisted format
/// stable across SwiftUI/AppKit releases.
struct OverlayPalette: Codable, Equatable, Sendable {
    enum OverlayMode: String, Codable, CaseIterable, Sendable {
        case byBin
        case single

        var label: String {
            switch self {
            case .byBin: return "Color by size bin"
            case .single: return "Single high-contrast color"
            }
        }
    }

    static let defaultsKey = "cc-overlay-palette-v1"
    static let defaultBinHexes = ["#414487", "#2A788E", "#22A884", "#7AD151", "#FDE725"]
    static let `default` = OverlayPalette(
        binHexes: defaultBinHexes,
        overlayMode: .byBin,
        singleOverlayHex: "#00D7FF"
    )

    var binHexes: [String]
    var overlayMode: OverlayMode
    var singleOverlayHex: String

    init(binHexes: [String], overlayMode: OverlayMode, singleOverlayHex: String) {
        self.binHexes = binHexes.isEmpty ? Self.defaultBinHexes : binHexes
        self.overlayMode = overlayMode
        self.singleOverlayHex = Color(hex: singleOverlayHex) == nil ? "#00D7FF" : singleOverlayHex
    }

    static func load(defaults: UserDefaults = .standard) -> OverlayPalette {
        guard let data = defaults.data(forKey: defaultsKey),
              let decoded = try? JSONDecoder().decode(OverlayPalette.self, from: data) else {
            return .default
        }
        return decoded.normalized()
    }

    func save(defaults: UserDefaults = .standard) {
        defaults.set(try? JSONEncoder().encode(normalized()), forKey: Self.defaultsKey)
    }

    func normalized() -> OverlayPalette {
        let valid = binHexes.filter { Color(hex: $0) != nil }
        return OverlayPalette(
            binHexes: valid.isEmpty ? Self.defaultBinHexes : valid,
            overlayMode: overlayMode,
            singleOverlayHex: Color(hex: singleOverlayHex) == nil ? "#00D7FF" : singleOverlayHex
        )
    }

    func binHex(_ index: Int) -> String {
        let colors = binHexes.isEmpty ? Self.defaultBinHexes : binHexes
        return colors[max(0, min(index, colors.count - 1))]
    }

    func binColor(_ index: Int) -> Color {
        Color(hex: binHex(index)) ?? Color(hex: Self.defaultBinHexes[0])!
    }

    func overlayColor(forBin index: Int) -> Color {
        switch overlayMode {
        case .byBin: return binColor(index)
        case .single: return Color(hex: singleOverlayHex) ?? .cyan
        }
    }

    func cgColor(forBin index: Int, overlay: Bool = false) -> CGColor {
        let hex = overlay && overlayMode == .single ? singleOverlayHex : binHex(index)
        return NSColor(hex: hex)?.usingColorSpace(.sRGB)?.cgColor
            ?? CGColor(red: 0, green: 0.84, blue: 1, alpha: 1)
    }
}

extension NSColor {
    convenience init?(hex raw: String) {
        var value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.hasPrefix("#") { value.removeFirst() }
        guard value.count == 6, let rgb = UInt32(value, radix: 16) else { return nil }
        self.init(
            srgbRed: CGFloat((rgb >> 16) & 0xff) / 255,
            green: CGFloat((rgb >> 8) & 0xff) / 255,
            blue: CGFloat(rgb & 0xff) / 255,
            alpha: 1
        )
    }
}

extension Color {
    /// Stable #RRGGBB representation used by native `ColorPicker` bindings.
    var hexString: String? {
        guard let rgb = NSColor(self).usingColorSpace(.sRGB) else { return nil }
        return String(
            format: "#%02X%02X%02X",
            Int((rgb.redComponent * 255).rounded()),
            Int((rgb.greenComponent * 255).rounded()),
            Int((rgb.blueComponent * 255).rounded())
        )
    }
}
