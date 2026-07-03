import Foundation
import ImageIO

/// Pass-17 (Lane C): reads embedded physical pixel-size metadata from microscope
/// TIFF files and returns a px/µm calibration value without any 3rd-party deps.
///
/// Parser priority:
///   1. OME-XML inside TIFF tag 270 (ImageDescription) — high confidence.
///   2. TIFF baseline XResolution/YResolution + ResolutionUnit — medium confidence.
///   3. Olympus vendor tag (OlympusIni / ImageDescription "Calibration Value") — low confidence.
///
/// All parsers are defensive: malformed XML / missing fields → nil, not a crash.
enum EXIFCalibration {

    struct Result {
        let pxPerUm: Double
        let source: Source
        let confidence: Confidence
    }

    enum Source: CustomStringConvertible {
        case omeXML
        case tiffBaseline
        case olympus
        case zeiss
        case imagej

        var description: String {
            switch self {
            case .omeXML:       return "OME-XML"
            case .tiffBaseline: return "TIFF baseline tags"
            case .olympus:      return "Olympus vendor tag"
            case .zeiss:        return "Zeiss vendor tag"
            case .imagej:       return "ImageJ metadata"
            }
        }
    }

    enum Confidence {
        case high, medium, low
    }

    /// Read embedded calibration. Returns nil if no recognizable metadata is found.
    /// Safe to call from any thread. Does NOT throw — all failures return nil.
    static func detectPxPerUm(at url: URL) -> Result? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, [
            kCGImageSourceShouldCache: false,
        ] as CFDictionary) else { return nil }

        guard let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any] else {
            return nil
        }

        // --- 1. Pull the raw image description string for text-based parsers ---
        let tiffDict = props[kCGImagePropertyTIFFDictionary] as? [CFString: Any]
        let imageDescription = tiffDict?[kCGImagePropertyTIFFImageDescription] as? String

        // --- 2. OME-XML in ImageDescription (highest confidence) ---
        if let desc = imageDescription, desc.contains("<OME") || desc.contains("<Pixels") {
            if let r = parseOMEXML(desc) { return r }
        }

        // --- 3. TIFF baseline XResolution/YResolution + ResolutionUnit ---
        if let r = parseTIFFBaseline(props: props, tiffDict: tiffDict) { return r }

        // --- 4. ImageJ metadata in ImageDescription (medium confidence) ---
        if let desc = imageDescription, desc.hasPrefix("ImageJ=") {
            if let r = parseImageJDescription(desc) { return r }
        }

        // --- 5. Olympus-style "Calibration Value" in ImageDescription (low confidence) ---
        if let desc = imageDescription {
            if let r = parseOlympusDescription(desc) { return r }
        }

        return nil
    }

    // MARK: — OME-XML parser

    /// Extracts `PhysicalSizeX` and `PhysicalSizeXUnit` from an OME-XML string.
    /// Uses regex first (fast path), falls back to XMLParser. Both are guarded
    /// with try? so malformed XML never crashes.
    private static func parseOMEXML(_ xml: String) -> Result? {
        // Fast path: regex for <Pixels … PhysicalSizeX="0.385" PhysicalSizeXUnit="µm" …>
        // The attributes may appear in any order and with any whitespace.
        let sizePattern = #"PhysicalSizeX\s*=\s*"([0-9]*\.?[0-9]+)""#
        let unitPattern = #"PhysicalSizeXUnit\s*=\s*"([^"]+)""#

        guard let sizeMatch = xml.range(of: sizePattern, options: .regularExpression),
              let sizeStr = String(xml[sizeMatch]).firstMatch(for: #"[0-9]*\.?[0-9]+"#),
              let physicalSizeX = Double(sizeStr)
        else { return nil }

        let unit: String
        if let unitMatch = xml.range(of: unitPattern, options: .regularExpression),
           let u = String(xml[unitMatch]).firstMatch(for: #"(?<=\")[^"]+(?=\")"#) {
            unit = u
        } else {
            unit = "µm"   // OME spec default
        }

        // OME-TIFFs can carry anisotropic pixels. Auto-calibration assumes a
        // single square-pixel scale, so if a Y axis is present and disagrees with
        // X beyond a 1% tolerance, refuse rather than silently calibrate off X
        // (mirrors the ImageJ pixelWidth/pixelHeight guard).
        let yUnit: String = {
            if let m = xml.range(of: #"PhysicalSizeYUnit\s*=\s*"([^"]+)""#, options: .regularExpression),
               let u = String(xml[m]).firstMatch(for: #"(?<=\")[^"]+(?=\")"#) { return u }
            return unit
        }()
        if let yMatch = xml.range(of: #"PhysicalSizeY\s*=\s*"([0-9]*\.?[0-9]+)""#, options: .regularExpression),
           let yStr = String(xml[yMatch]).firstMatch(for: #"[0-9]*\.?[0-9]+"#),
           let physicalSizeY = Double(yStr),
           let xMicrons = convertToMicrons(value: physicalSizeX, unit: unit),
           let yMicrons = convertToMicrons(value: physicalSizeY, unit: yUnit),
           xMicrons > 0, abs(yMicrons - xMicrons) > xMicrons * 0.01 {
            return nil
        }

        guard let pxPerUm = convertToMicrons(value: physicalSizeX, unit: unit).map({ 1.0 / $0 }) else {
            return nil
        }
        guard pxPerUm > 0, pxPerUm < 1000 else { return nil }

        return Result(pxPerUm: pxPerUm, source: .omeXML, confidence: .high)
    }

    // MARK: — TIFF baseline parser

    private static func parseTIFFBaseline(props: [CFString: Any],
                                          tiffDict: [CFString: Any]?) -> Result? {
        guard let tiff = tiffDict else { return nil }

        // ResolutionUnit: 1=no unit, 2=inch, 3=cm
        let unitRaw = tiff[kCGImagePropertyTIFFResolutionUnit] as? Int ?? 2

        // ImageIO gives XResolution as a Double (pixels per resolution-unit).
        guard let xRes = tiff[kCGImagePropertyTIFFXResolution] as? Double,
              xRes > 0 else { return nil }

        let pxPerUm: Double
        switch unitRaw {
        case 2: // inch → µm: 1 inch = 25400 µm
            pxPerUm = xRes / 25400.0
        case 3: // cm → µm: 1 cm = 10000 µm
            pxPerUm = xRes / 10000.0
        default:
            return nil   // no unit → unusable
        }

        // The TIFF baseline result is only medium-confidence yet gets
        // auto-applied to a whole batch. The old 0.001–1000 window spans six
        // orders of magnitude and admits ordinary document-scanner/printer
        // resolutions (200 dpi ≈ 0.0079 px/µm, 600 dpi ≈ 0.0236 px/µm) that no
        // microscope objective produces. Restrict to a plausible light-
        // microscopy range so a stack of scanned TIFFs can't silently rewrite
        // the batch calibration to a nonsense value.
        guard pxPerUm > 0.2, pxPerUm < 100 else { return nil }

        // Heuristic sanity: 72 and 96 dpi are the default screen/scanner DPI
        // values written by software without real calibration. Compare with a
        // small tolerance rather than exact float equality — on the cm path
        // pxPerInch is derived as xRes * 2.54 and will almost never land on
        // exactly 72.0/96.0 even when it should match. (300 dpi is a plausible
        // real microscope/scan resolution, so it is NOT treated as a default.)
        let pxPerInch = unitRaw == 2 ? xRes : xRes * 2.54
        if abs(pxPerInch - 72) < 0.5 || abs(pxPerInch - 96) < 0.5 {
            // Almost certainly a scanner/printer default, not real calibration.
            return nil
        }

        return Result(pxPerUm: pxPerUm, source: .tiffBaseline, confidence: .medium)
    }

    // MARK: — ImageJ metadata parser

    /// Parses lines like:
    ///   unit=micron
    ///   finterval=0.385
    ///   pixelWidth=0.385
    ///   pixelHeight=0.385
    private static func parseImageJDescription(_ desc: String) -> Result? {
        let lines = desc.components(separatedBy: "\n")
        var pixelWidth: Double? = nil
        var pixelHeight: Double? = nil
        var unit: String = "µm"

        for line in lines {
            let kv = line.trimmingCharacters(in: .whitespaces)
            if kv.lowercased().hasPrefix("pixelwidth="),
               let v = Double(kv.dropFirst("pixelwidth=".count).trimmingCharacters(in: .whitespaces)) {
                pixelWidth = v
            }
            if kv.lowercased().hasPrefix("pixelheight="),
               let v = Double(kv.dropFirst("pixelheight=".count).trimmingCharacters(in: .whitespaces)) {
                pixelHeight = v
            }
            if kv.lowercased().hasPrefix("unit=") {
                unit = String(kv.dropFirst("unit=".count)).trimmingCharacters(in: .whitespaces)
            }
        }

        guard let pw = pixelWidth, pw > 0 else { return nil }

        // ImageJ can carry anisotropic pixels (pixelWidth != pixelHeight after
        // binning / aspect corrections). We only model a single square-pixel
        // scale, so if the two axes disagree beyond a 1% tolerance, refuse to
        // silently apply the x-axis scale to both — a wrong y-axis / µm² area
        // is worse than no auto-calibration.
        if let ph = pixelHeight, ph > 0, abs(ph - pw) > pw * 0.01 {
            return nil
        }

        // pw is µm-per-pixel; we want px/µm
        let umPerPx: Double
        switch normalizedUnit(unit) {
        case "um", "µm", "micron", "microns": umPerPx = pw
        case "nm":                             umPerPx = pw / 1000.0
        case "mm":                             umPerPx = pw * 1000.0
        case "cm":                             umPerPx = pw * 10000.0
        case "m":                              umPerPx = pw * 1_000_000.0
        default:                               return nil
        }

        guard umPerPx > 0 else { return nil }
        let pxPerUm = 1.0 / umPerPx
        guard pxPerUm > 0.001, pxPerUm < 1000 else { return nil }

        return Result(pxPerUm: pxPerUm, source: .imagej, confidence: .medium)
    }

    // MARK: — Olympus description parser

    /// Olympus CellSens / BDP export puts lines like:
    ///   Calibration Unit=µm
    ///   Calibration Value=0.385
    private static func parseOlympusDescription(_ desc: String) -> Result? {
        let lines = desc.components(separatedBy: "\n")
        var calValue: Double? = nil
        var calUnit: String = "µm"

        for line in lines {
            let kv = line.trimmingCharacters(in: .whitespaces)
            if kv.lowercased().hasPrefix("calibration value="),
               let v = Double(kv.dropFirst("calibration value=".count).trimmingCharacters(in: .whitespaces)) {
                calValue = v
            }
            if kv.lowercased().hasPrefix("calibration unit=") {
                calUnit = String(kv.dropFirst("calibration unit=".count)).trimmingCharacters(in: .whitespaces)
            }
        }

        guard let cv = calValue, cv > 0 else { return nil }

        // Calibration Value is µm/pixel; convert to px/µm
        guard let umPerPx = convertToMicrons(value: cv, unit: calUnit),
              umPerPx > 0 else { return nil }
        let pxPerUm = 1.0 / umPerPx
        guard pxPerUm > 0.001, pxPerUm < 1000 else { return nil }

        return Result(pxPerUm: pxPerUm, source: .olympus, confidence: .low)
    }

    // MARK: — Unit conversion helper

    /// Normalizes a unit string for matching: lowercases, trims whitespace, and
    /// folds the Greek small letter mu (U+03BC) — written by many OME-XML/ImageJ
    /// exporters — onto the canonical micro sign (U+00B5) so "µm" matches
    /// regardless of which codepoint the source used.
    private static func normalizedUnit(_ unit: String) -> String {
        unit.lowercased()
            .trimmingCharacters(in: .whitespaces)
            .replacingOccurrences(of: "\u{03BC}", with: "\u{00B5}")
    }

    /// Converts a physical size value + unit string into µm.
    /// Returns nil for unrecognised units.
    private static func convertToMicrons(value: Double, unit: String) -> Double? {
        switch normalizedUnit(unit) {
        case "µm", "um", "micron", "microns":
            return value
        case "nm":
            return value / 1000.0
        case "pm":
            return value / 1_000_000.0
        case "mm":
            return value * 1000.0
        case "cm":
            return value * 10000.0
        case "m":
            return value * 1_000_000.0
        default:
            return nil
        }
    }
}

// MARK: — String helpers

private extension String {
    /// Returns the first match for `pattern` in self, or nil.
    func firstMatch(for pattern: String) -> String? {
        guard let r = range(of: pattern, options: .regularExpression) else { return nil }
        return String(self[r])
    }
}
