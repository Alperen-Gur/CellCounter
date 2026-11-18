import Foundation

/// The pixel scale (px/µm) of one image: where it comes from, how it is
/// described, and how the scales of a batch are summarised and checked.
///
/// Every image has its own scale, taken from the first of:
/// 1. a value set for that image (typed, measured on its scale bar, a saved
///    preset, or an explicit override of the file's value);
/// 2. the scale recorded in the image file, when it is read with high or
///    medium confidence (`ImageRecord.sourcePxPerUm`);
/// 3. the batch's scale for images without one (`BatchRecord.pxPerUm`).
/// An image with none of these has no scale and is not analysed: there is no
/// built-in default.
///
/// Sources are stored as strings, so values recorded by older versions keep
/// their meaning: "exif-tiff", "exif-omeXML", "metadata-czi" (from the file),
/// "manual" / "manual-entry" (typed), "scale-bar", "preset-<name>",
/// "default" (the user's default for images without a scale),
/// "manual override (file: X px/µm)", and "batch:<source>" for a value an
/// image took from its batch (including every image analysed before images
/// had their own scale).
nonisolated enum ImageScale {
    /// Two scales within 0.5 % of each other are the same scale.
    static let tolerance = 0.005

    /// A scale with the provenance key of its source.
    struct Value: Codable, Equatable, Hashable, Sendable {
        var pxPerUm: Double
        var source: String
    }

    /// Which rule gave an image its scale.
    enum Origin: String, Codable, Equatable, Sendable {
        /// Set for this image.
        case image
        /// Read from the image file.
        case file
        /// The batch's scale for images without one.
        case batch
    }

    struct Resolved: Equatable, Sendable {
        var value: Value
        var origin: Origin
        var pxPerUm: Double { value.pxPerUm }
        var source: String { value.source }
    }

    static func isUsable(_ pxPerUm: Double?) -> Bool {
        guard let pxPerUm else { return false }
        return pxPerUm.isFinite && pxPerUm > 0
    }

    /// True when both are usable and within `tolerance` of each other.
    static func same(_ a: Double, _ b: Double) -> Bool {
        guard isUsable(a), isUsable(b) else { return false }
        return abs(a - b) / max(a, b) <= tolerance
    }

    // MARK: - Sources

    static let batchPrefix = "batch:"
    static let overridePrefix = "manual override"
    /// The user's default for images without a scale (Settings → Calibration).
    static let defaultSource = "default"
    /// No scale for images without one.
    static let unsetSource = "unset"
    static let typedSource = "manual-entry"
    static let scaleBarSource = "scale-bar"
    /// A value read from another image's file, used for images without a scale.
    static let otherFilePrefix = "file-of:"

    static func presetSource(_ name: String) -> String { "preset-\(name)" }

    /// Recorded when a value replaces the scale in an image's file.
    static func overrideSource(filePxPerUm: Double) -> String {
        "\(overridePrefix) (file: \(format(filePxPerUm)) px/µm)"
    }

    static func isOverride(_ source: String?) -> Bool {
        source?.hasPrefix(overridePrefix) == true
    }

    /// The source an image records for a value it takes from its batch.
    static func batchSource(_ batchSource: String?) -> String {
        if let batchSource, batchSource.hasPrefix(batchPrefix) { return batchSource }
        guard let batchSource, !batchSource.isEmpty else { return batchPrefix + "unrecorded" }
        return batchPrefix + batchSource
    }

    static func isFromFile(_ source: String?) -> Bool {
        guard let source else { return false }
        return source.hasPrefix("exif-") || source.hasPrefix("metadata")
    }

    /// Plain words for a source, as shown next to a scale.
    static func label(_ source: String?) -> String {
        guard let source, !source.isEmpty else { return "source not recorded" }
        if source.hasPrefix(batchPrefix) {
            let inner = String(source.dropFirst(batchPrefix.count))
            return inner == "unrecorded" || inner.isEmpty ? "batch scale" : "batch scale (\(label(inner)))"
        }
        if isOverride(source) {
            if let open = source.range(of: "(file: "),
               let close = source.range(of: ")", range: open.upperBound..<source.endIndex) {
                return "your override; file says \(source[open.upperBound..<close.lowerBound])"
            }
            return "your override"
        }
        if isFromFile(source) { return "from file" }
        if source.hasPrefix(otherFilePrefix) {
            return "from the file of \(source.dropFirst(otherFilePrefix.count))"
        }
        if source.hasPrefix("preset-") { return "preset “\(source.dropFirst("preset-".count))”" }
        switch source {
        case "manual", typedSource: return "typed"
        case scaleBarSource: return "scale bar"
        case defaultSource: return "your default"
        case "unconfirmed": return "not confirmed"
        case unsetSource: return "not set"
        default: return source
        }
    }

    /// The label used when scales are grouped: a value an image took from its
    /// batch is described by where the batch's value came from.
    static func groupLabel(_ value: Value) -> String {
        if value.source.hasPrefix(batchPrefix) {
            let inner = String(value.source.dropFirst(batchPrefix.count))
            return inner == "unrecorded" || inner.isEmpty ? "batch scale" : label(inner)
        }
        return label(value.source)
    }

    /// "4.1666 px/µm · from file"
    static func caption(_ value: Value) -> String {
        "\(format(value.pxPerUm)) px/µm · \(label(value.source))"
    }

    /// px/µm with up to four decimals and no trailing zeros: 4.1666, 8.3333, 2.6.
    static func format(_ pxPerUm: Double) -> String {
        SizeHint.format(pxPerUm, digits: 4)
    }

    static func countText(_ count: Int) -> String {
        count == 1 ? "1 image" : "\(count) images"
    }

    // MARK: - Resolution

    /// The scale an image is analysed at: its own value, else its file's,
    /// else the batch's scale for images without one; nil when none is usable.
    static func resolve(explicit: Value?, file: Value?, fallback: Value?) -> Resolved? {
        if let explicit, isUsable(explicit.pxPerUm) { return Resolved(value: explicit, origin: .image) }
        if let file, isUsable(file.pxPerUm) { return Resolved(value: file, origin: .file) }
        if let fallback, isUsable(fallback.pxPerUm) {
            return Resolved(value: Value(pxPerUm: fallback.pxPerUm, source: batchSource(fallback.source)),
                            origin: .batch)
        }
        return nil
    }

    /// Why an image must not be analysed with its own value, or nil. A value
    /// set for an image whose file records a different scale is accepted only
    /// as an explicit override, never silently.
    static func mismatch(explicit: Value?, file: Value?) -> String? {
        guard let explicit, let file, isUsable(explicit.pxPerUm), isUsable(file.pxPerUm),
              !isOverride(explicit.source), !same(explicit.pxPerUm, file.pxPerUm) else { return nil }
        return "This image's file says \(format(file.pxPerUm)) px/µm, but \(format(explicit.pxPerUm)) px/µm was set for it. "
            + "To use your value, choose “Override the file's scale” for this image; otherwise remove your value so the file's scale is used."
    }

    static let missingMessage = "This image has no pixel scale. Set one in Analysis setup: use the file's scale, draw on the scale bar, or type px/µm."

    // MARK: - Groups and summary

    /// One image's scale as shown in a summary.
    enum Entry: Equatable, Sendable {
        case scale(Value)
        /// No scale.
        case missing
        /// A microscope file whose scale is read when it is imported.
        case readOnImport
    }

    struct Group: Equatable, Sendable {
        var pxPerUm: Double
        var label: String
        var count: Int
        /// "8 images · 4.1666 px/µm (from file)"
        var line: String { "\(ImageScale.countText(count)) · \(ImageScale.format(pxPerUm)) px/µm (\(label))" }
    }

    struct Summary: Equatable, Sendable {
        var groups: [Group] = []
        var missing = 0
        var readOnImport = 0
        /// Different scale values, whatever their source.
        var distinctScales = 0

        var lines: [String] { groups.map(\.line) }
        /// "8 images · 4.1666 px/µm (from file) · 8 images · 8.3333 px/µm (from file)"
        var text: String { lines.joined(separator: " · ") }
        /// "4 images have no scale", or nil.
        var missingLine: String? {
            guard missing > 0 else { return nil }
            return missing == 1 ? "1 image has no scale" : "\(missing) images have no scale"
        }
        var readOnImportLine: String? {
            guard readOnImport > 0 else { return nil }
            return "\(ImageScale.countText(readOnImport)) · scale read from the file when imported"
        }
        /// Short form for overviews: "4.1666 px/µm", "2 scales", "No scale".
        var overview: String {
            var text: String
            switch distinctScales {
            case 0: text = missing > 0 ? "No scale" : "Scale not known yet"
            case 1: text = "\(ImageScale.format(groups[0].pxPerUm)) px/µm"
            default: text = "\(distinctScales) scales"
            }
            if missing > 0, distinctScales > 0 { text += " · \(missing) without" }
            return text
        }
    }

    /// Groups equal scales (within `tolerance`) that have the same source
    /// label, ordered by scale.
    static func summarize(_ entries: [Entry]) -> Summary {
        var summary = Summary()
        for entry in entries {
            switch entry {
            case .missing: summary.missing += 1
            case .readOnImport: summary.readOnImport += 1
            case .scale(let value):
                guard isUsable(value.pxPerUm) else { summary.missing += 1; continue }
                let label = groupLabel(value)
                if let index = summary.groups.firstIndex(where: { $0.label == label && same($0.pxPerUm, value.pxPerUm) }) {
                    summary.groups[index].count += 1
                } else {
                    summary.groups.append(Group(pxPerUm: value.pxPerUm, label: label, count: 1))
                }
            }
        }
        summary.groups.sort { ($0.pxPerUm, $0.label) < ($1.pxPerUm, $1.label) }
        var distinct: [Double] = []
        for group in summary.groups where !distinct.contains(where: { same($0, group.pxPerUm) }) {
            distinct.append(group.pxPerUm)
        }
        summary.distinctScales = distinct.count
        return summary
    }

    // MARK: - Overriding a file's scale

    /// What replacing the file's scale with `yours` does to the sizes.
    static func overrideEffect(yours: Double, file: Double) -> String {
        guard isUsable(yours), isUsable(file) else { return "" }
        if same(yours, file) { return "Your value matches the file's." }
        if yours < file {
            let ratio = ratioText(file / yours)
            return "Your value is \(ratio)× smaller than the file's, so sizes would be \(ratio)× larger."
        }
        let ratio = ratioText(yours / file)
        return "Your value is \(ratio)× larger than the file's, so sizes would be \(ratio)× smaller."
    }

    /// One line per file scale among the images being overridden:
    /// "File says 4.1666 px/µm (8 images). Your value is 1.6× smaller than the file's, so sizes would be 1.6× larger."
    static func overrideLines(yours: Double, files: [Double]) -> [String] {
        var groups: [(pxPerUm: Double, count: Int)] = []
        for file in files where isUsable(file) {
            if let index = groups.firstIndex(where: { same($0.pxPerUm, file) }) { groups[index].count += 1 }
            else { groups.append((file, 1)) }
        }
        return groups.sorted { $0.pxPerUm < $1.pxPerUm }.map { group in
            "File says \(format(group.pxPerUm)) px/µm (\(countText(group.count))). "
                + overrideEffect(yours: yours, file: group.pxPerUm)
        }
    }

    static func ratioText(_ ratio: Double) -> String {
        SizeHint.format(ratio, digits: ratio < 1.1 ? 2 : 1)
    }

    // MARK: - Objective names in file names

    /// Objective magnifications recognised in file names.
    static let objectiveMagnifications: Set<Int> = [4, 5, 10, 20, 40, 60, 63, 100]

    /// The objective a file name names as a separate token ("…_10x_…",
    /// "20X.tif", "40×"), case-insensitive. Nil when it names none, or more
    /// than one different one.
    static func objectiveToken(in fileName: String) -> Int? {
        let base = (fileName as NSString).deletingPathExtension
        let chars = Array(base)
        func isWordCharacter(_ c: Character) -> Bool { c.isLetter || c.isNumber }
        var found: Set<Int> = []
        var index = 0
        while index < chars.count {
            guard chars[index].isASCII, chars[index].isNumber else { index += 1; continue }
            let start = index
            var digits = ""
            while index < chars.count, chars[index].isASCII, chars[index].isNumber {
                digits.append(chars[index]); index += 1
            }
            // Start of the name or a separator before it; a decimal ("2.5x") is not a token.
            let boundedBefore = start == 0 || (!isWordCharacter(chars[start - 1])
                && !(chars[start - 1] == "." && start >= 2 && chars[start - 2].isNumber))
            guard boundedBefore, index < chars.count,
                  chars[index] == "x" || chars[index] == "X" || chars[index] == "×" else { continue }
            let boundedAfter = index + 1 == chars.count || !isWordCharacter(chars[index + 1])
            if boundedAfter, let value = Int(digits), objectiveMagnifications.contains(value) {
                found.insert(value)
            }
            index += 1
        }
        return found.count == 1 ? found.first : nil
    }

    /// One plain, non-blocking warning when objective names in the file names
    /// contradict the scales: images named for different objectives share a
    /// scale, or their scale ratio is far from the objectives' ratio.
    static func objectiveWarning(_ images: [(fileName: String, pxPerUm: Double?)]) -> String? {
        var byToken: [Int: [Double]] = [:]
        for image in images {
            guard let pxPerUm = image.pxPerUm, isUsable(pxPerUm),
                  let token = objectiveToken(in: image.fileName) else { continue }
            byToken[token, default: []].append(pxPerUm)
        }
        let tokens = byToken.keys.sorted()
        guard tokens.count >= 2 else { return nil }
        for (position, low) in tokens.enumerated() {
            for high in tokens[(position + 1)...] {
                let highScales = byToken[high] ?? []
                if let shared = (byToken[low] ?? []).first(where: { scale in highScales.contains { same($0, scale) } }) {
                    return "Images named \(low)x and \(high)x have the same scale (\(format(shared)) px/µm). "
                        + "Different objectives normally have different scales. Check the scales before you start."
                }
            }
        }
        for (position, low) in tokens.enumerated() {
            for high in tokens[(position + 1)...] {
                guard let lowScale = median(byToken[low] ?? []), let highScale = median(byToken[high] ?? []) else { continue }
                let actual = highScale / lowScale
                let expected = Double(high) / Double(low)
                let agreement = actual / expected
                if agreement < 0.75 || agreement > 1.33 {
                    return "Images named \(high)x have \(ratioText(actual))× the scale of images named \(low)x, "
                        + "but the names suggest about \(ratioText(expected))×. Check the scales before you start."
                }
            }
        }
        return nil
    }

    private static func median(_ values: [Double]) -> Double? {
        guard !values.isEmpty else { return nil }
        let sorted = values.sorted()
        let middle = sorted.count / 2
        return sorted.count.isMultiple(of: 2) ? (sorted[middle - 1] + sorted[middle]) / 2 : sorted[middle]
    }

    // MARK: - Re-segment or rescale

    /// Whether segmenting an image again at another scale can give other
    /// outlines: the model is told the expected cell size in pixels
    /// (`SizeHint`), or touching cells are split with a spacing set in µm.
    /// Otherwise a new scale changes only the µm values.
    static func segmentationDependsOnScale(modelFamily: String, modelId: String,
                                           expectedDiameterUm: Double, watershedSplit: Bool) -> Bool {
        if watershedSplit { return true }
        switch SizeHint.behavior(modelFamily: modelFamily, modelId: modelId) {
        case .cellposeRescale, .mixed: return true
        case .omniposeRescale, .watershedSpacing: return !SizeHint.isAutomatic(expectedDiameterUm)
        case .unused: return false
        }
    }

    static func segmentationDependsOnScale(_ settings: AnalysisRunSettings) -> Bool {
        segmentationDependsOnScale(modelFamily: settings.modelFamily, modelId: settings.modelId,
                                   expectedDiameterUm: settings.expectedDiameterUm,
                                   watershedSplit: settings.watershedSplit)
    }

    // MARK: - Notices on analysed images

    /// "Segmented at 4.1666 px/µm, measured at 8.3333 px/µm" when the model
    /// saw the image at another scale than its numbers use, or nil.
    static func segmentationNote(segmented: Double?, measured: Double?) -> String? {
        guard let segmented, let measured, isUsable(segmented), isUsable(measured),
              !same(segmented, measured) else { return nil }
        return "Segmented at \(format(segmented)) px/µm, measured at \(format(measured)) px/µm"
    }

    enum Notice: Equatable, Sendable {
        /// Analysed at one scale while the file records another.
        case fileDisagrees(measured: Double, file: Double)
        /// The image's scale changed; its numbers follow after it is analysed again.
        case awaitingAnalysis(measured: Double, next: Double)

        var text: String {
            switch self {
            case .fileDisagrees(let measured, let file):
                return "Measured at \(ImageScale.format(measured)) px/µm; the file says \(ImageScale.format(file)) px/µm."
            case .awaitingAnalysis(let measured, let next):
                return "Measured at \(ImageScale.format(measured)) px/µm; its scale is now \(ImageScale.format(next)) px/µm. Re-run to update."
            }
        }
    }

    /// A one-line notice when an analysed image's numbers use another scale
    /// than the image now has, or nil. Old numbers are never changed
    /// automatically; the notice offers to analyse the image again.
    static func notice(measured: Value?, effective: Resolved?) -> Notice? {
        guard let measured, let effective, isUsable(measured.pxPerUm),
              !same(measured.pxPerUm, effective.pxPerUm) else { return nil }
        if effective.origin == .file { return .fileDisagrees(measured: measured.pxPerUm, file: effective.pxPerUm) }
        return .awaitingAnalysis(measured: measured.pxPerUm, next: effective.pxPerUm)
    }
}

// MARK: - Changing scales

/// Turns a scale chosen in the calibration sheet into per-image changes.
///
/// A typed value, a scale-bar measurement or a preset applies by default to
/// images without a scale of their own (it becomes the batch's scale for
/// them). It replaces a file's scale only when the user explicitly asks to
/// override it, and that is recorded as `manual override (file: X px/µm)`.
nonisolated enum ScaleChange {
    struct ImageState: Equatable, Sendable {
        var id: UUID
        var fileName: String = ""
        /// The image's own value.
        var explicit: ImageScale.Value?
        /// The file's scale (high or medium confidence).
        var file: ImageScale.Value?
        /// Scale of the stored measurements; nil when not analysed.
        var measured: ImageScale.Value?
        /// Whether the outlines of its analysis depend on the scale.
        var segmentationDependsOnScale: Bool = true
    }

    /// What the calibration sheet works with for one batch.
    struct Context: Equatable, Sendable {
        var batchId: UUID
        var images: [ImageState]
        /// The batch's scale for images without one.
        var fallback: ImageScale.Value?
        var currentImageId: UUID?

        var currentImage: ImageState? { images.first { $0.id == currentImageId } }
        /// Images that take the batch's scale (no own value, no file scale).
        var withoutOwnScaleCount: Int { images.filter { $0.explicit == nil && $0.file == nil }.count }
        /// Images whose file records a scale and that have no own value other than an override.
        var fileScaled: [ImageState] {
            images.filter { $0.file != nil && ($0.explicit == nil || ImageScale.isOverride($0.explicit?.source)) }
        }
    }

    enum Scope: Equatable, Sendable {
        /// The batch's scale for images without one.
        case imagesWithoutOwnScale
        /// One image's own value.
        case image(UUID)
    }

    struct Request: Equatable, Sendable {
        var value: ImageScale.Value
        var scope: Scope
        /// Also replace the file's scale for images whose file records one.
        var overrideFiles = false
        /// With `.image`: remove the image's own value so its file's scale is used.
        var useFileScale = false
    }

    struct Plan: Equatable, Sendable {
        /// New batch scale for images without one; nil keeps it.
        var fallback: ImageScale.Value?
        /// New own values; a nil value removes the image's own value.
        var explicit: [UUID: ImageScale.Value?] = [:]
        /// Analysed images whose stored measurements must move to a new scale.
        var changed: [UUID: ImageScale.Value] = [:]
        /// Analysed images whose scale keeps its value but gets a new source.
        var relabel: [UUID: ImageScale.Value] = [:]
        /// Of `changed`, those whose outlines depend on the scale.
        var resegment: Set<UUID> = []
        /// Images whose file's scale is replaced.
        var overridden = 0

        var isEmpty: Bool { fallback == nil && explicit.isEmpty }
        /// Whether to offer "Re-run segmentation (recommended)" or "Only rescale sizes".
        var offersResegmentation: Bool { !resegment.isEmpty }
    }

    static func plan(_ request: Request, context: Context) -> Plan {
        var plan = Plan()
        let value = request.value
        guard ImageScale.isUsable(value.pxPerUm) else { return plan }
        var fallback = context.fallback
        var fallbackChanged = false
        switch request.scope {
        case .imagesWithoutOwnScale:
            plan.fallback = value
            fallbackChanged = context.fallback != value
            fallback = value
            if request.overrideFiles {
                for image in context.fileScaled {
                    guard let file = image.file else { continue }
                    let override = ImageScale.Value(pxPerUm: value.pxPerUm,
                                                    source: ImageScale.overrideSource(filePxPerUm: file.pxPerUm))
                    if image.explicit != override { plan.explicit[image.id] = .some(override) }
                    plan.overridden += 1
                }
            }
        case .image(let id):
            guard let image = context.images.first(where: { $0.id == id }) else { return plan }
            if request.useFileScale {
                guard image.file != nil else { return plan }
                // The file's scale is used once the image has no value of its own.
                plan.explicit[id] = .some(nil)
            } else if let file = image.file {
                guard request.overrideFiles else { return plan }
                plan.explicit[id] = .some(ImageScale.Value(pxPerUm: value.pxPerUm,
                                                           source: ImageScale.overrideSource(filePxPerUm: file.pxPerUm)))
                plan.overridden = 1
            } else {
                plan.explicit[id] = .some(value)
            }
        }
        // Only images this request changes are touched: an image keeps its
        // stored numbers unless its own scale is what the user changed.
        for image in context.images {
            let explicit: ImageScale.Value?
            let targeted: Bool
            if let change = plan.explicit[image.id] {
                explicit = change
                targeted = true
            } else {
                explicit = image.explicit
                targeted = fallbackChanged && explicit == nil && image.file == nil
            }
            guard targeted, let measured = image.measured,
                  let next = ImageScale.resolve(explicit: explicit, file: image.file, fallback: fallback) else { continue }
            if !ImageScale.same(measured.pxPerUm, next.pxPerUm) {
                plan.changed[image.id] = next.value
                if image.segmentationDependsOnScale { plan.resegment.insert(image.id) }
            } else if measured.source != next.source {
                plan.relabel[image.id] = ImageScale.Value(pxPerUm: measured.pxPerUm, source: next.source)
            }
        }
        return plan
    }
}

extension ImageScale.Value {
    /// Nil for a missing, zero, negative or non-finite value.
    init?(_ pxPerUm: Double?, source: String?) {
        guard let pxPerUm, ImageScale.isUsable(pxPerUm) else { return nil }
        self.init(pxPerUm: pxPerUm, source: source ?? "")
    }
}
