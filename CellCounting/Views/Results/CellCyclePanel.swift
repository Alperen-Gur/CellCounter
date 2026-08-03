import SwiftUI

// Assay 6 — cell cycle from DNA content.
//
// Mounted by `IntensityAssaysPanel`. Computed live in Swift from
// `DetectedCell.channelIntensities` (integrated intensity in the DNA channel).
//
// HONESTY CONSTRAINT: this is a peak-and-gate heuristic, not a Watson
// pragmatic / Dean-Jett-Fox model fit. The panel says so on screen, in the
// header badge and in a caption directly under the numbers. Do not soften that
// wording, and do not add a "confidence" or "fit quality" figure — there is no
// fit to report the quality of.

/// G1 / S / G2-M **estimate** from the per-cell integrated DNA intensity.
struct CellCyclePanel: View {
    let cells: [DetectedCell]
    let channels: [AssayChannel]

    @State private var channelIndex: Int? = nil
    @State private var gateWidth: Double = 0.15

    @Environment(AppTheme.self) private var theme

    private var channel: AssayChannel {
        if let channelIndex, let match = channels.first(where: { $0.index == channelIndex }) {
            return match
        }
        return IntensityAssays.likelyDNAChannel(in: channels)
            ?? channels.first
            ?? AssayChannel(index: 0, name: nil)
    }

    private var outcome: Result<CellCycleResult, AssayAvailability> {
        IntensityAssays.cellCycle(cells: cells,
                                  channel: channel,
                                  gateWidth: gateWidth)
    }

    /// Ordered so the bar reads left-to-right in increasing DNA content.
    private let order: [CellCycleResult.Phase] = [.subG1, .g1, .s, .g2m, .aboveG2M]

    private func color(_ phase: CellCycleResult.Phase) -> Color {
        switch phase {
        case .subG1:    return Tokens.textQuaternary
        case .g1:       return Tokens.binColor(1)
        case .s:        return Tokens.binColor(3)
        case .g2m:      return Tokens.binColor(4)
        case .aboveG2M: return Tokens.warning
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top) {
                AssaySubsectionHeader(
                    title: "Cell cycle (DNA content)",
                    subtitle: IntensityAssayKind.cellCycle.subtitle)
                TagLabel(text: "Estimate", style: .licNc)
            }

            AssayChannelMenu(label: "DNA channel",
                             channels: channels,
                             selection: Binding(get: { channel.index },
                                                set: { channelIndex = $0 }))

            switch outcome {
            case .failure(let reason):
                AssayUnavailableNote(reason.message)
            case .success(let result):
                resultBody(result)
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 16)
    }

    @ViewBuilder
    private func resultBody(_ result: CellCycleResult) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            DNAContentHistogram(result: result,
                                g1Color: color(.g1),
                                g2Color: color(.g2m))

            AssaySegmentBar(segments: order.map {
                (result.counts[$0] ?? 0, color($0))
            })
            .padding(.top, 6)
            .padding(.bottom, 2)

            ForEach(order, id: \.self) { phase in
                let count = result.counts[phase] ?? 0
                if count > 0 || phase == .g1 || phase == .s || phase == .g2m {
                    AssayClassRow(color: color(phase),
                                  label: phase.rawValue,
                                  count: count,
                                  percent: result.percent(phase),
                                  help: phase.explanation)
                }
            }

            Divider().overlay(Tokens.divider).padding(.vertical, 4)

            AssayStatRow(label: "2n (G1) peak",
                         value: String(format: "%.4g", result.g1Peak), unit: "AU")
            AssayStatRow(label: "4n (G2/M) peak",
                         value: String(format: "%.4g", result.g2Peak), unit: "AU")
            AssayStatRow(label: "4n : 2n ratio",
                         value: String(format: "%.2f", result.g2OverG1),
                         unit: result.g2PeakFound ? "" : "assumed")
            AssayStatRow(label: "Cells gated", value: "\(result.cellCount)")

            AssayStepperRow(label: "Gate half-width",
                            value: Binding(get: { gateWidth * 100 },
                                           set: { gateWidth = $0 / 100 }),
                            range: 5...35, step: 2.5, format: "%.1f%%")

            if !result.g2PeakFound {
                AssayCaption(
                    "No second peak was found near twice the G1 position, so the "
                    + "4n gate was placed at exactly 2× G1. Phase fractions are "
                    + "correspondingly weaker.")
            }
            AssayCaption(CellCycleResult.caveat)
        }
    }
}

// MARK: — Histogram

/// Histogram of per-cell integrated DNA intensity, with the 2n and 4n peak
/// positions marked. Draws the same buckets the gating used, so what the user
/// sees is what was measured.
struct DNAContentHistogram: View {
    let result: CellCycleResult
    let g1Color: Color
    let g2Color: Color

    private let height: CGFloat = 64

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Canvas { ctx, size in
                ctx.fill(Path(CGRect(origin: .zero, size: size)),
                         with: .color(Tokens.bgSunken))
                let buckets = result.histogram
                guard !buckets.isEmpty, let peak = buckets.max(), peak > 0 else { return }

                let barW = size.width / CGFloat(buckets.count)
                for (i, count) in buckets.enumerated() {
                    guard count > 0 else { continue }
                    let h = CGFloat(count) / CGFloat(peak) * (size.height - 2)
                    let rect = CGRect(x: CGFloat(i) * barW,
                                      y: size.height - h,
                                      width: max(barW - 0.5, 1),
                                      height: h)
                    ctx.fill(Path(rect), with: .color(Tokens.text.opacity(0.55)))
                }

                // Peak markers.
                let lo = result.histogramRange.lowerBound
                let hi = result.histogramRange.upperBound
                guard hi > lo else { return }
                for (value, color) in [(result.g1Peak, g1Color), (result.g2Peak, g2Color)] {
                    let x = CGFloat((value - lo) / (hi - lo)) * size.width
                    guard x >= 0, x <= size.width else { continue }
                    var path = Path()
                    path.move(to: CGPoint(x: x, y: 0))
                    path.addLine(to: CGPoint(x: x, y: size.height))
                    ctx.stroke(path, with: .color(color),
                               style: StrokeStyle(lineWidth: 1.5, dash: [3, 2]))
                }
            }
            .frame(maxWidth: .infinity)
            .frame(height: height)
            .cornerRadius(Tokens.Radius.sm)
            .overlay(RoundedRectangle(cornerRadius: Tokens.Radius.sm)
                .strokeBorder(Tokens.border, lineWidth: 0.5))

            HStack(spacing: 10) {
                HStack(spacing: 4) {
                    Rectangle().fill(g1Color).frame(width: 8, height: 1.5)
                    Text("2n").font(.system(size: 9.5, design: .monospaced))
                }
                HStack(spacing: 4) {
                    Rectangle().fill(g2Color).frame(width: 8, height: 1.5)
                    Text("4n").font(.system(size: 9.5, design: .monospaced))
                }
                Spacer()
                Text("integrated DNA intensity →")
                    .font(.system(size: 9.5))
            }
            .foregroundStyle(Tokens.textTertiary)
        }
    }
}
