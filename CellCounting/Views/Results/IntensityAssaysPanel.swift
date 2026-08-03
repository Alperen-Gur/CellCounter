import SwiftUI

// MOUNT (intensity assays)
// ─────────────────────────────────────────────────────────────────────────────
// `IntensityAssaysPanel` is the single mount point for all six intensity
// assays. It lives in the Results sidebar (`ResultsView.swift`,
// `ResultsSidebar.body`) directly AFTER `MeasurementsPanel` — the assays are
// derived measurements, so they read as a continuation of that block:
//
//       MeasurementsPanel(cells: cells)
//       IntensityAssaysPanel(cells: cells,
//                            imageStats: state.currentImage?.detection?.imageStats ?? [:])
//
// It draws its OWN leading `Divider()`, inside the same guard that decides
// whether to render — like `MeasurementsPanel` and `ColoniesPanel`. Separators
// supplied by the caller would still be emitted when the panel hides itself and
// stack against the next panel's.
//
// It takes plain values rather than `AppState` on purpose: every assay is a
// pure function of the cells plus the image-stats blob, so the panel stays
// previewable and the maths stays testable. `cells` should be the SAME
// confidence/ROI-filtered array the other panels receive, so a filtered-out
// cell can't inflate a percentage.
//
// The panel hides itself entirely when the detection carries neither
// per-channel intensities nor sidecar assay stats — mirroring
// `MeasurementsPanel` / `ColoniesPanel`, so single-channel brightfield work is
// unaffected. It ALSO withholds the assays (behind an explicit opt-in) when the
// three "channels" are just the R/G/B planes of an ordinary colour photograph —
// see `isPlainRGBSource`.
//
// WHERE THE NUMBERS COME FROM
// ───────────────────────────
//   • Positivity, viability, cell cycle — computed live in Swift from
//     `DetectedCell.channelIntensities`; they update as the user drags a
//     threshold, with no Python round-trip.
//   • N:C ratio and colocalization — read back from `image_stats` keys written
//     by `CellCounting/python/intensity_assays.py`. Pearson and Manders are
//     pixel-level definitions and cannot be reconstructed from per-cell means,
//     so those panels ask for the sidecar rather than approximating.

/// Container for the six intensity-based assays. Groups them into four
/// sub-panels: positivity (% marker-positive + transfection efficiency),
/// viability, cell cycle, and the two pixel-level ratio/overlap readouts.
struct IntensityAssaysPanel: View {
    let cells: [DetectedCell]
    let imageStats: [String: Double]

    /// User opt-in for the R/G/B case below. Off by default and deliberately
    /// NOT persisted: it is a per-image judgement ("this particular RGB file
    /// really is a fluorescence composite"), not a preference.
    @State private var treatRGBAsFluorescence = false

    private var channels: [AssayChannel] {
        IntensityAssays.channels(in: cells)
    }

    /// True when the assay sidecar has written pixel-level results for this image.
    private var hasSidecarResults: Bool {
        IntensityAssays.colocalization(fromImageStats: imageStats) != nil
            || IntensityAssays.nuclearCytoplasmic(fromImageStats: imageStats) != nil
    }

    /// True when the "channels" are just the R/G/B planes of an ordinary colour
    /// photograph rather than separate fluorescence acquisitions.
    ///
    /// WHY A NAME TEST. `_imageio` knows the answer exactly — it sets
    /// `is_rgb` in its metadata — but that flag never crosses the sidecar
    /// boundary: the only per-image channel back to Swift is
    /// `DetectedCell.channelIntensities`, and `image_stats` is a
    /// `[String: Double]` of QC/colony scalars with no slot for it. What DOES
    /// cross is the channel NAME, and `_imageio.load_planes` hard-codes
    /// exactly `["R", "G", "B"]` — and only that triple — when `is_rgb` is
    /// true for a 3-channel source (`_imageio.py:818-820`, and the PIL
    /// fallback at `:727` which sets `is_rgb=True` for every ordinary RGB
    /// PNG/JPG). Unnamed fluorescence channels come back as `Ch0/Ch1/Ch2`
    /// (`_fit_names`) and named ones as `DAPI`/`GFP`/…, so this test is
    /// exactly as precise as the `is_rgb` flag itself for the 3-channel case.
    ///
    /// Without it, a brightfield or phase-contrast photograph reported "3
    /// channels available" and offered "% marker-positive" pre-set to the
    /// GREEN channel — real arithmetic over a colour plane that means nothing,
    /// presented with no caveat at all.
    private var isPlainRGBSource: Bool {
        guard channels.count == 3 else { return false }
        let names = channels.map { ($0.name ?? "").uppercased() }
        return names == ["R", "G", "B"]
    }

    /// The assays render only when the channels are (or are asserted to be)
    /// real fluorescence channels.
    private var assaysUnlocked: Bool { !isPlainRGBSource || treatRGBAsFluorescence }

    var body: some View {
        let channels = self.channels
        if channels.isEmpty && !hasSidecarResults {
            return AnyView(EmptyView())
        }
        return AnyView(
            VStack(spacing: 0) {
                // Own leading divider, inside the guard above — see the
                // sibling panels; an unconditional one in ResultsSidebar would
                // double up whenever this panel hides.
                Divider().overlay(Tokens.divider)

                VStack(spacing: 0) {
                    SectionHeader(title: "Intensity assays")
                    AssayCaption(
                        "Post-processing over the cells already segmented — "
                        + "no re-detection. "
                        + (isPlainRGBSource
                           ? "Source is an RGB colour image (R, G, B planes)."
                           : "\(channels.count) channel"
                             + (channels.count == 1 ? "" : "s") + " available."))
                }
                .padding(.horizontal, 18)
                .padding(.top, 18)
                .padding(.bottom, 10)

                if channels.isEmpty {
                    AssayUnavailableNote(AssayAvailability.noChannelData.message)
                        .padding(.horizontal, 18)
                        .padding(.bottom, 18)
                } else if !assaysUnlocked {
                    rgbSourceNote
                } else {
                    if isPlainRGBSource { rgbOverrideBanner }
                    PositivityAssayPanel(cells: cells, channels: channels)
                    Divider().overlay(Tokens.divider)
                    ViabilityAssayPanel(cells: cells, channels: channels)
                    Divider().overlay(Tokens.divider)
                    CellCyclePanel(cells: cells, channels: channels)
                    Divider().overlay(Tokens.divider)
                }

                if assaysUnlocked || hasSidecarResults {
                    ColocalizationPanel(cells: cells,
                                        channels: channels,
                                        imageStats: imageStats)
                }
            }
            // The RGB override is a judgement about ONE file, so it must not
            // survive into the next one. The panel isn't given the image id,
            // but a detection's cell UUIDs are unique to it, so the first
            // cell's id changes on both a page and a re-detect.
            .onChange(of: cells.first?.id) { _, _ in treatRGBAsFluorescence = false }
        )
    }

    /// Shown INSTEAD of the assays for a plain RGB photograph. The numbers are
    /// withheld rather than captioned: a percentage on screen is read as a
    /// result no matter what sits beside it.
    private var rgbSourceNote: some View {
        VStack(alignment: .leading, spacing: 10) {
            AssayUnavailableNote(
                "These are the R, G and B planes of an ordinary colour image — "
                + "not separate fluorescence channels. Thresholding one of them "
                + "would produce a real-looking percentage from a meaningless "
                + "input, so the assays are withheld.")
            Button("This file is a fluorescence composite — enable anyway") {
                treatRGBAsFluorescence = true
            }
            .appButton(.standard, size: .sm)
        }
        .padding(.horizontal, 18)
        .padding(.bottom, 18)
    }

    /// Kept visible for the whole session once the user overrides, so an
    /// exported number is never remembered as having come from a clean source.
    private var rgbOverrideBanner: some View {
        AssayCaption("Reading the R/G/B planes as fluorescence channels at your "
                     + "request — the file reports itself as an ordinary colour image.")
            .padding(.horizontal, 18)
            .padding(.bottom, 10)
    }
}

// MARK: — Assay 1 + 5: positivity

/// `% marker-positive` (Ki67, EdU, BrdU, cleaved caspase-3) and
/// `Transfection efficiency` — identical maths, surfaced under both names
/// because that's what users search for. The preset switch changes the
/// vocabulary and the default channel guess, nothing else.
struct PositivityAssayPanel: View {
    let cells: [DetectedCell]
    let channels: [AssayChannel]

    enum Preset: String, CaseIterable, Hashable {
        case marker, transfection

        var title: String {
            switch self {
            case .marker:       return "% marker-positive"
            case .transfection: return "Transfection efficiency"
            }
        }
        var readoutLabel: String {
            switch self {
            case .marker:       return "positive"
            case .transfection: return "transfected"
            }
        }
        var channelLabel: String {
            switch self {
            case .marker:       return "Marker channel"
            case .transfection: return "Reporter channel"
            }
        }
        var hint: String {
            switch self {
            case .marker:
                return "Ki67, EdU, BrdU, cleaved caspase-3 — one channel, one cut-off."
            case .transfection:
                return "% of cells expressing the reporter (GFP, mCherry, …)."
            }
        }
    }

    @State private var preset: Preset = .marker
    @State private var channelIndex: Int? = nil
    @State private var metric: AssayMetric = .mean
    @State private var mode: AssayThresholdMode = .otsu
    @State private var manualThreshold: Double? = nil
    @State private var k: Double = 3.0

    @Environment(AppTheme.self) private var theme

    private var channel: AssayChannel {
        if let channelIndex, let match = channels.first(where: { $0.index == channelIndex }) {
            return match
        }
        // The final fallback can't be `channels[0]`: `body` evaluates this even
        // on the branch where the panel renders nothing useful.
        return IntensityAssays.likelyMarkerChannel(in: channels)
            ?? channels.first
            ?? AssayChannel(index: 0, name: nil)
    }

    private var rawValues: [Double] {
        IntensityAssays.values(in: cells, channel: channel.index, metric: metric)
            .map(\.value)
    }

    /// Seed for the manual slider: Otsu when it resolves, else the midpoint.
    private var seedThreshold: Double {
        if let otsu = IntensityAssays.otsuThreshold(rawValues) { return otsu }
        let values = rawValues
        guard let lo = values.min(), let hi = values.max() else { return 0 }
        return 0.5 * (lo + hi)
    }

    private var manualBinding: Binding<Double> {
        Binding(get: { manualThreshold ?? seedThreshold },
                set: { manualThreshold = $0 })
    }

    private var outcome: Result<MarkerPositivityResult, AssayAvailability> {
        IntensityAssays.markerPositive(cells: cells,
                                       channel: channel,
                                       metric: metric,
                                       mode: mode,
                                       manualThreshold: manualBinding.wrappedValue,
                                       k: k)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            SegmentedPicker(value: $preset,
                            options: Preset.allCases.map { ($0, $0.title) })
            AssayCaption(preset.hint)

            AssayChannelMenu(label: preset.channelLabel,
                             channels: channels,
                             selection: Binding(get: { channel.index },
                                                set: { channelIndex = $0 }))

            AssayFieldLabel("Per-cell statistic")
            SegmentedPicker(value: $metric,
                            options: AssayMetric.allCases.map { ($0, $0.label) })

            AssayFieldLabel("Threshold")
            SegmentedPicker(value: $mode,
                            options: AssayThresholdMode.allCases.map { ($0, $0.label) })
            AssayCaption(mode.blurb)

            if mode == .manual {
                ManualThresholdSlider(value: manualBinding, values: rawValues)
            }
            if mode == .negativeSD {
                AssayStepperRow(label: "k", value: $k,
                                range: 1...6, step: 0.5,
                                format: "%.1f")
            }

            switch outcome {
            case .failure(let reason):
                AssayUnavailableNote(reason.message)
            case .success(let result):
                VStack(spacing: 4) {
                    AssayHeadlineRow(
                        value: String(format: "%.1f", result.percentPositive),
                        unit: "%",
                        caption: "\(result.positiveCount) of \(result.cellCount) cells "
                               + preset.readoutLabel)
                    AssayProportionBar(fraction: result.percentPositive / 100,
                                       fillColor: theme.accentColor)
                        .padding(.vertical, 2)
                    AssayStatRow(label: "Threshold",
                                 value: format(result.threshold),
                                 unit: metric == .integrated ? "AU" : "")
                    AssayStatRow(label: preset.readoutLabel.capitalized,
                                 value: "\(result.positiveCount)", unit: "cells")
                    AssayStatRow(label: "Negative",
                                 value: "\(result.negativeCount)", unit: "cells")
                    if let v = result.meanPositive {
                        AssayStatRow(label: "Mean, positive", value: format(v), unit: "")
                    }
                    if let v = result.meanNegative {
                        AssayStatRow(label: "Mean, negative", value: format(v), unit: "")
                    }
                    if let mean = result.negativeMean, let sd = result.negativeSD {
                        AssayCaption("Negative population: mean \(format(mean)), "
                                     + "SD \(format(sd)) → cut-off = mean + "
                                     + "\(String(format: "%.1f", k))·SD.")
                    }
                }
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 16)
        .onChange(of: channel.index) { manualThreshold = nil }
        .onChange(of: metric) { manualThreshold = nil }
        .onChange(of: preset) { channelIndex = nil; manualThreshold = nil }
    }

    private func format(_ v: Double) -> String {
        abs(v) >= 10_000 ? String(format: "%.3g", v) : String(format: "%.2f", v)
    }
}

// MARK: — Shared atoms
//
// Deliberately internal (not private) so the sibling assay panels reuse them.
// Names are prefixed `Assay…` so they can't collide with the private `MeasRow`
// in ResultsView.swift or `ColonyRow` in ColoniesPanel.swift.

/// Two-column key/value row, matching `MeasRow` / `ColonyRow`.
struct AssayStatRow: View {
    let label: String
    let value: String
    var unit: String = ""
    var emphasized: Bool = false

    var body: some View {
        HStack {
            Text(label)
                .font(.system(size: 12.5))
                .foregroundStyle(Tokens.textSecondary)
            Spacer()
            HStack(spacing: 3) {
                Text(value)
                    .font(.system(size: 12.5,
                                  weight: emphasized ? .semibold : .regular,
                                  design: .monospaced))
                    .foregroundStyle(Tokens.text)
                if !unit.isEmpty {
                    Text(unit)
                        .font(.system(size: 11.5))
                        .foregroundStyle(Tokens.textTertiary)
                }
            }
        }
        .padding(.vertical, 4)
    }
}

/// The single number a researcher copies into a figure legend.
struct AssayHeadlineRow: View {
    let value: String
    let unit: String
    let caption: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 2) {
                Text(value)
                    .font(.system(size: 26, weight: .semibold, design: .monospaced))
                    .foregroundStyle(Tokens.text)
                Text(unit)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(Tokens.textSecondary)
            }
            Text(caption)
                .font(.system(size: 11))
                .foregroundStyle(Tokens.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(.top, 2)
        .padding(.bottom, 2)
    }
}

/// Small uppercase label above a control.
struct AssayFieldLabel: View {
    let text: String
    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text)
            .font(.system(size: 11.5, weight: .medium))
            .foregroundStyle(Tokens.textSecondary)
    }
}

/// Explanatory caption — never carries a number the user might mistake for a result.
struct AssayCaption: View {
    let text: String
    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text)
            .font(.system(size: 10.5))
            .foregroundStyle(Tokens.textTertiary)
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// Why an assay can't run. Shown instead of a misleading zero.
struct AssayUnavailableNote: View {
    let message: String
    init(_ message: String) { self.message = message }

    var body: some View {
        HStack(alignment: .top, spacing: 7) {
            Icon("info", size: 12)
                .foregroundStyle(Tokens.textTertiary)
            Text(message)
                .font(.system(size: 11))
                .foregroundStyle(Tokens.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: Tokens.Radius.sm).fill(Tokens.bgSunken))
        .overlay(RoundedRectangle(cornerRadius: Tokens.Radius.sm)
            .strokeBorder(Tokens.border, lineWidth: 0.5))
    }
}

/// Channel picker. A menu rather than a segmented control because a CZI/LIF
/// stack can legitimately carry six or more channels.
struct AssayChannelMenu: View {
    let label: String
    let channels: [AssayChannel]
    @Binding var selection: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            AssayFieldLabel(label)
            Menu {
                ForEach(channels) { channel in
                    Button(channel.indexedName) { selection = channel.index }
                }
            } label: {
                HStack(spacing: 6) {
                    Text(channels.first { $0.index == selection }?.displayName
                         ?? "Channel \(selection)")
                        .font(.system(size: 12))
                        .foregroundStyle(Tokens.text)
                        .lineLimit(1)
                    Spacer(minLength: 0)
                    Icon("chevron", size: 10)
                        .foregroundStyle(Tokens.textTertiary)
                }
                .padding(.horizontal, 9)
                .padding(.vertical, 5)
                .background(RoundedRectangle(cornerRadius: Tokens.Radius.sm)
                    .fill(Tokens.bgElevated))
                .overlay(RoundedRectangle(cornerRadius: Tokens.Radius.sm)
                    .strokeBorder(Tokens.borderStrong, lineWidth: 0.5))
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// Slider over the observed per-cell range, with the value spelled out.
struct ManualThresholdSlider: View {
    @Binding var value: Double
    let values: [Double]

    private var bounds: ClosedRange<Double> {
        guard let lo = values.min(), let hi = values.max(), hi > lo else {
            return 0...1
        }
        return lo...hi
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Slider(value: $value, in: bounds)
                .controlSize(.small)
            HStack {
                Text(String(format: "%.4g", bounds.lowerBound))
                Spacer()
                Text(String(format: "%.4g", value))
                    .foregroundStyle(Tokens.text)
                Spacer()
                Text(String(format: "%.4g", bounds.upperBound))
            }
            .font(.system(size: 10, design: .monospaced))
            .foregroundStyle(Tokens.textTertiary)
        }
    }
}

/// −/+ stepper for a small numeric parameter (k, gate width).
struct AssayStepperRow: View {
    let label: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    let step: Double
    var format: String = "%.1f"

    var body: some View {
        HStack {
            Text(label)
                .font(.system(size: 12.5))
                .foregroundStyle(Tokens.textSecondary)
            Spacer()
            HStack(spacing: 6) {
                Button {
                    value = max(range.lowerBound, value - step)
                } label: { Icon("minus", size: 10) }
                    .buttonStyle(.plain)
                    .foregroundStyle(Tokens.textSecondary)
                Text(String(format: format, value))
                    .font(.system(size: 12.5, design: .monospaced))
                    .foregroundStyle(Tokens.text)
                    .frame(minWidth: 30)
                Button {
                    value = min(range.upperBound, value + step)
                } label: { Icon("plus", size: 10) }
                    .buttonStyle(.plain)
                    .foregroundStyle(Tokens.textSecondary)
            }
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(RoundedRectangle(cornerRadius: Tokens.Radius.sm)
                .fill(Tokens.bgSunken))
        }
        .padding(.vertical, 2)
    }
}

/// Single-fill proportion bar (positive vs negative).
struct AssayProportionBar: View {
    let fraction: Double
    let fillColor: Color

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Tokens.bgSunken)
                Capsule()
                    .fill(fillColor)
                    .frame(width: geo.size.width * max(0, min(1, fraction)))
            }
        }
        .frame(height: 6)
    }
}

/// Multi-segment proportion bar (live / dead / unlabelled, cell-cycle phases).
struct AssaySegmentBar: View {
    /// Ordered segments; widths are the raw counts.
    let segments: [(count: Int, color: Color)]

    private var total: Int { segments.reduce(0) { $0 + $1.count } }

    var body: some View {
        GeometryReader { geo in
            HStack(spacing: 1) {
                ForEach(Array(segments.enumerated()), id: \.offset) { _, segment in
                    Rectangle()
                        .fill(segment.color)
                        .frame(width: total > 0
                               ? geo.size.width * CGFloat(segment.count) / CGFloat(total)
                               : 0)
                }
            }
            .clipShape(Capsule())
        }
        .frame(height: 6)
    }
}

/// Colour swatch + label + count + percentage, used by the class breakdowns.
struct AssayClassRow: View {
    let color: Color
    let label: String
    let count: Int
    let percent: Double
    var help: String? = nil

    var body: some View {
        HStack(spacing: 7) {
            RoundedRectangle(cornerRadius: 2)
                .fill(color)
                .frame(width: 9, height: 9)
            Text(label)
                .font(.system(size: 12.5))
                .foregroundStyle(Tokens.textSecondary)
            Spacer()
            Text("\(count)")
                .font(.system(size: 12.5, design: .monospaced))
                .foregroundStyle(Tokens.text)
            Text(String(format: "%.1f%%", percent))
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(Tokens.textTertiary)
                .frame(minWidth: 44, alignment: .trailing)
        }
        .padding(.vertical, 3)
        .help(help ?? "")
    }
}
