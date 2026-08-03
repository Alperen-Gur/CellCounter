import SwiftUI

// Assay 4 — live / dead viability.
//
// Mounted by `IntensityAssaysPanel`; see the splice instructions at the top of
// that file for where the container itself goes. Computed live in Swift from
// `DetectedCell.channelIntensities` — dragging a threshold reclassifies
// instantly with no Python round-trip.

/// Two-channel viability (calcein-AM / EthD-1, PI, …).
///
/// The classification convention is spelled out in the panel itself, because
/// papers differ on it: a dead-stain-positive cell is counted **dead** even if
/// it is also live-stain-positive, and cells negative in both are reported
/// separately as *unlabelled* rather than being silently folded into either
/// class. Both viability denominators are shown so the user can state which
/// one they quoted.
struct ViabilityAssayPanel: View {
    let cells: [DetectedCell]
    let channels: [AssayChannel]

    @State private var liveIndex: Int? = nil
    @State private var deadIndex: Int? = nil
    @State private var metric: AssayMetric = .mean
    @State private var mode: AssayThresholdMode = .otsu
    @State private var liveManual: Double? = nil
    @State private var deadManual: Double? = nil

    @Environment(AppTheme.self) private var theme

    private var liveChannel: AssayChannel {
        resolve(liveIndex, fallback: IntensityAssays.likelyMarkerChannel(in: channels))
    }

    private var deadChannel: AssayChannel {
        let preferred = channels.first { $0.index != liveChannel.index }
        return resolve(deadIndex, fallback: preferred)
    }

    private func resolve(_ index: Int?, fallback: AssayChannel?) -> AssayChannel {
        if let index, let match = channels.first(where: { $0.index == index }) {
            return match
        }
        // `body` reads liveChannel/deadChannel (via .onChange) even when the
        // panel renders only the "needs 2 channels" note, so this must not
        // subscript an empty array.
        return fallback ?? channels.first ?? AssayChannel(index: 0, name: nil)
    }

    private func values(_ channel: AssayChannel) -> [Double] {
        IntensityAssays.values(in: cells, channel: channel.index, metric: metric)
            .map(\.value)
    }

    private func seed(_ channel: AssayChannel) -> Double {
        let v = values(channel)
        if let otsu = IntensityAssays.otsuThreshold(v) { return otsu }
        guard let lo = v.min(), let hi = v.max() else { return 0 }
        return 0.5 * (lo + hi)
    }

    private var liveBinding: Binding<Double> {
        Binding(get: { liveManual ?? seed(liveChannel) }, set: { liveManual = $0 })
    }

    private var deadBinding: Binding<Double> {
        Binding(get: { deadManual ?? seed(deadChannel) }, set: { deadManual = $0 })
    }

    private var outcome: Result<ViabilityResult, AssayAvailability> {
        guard channels.count >= 2 else {
            return .failure(.needsChannels(have: channels.count, need: 2))
        }
        return IntensityAssays.viability(cells: cells,
                                         liveChannel: liveChannel,
                                         deadChannel: deadChannel,
                                         metric: metric,
                                         liveMode: mode,
                                         deadMode: mode,
                                         liveManual: liveBinding.wrappedValue,
                                         deadManual: deadBinding.wrappedValue)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            AssaySubsectionHeader(title: "Live / dead viability",
                                  subtitle: IntensityAssayKind.liveDead.subtitle)

            if channels.count < 2 {
                AssayUnavailableNote(
                    AssayAvailability.needsChannels(have: channels.count, need: 2).message)
            } else {
                AssayChannelMenu(label: "Live channel",
                                 channels: channels,
                                 selection: Binding(get: { liveChannel.index },
                                                    set: { liveIndex = $0 }))
                AssayChannelMenu(label: "Dead channel",
                                 channels: channels,
                                 selection: Binding(get: { deadChannel.index },
                                                    set: { deadIndex = $0 }))

                AssayFieldLabel("Threshold")
                SegmentedPicker(value: $mode,
                                options: AssayThresholdMode.allCases.map { ($0, $0.label) })
                if mode == .manual {
                    VStack(alignment: .leading, spacing: 8) {
                        AssayCaption("Live cut-off")
                        ManualThresholdSlider(value: liveBinding,
                                              values: values(liveChannel))
                        AssayCaption("Dead cut-off")
                        ManualThresholdSlider(value: deadBinding,
                                              values: values(deadChannel))
                    }
                }

                switch outcome {
                case .failure(let reason):
                    AssayUnavailableNote(reason.message)
                case .success(let result):
                    resultBody(result)
                }
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 16)
        .onChange(of: liveChannel.index) { liveManual = nil }
        .onChange(of: deadChannel.index) { deadManual = nil }
        .onChange(of: metric) { liveManual = nil; deadManual = nil }
    }

    @ViewBuilder
    private func resultBody(_ result: ViabilityResult) -> some View {
        VStack(spacing: 4) {
            AssayHeadlineRow(
                value: String(format: "%.1f", result.percentViable),
                unit: "%",
                caption: "viable — \(result.liveCount) live of "
                       + "\(result.liveCount + result.deadCount) labelled cells")

            AssaySegmentBar(segments: [
                (result.liveCount, Tokens.success),
                (result.deadCount, Tokens.danger),
                (result.unlabelledCount, Tokens.textQuaternary),
            ])
            .padding(.vertical, 2)

            AssayClassRow(color: Tokens.success, label: "Live",
                          count: result.liveCount,
                          percent: pct(result.liveCount, result.cellCount),
                          help: "Positive in the live channel, negative in the dead channel.")
            AssayClassRow(color: Tokens.danger, label: "Dead",
                          count: result.deadCount,
                          percent: pct(result.deadCount, result.cellCount),
                          help: "Positive in the dead channel, regardless of the live channel.")
            AssayClassRow(color: Tokens.textQuaternary, label: "Unlabelled",
                          count: result.unlabelledCount,
                          percent: pct(result.unlabelledCount, result.cellCount),
                          help: "Negative in both channels — excluded from the viability denominator.")

            Divider().overlay(Tokens.divider).padding(.vertical, 4)

            AssayStatRow(label: "Viable (live / labelled)",
                         value: String(format: "%.1f", result.percentViable),
                         unit: "%", emphasized: true)
            AssayStatRow(label: "Viable (live / all cells)",
                         value: String(format: "%.1f", result.percentViableOfAll),
                         unit: "%")
            AssayStatRow(label: "Live cut-off",
                         value: String(format: "%.4g", result.liveThreshold))
            AssayStatRow(label: "Dead cut-off",
                         value: String(format: "%.4g", result.deadThreshold))
            if result.doublePositiveCount > 0 {
                AssayStatRow(label: "Double-positive",
                             value: "\(result.doublePositiveCount)", unit: "cells")
            }

            AssayCaption(
                "Double-positive cells are counted dead — the membrane-impermeant "
                + "dead stain only enters compromised cells. Unlabelled cells are "
                + "excluded from the primary viability figure.")
        }
    }

    private func pct(_ n: Int, _ total: Int) -> Double {
        total > 0 ? 100.0 * Double(n) / Double(total) : 0
    }
}

// MARK: — Shared sub-panel header

/// Header for one assay inside the intensity-assay stack. Lighter than
/// `SectionHeader`, which is reserved for top-level sidebar sections.
struct AssaySubsectionHeader: View {
    let title: String
    var subtitle: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .font(.system(size: 12.5, weight: .semibold))
                .foregroundStyle(Tokens.text)
            if let subtitle {
                Text(subtitle)
                    .font(.system(size: 10.5))
                    .foregroundStyle(Tokens.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
