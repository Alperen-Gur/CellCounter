import SwiftUI

// MOUNTED BY `ResultsView.swift`'s `AdditionalAssaysSection`:
//
//       NeuritePanel(state: state, cells: cells, roiCount: roiCount)
//
//   The panel does NOT re-derive the cell list. It receives `ResultsSidebar`'s
//   already confidence- and ROI-filtered `cells` verbatim (they become the
//   somas), so it re-evaluates whenever that array changes rather than
//   depending on the untracked `state.repos.rois(for:)` SwiftData fetch.
//
//   It draws its OWN leading `Divider()`, inside the same branch that decides
//   whether to render at all. A caller-supplied separator would still be
//   emitted when the panel hides itself and double up with its neighbour's —
//   which is exactly what used to happen for every detection returning no
//   cells.
//
// APPLICABILITY: renders `EmptyView` unless the current image has at least
// one visible detected cell to use as a soma — mirroring `MeasurementsPanel`/
// `ColoniesPanel`'s skip-when-there-is-nothing-to-show convention, so the
// sidebar gains no empty box for users who never run this assay.
//
// INPUT: `neurite_outgrowth.py` wants a MASK — every nonzero pixel counts as
// neurite. The panel defaults that to the current image (a fair
// approximation for a dark-background fluorescence stain, and the "current
// image" the integrator asked for) but lets the user point at a real
// segmented mask instead, and says so in the UI, because a light-background
// brightfield frame would come out almost entirely "foreground" and produce
// meaningless lengths. Somas come from the image's own detected cells, sent
// as `--soma-centroids`.
//
// Results live in local `@State`, are NOT persisted, and are tagged with an
// `AssayResultKey` — image id PLUS cell count, confidence cutoff and ROI count
// — so a per-soma length table can never be read against a soma set it was not
// computed from. See `AssayResultKey`'s doc comment for the full rationale.

/// Neurite outgrowth results for one image. Runs `neurite_outgrowth.py` via
/// `NeuriteRunner`.
///
/// The overlapping-neurite limitation (`NeuriteOverlapCaveat` below) is shown
/// UNCONDITIONALLY on every result, per the feature spec: "Be honest about
/// limitations... surface it as a caveat in the UI panel." It is not
/// something the user can miss by not noticing a badge — it sits directly
/// under the section header, ABOVE the numbers, on every single run. The text
/// comes straight from `_neurite.py`'s `_CAVEAT` constant via the JSON
/// `caveat` field, so the Python and Swift sides can never say two different
/// things about the same limitation.
struct NeuritePanel: View {
    @Bindable var state: AppState
    /// `ResultsSidebar`'s already confidence- and ROI-filtered cells — these
    /// become the somas. See the header note.
    let cells: [DetectedCell]
    /// ROI count for the current image, part of the staleness fingerprint.
    let roiCount: Int

    /// Cap on how many individual per-cell rows are listed inline — same
    /// rationale as `TrackingPanel.maxListedTracks`.
    private static let maxListedCells = 8

    private static let maskFileTypes = ["png", "tif", "tiff", "bmp", "jpg", "jpeg"]

    /// User-supplied neurite mask. Nil = use the current image itself.
    @State private var maskOverrideURL: URL? = nil
    @State private var somaRadiusUm: Double = 8.0

    @State private var isRunning = false
    @State private var result: NeuritePayload? = nil
    /// Fingerprint of the inputs `result` was computed from — see the header
    /// note and `AssayResultKey`.
    @State private var resultKey: AssayResultKey? = nil
    @State private var errorMessage: String? = nil

    @Environment(AppTheme.self) private var theme

    // MARK: — Inputs

    private var effectiveMaskURL: URL? {
        maskOverrideURL ?? state.currentImage?.storedURL
    }

    /// Fingerprint of the soma set as it stands RIGHT NOW.
    private var currentKey: AssayResultKey {
        let image = state.currentImage
        return AssayResultKey(imageId: image?.id,
                              cellCount: cells.count,
                              cutoff: image.map { state.effectiveConfidence(for: $0) } ?? 0,
                              roiCount: roiCount)
    }

    /// Nil unless `result` was computed from exactly the soma set on screen
    /// right now — not merely from the same image.
    private var activeResult: NeuritePayload? {
        guard let resultKey, resultKey == currentKey else { return nil }
        return result
    }

    private var sortedCells: [NeuriteCellStat] {
        (activeResult?.cells ?? []).sorted { $0.total_length_um > $1.total_length_um }
    }

    var body: some View {
        // Skip entirely when there are no cell bodies to attribute neurites to.
        if cells.isEmpty { return AnyView(EmptyView()) }
        return AnyView(content)
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Drawn here, not by the caller — see the header note.
            Divider().overlay(Tokens.divider)

            panelBody
        }
        // Belt and braces alongside `AssayResultKey` — re-detect / split /
        // merge / delete all post this.
        .onReceive(NotificationCenter.default.publisher(for: .ccCorrectionsChanged)) { _ in
            result = nil
            resultKey = nil
        }
    }

    private var panelBody: some View {
        VStack(alignment: .leading, spacing: 0) {
            SectionHeader(title: "Neurite outgrowth")

            settingsSection

            if let errorMessage {
                Text(errorMessage)
                    .font(.system(size: 11))
                    .foregroundStyle(Tokens.danger)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 10)
            }

            if let activeResult {
                resultsSection(activeResult)
                    .padding(.top, 12)
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 18)
    }

    // MARK: — Run

    private func run() {
        guard let maskURL = effectiveMaskURL else {
            errorMessage = "Open an image first."
            return
        }
        errorMessage = nil
        result = nil
        resultKey = nil
        isRunning = true

        // Captured BEFORE the run so a cell edit that lands while the sidecar
        // is working invalidates the result instead of being stamped onto it.
        let startKey = currentKey
        // PIXELS PER MICROMETRE — forwarded to `--px-per-um` verbatim. Never
        // the reciprocal `pixel_size_um`; see NeuriteRunner's header note.
        let pxPerUm = state.pxPerUm
        let somas = cells
        let radius = somaRadiusUm

        Task { @MainActor in
            defer { isRunning = false }
            do {
                let r = try await NeuriteRunner.analyze(neuriteMaskURL: maskURL,
                                                        pxPerUm: pxPerUm,
                                                        somas: somas,
                                                        somaRadiusUm: radius)
                result = r
                resultKey = startKey
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    // MARK: — Settings

    private var settingsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Skeletonizes a neurite mask, removes each cell body, and attributes the "
                 + "remaining branches to the nearest soma.")
                .font(.system(size: 11))
                .foregroundStyle(Tokens.textTertiary)
                .fixedSize(horizontal: false, vertical: true)

            maskSourceRow

            VStack(spacing: 3) {
                HStack {
                    Text("Soma radius")
                        .font(.system(size: 11.5))
                        .foregroundStyle(Tokens.textSecondary)
                    Spacer()
                    Text(String(format: "%.0f µm", somaRadiusUm))
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(Tokens.textTertiary)
                }
                Slider(value: $somaRadiusUm, in: 2...40).tint(theme.accentColor)
                Text("Cell bodies are modelled as discs of this radius — CellCounter stores "
                     + "centroids, not a labelled soma raster.")
                    .font(.system(size: 10))
                    .foregroundStyle(Tokens.textQuaternary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Text("\(cells.count) cell(s) from the current image will be used as somas.")
                .font(.system(size: 10))
                .foregroundStyle(Tokens.textQuaternary)

            Button {
                run()
            } label: {
                HStack(spacing: 6) {
                    if isRunning {
                        AppSpinner()
                    } else {
                        Icon("play", size: 11)
                    }
                    Text(isRunning ? "Measuring…" : (activeResult == nil ? "Measure neurites" : "Re-measure"))
                }
                .frame(maxWidth: .infinity)
            }
            .appButton(.primary, size: .sm)
            .disabled(isRunning || effectiveMaskURL == nil)
        }
    }

    /// Which file is being skeletonized, plus the honest note about what that
    /// input actually needs to be.
    private var maskSourceRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Button {
                    presentOpenPanel(allowedExtensions: Self.maskFileTypes,
                                     allowFolders: false, allowMultiple: false) { urls in
                        if let first = urls.first {
                            maskOverrideURL = first
                            result = nil
                            resultKey = nil
                            errorMessage = nil
                        }
                    }
                } label: {
                    HStack(spacing: 6) {
                        Icon("folderup", size: 12)
                        Text("Choose mask…")
                    }
                }
                .appButton(.standard, size: .sm)

                Text(maskOverrideURL?.lastPathComponent ?? "Current image")
                    .font(.system(size: 11))
                    .foregroundStyle(maskOverrideURL == nil ? Tokens.textTertiary : Tokens.textSecondary)
                    .lineLimit(1)
                    .truncationMode(.middle)

                if maskOverrideURL != nil {
                    Button("Reset") {
                        maskOverrideURL = nil
                        result = nil
                        resultKey = nil
                        errorMessage = nil
                    }
                    .buttonStyle(.plain)
                    .font(.system(size: 10.5))
                    .foregroundStyle(theme.accentColor)
                }
            }

            if maskOverrideURL == nil {
                Text("Every nonzero pixel counts as neurite, so the current image works only "
                     + "for a dark-background fluorescence stain. For brightfield, or for "
                     + "publication numbers, choose a segmented mask instead.")
                    .font(.system(size: 10))
                    .foregroundStyle(Tokens.textQuaternary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: — Results

    @ViewBuilder
    private func resultsSection(_ result: NeuritePayload) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            // UNCONDITIONAL — see this struct's doc comment. Above the numbers,
            // on every result, never behind a disclosure or a toggle.
            NeuriteOverlapCaveat(text: result.caveat)
                .padding(.bottom, 12)

            if let message = result.message {
                NeuriteInfoNote(text: message)
                    .padding(.bottom, result.cells.isEmpty ? 0 : 12)
            }

            VStack(spacing: 4) {
                if !result.cells.isEmpty {
                    NeuriteStatRow(label: "Cells with neurites", value: "\(result.n_cells)", unit: "")
                    NeuriteStatRow(label: "Mean neurite length",
                                   value: String(format: "%.1f", result.mean_neurite_length_um),
                                   unit: "µm")
                }
                NeuriteStatRow(label: "Total skeleton length",
                               value: String(format: "%.1f", result.total_skeleton_length_um),
                               unit: "µm")
                if result.unattributed_length_um > 0 {
                    NeuriteStatRow(label: "Unattributed length",
                                   value: String(format: "%.1f", result.unattributed_length_um),
                                   unit: "µm")
                }
            }
            .padding(.bottom, result.cells.isEmpty ? 0 : 12)

            if !result.cells.isEmpty {
                VStack(spacing: 0) {
                    ForEach(Array(sortedCells.prefix(Self.maxListedCells).enumerated()), id: \.element.id) { i, cell in
                        if i > 0 { Divider().overlay(Tokens.divider.opacity(0.6)) }
                        NeuriteCellRow(cell: cell)
                    }
                }

                if result.cells.count > Self.maxListedCells {
                    Text("+ \(result.cells.count - Self.maxListedCells) more cell(s) — showing the \(Self.maxListedCells) longest")
                        .font(.system(size: 10.5))
                        .foregroundStyle(Tokens.textTertiary)
                        .padding(.top, 8)
                }
            }
        }
    }
}

// MARK: — Summary row (matches ColonyRow / MeasRow / TrackStatRow styling)

private struct NeuriteStatRow: View {
    let label: String
    let value: String
    let unit: String

    var body: some View {
        HStack {
            Text(label)
                .font(.system(size: 12.5))
                .foregroundStyle(Tokens.textSecondary)
            Spacer()
            HStack(spacing: 3) {
                Text(value)
                    .font(.system(size: 12.5, design: .monospaced))
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

// MARK: — Per-cell row

private struct NeuriteCellRow: View {
    let cell: NeuriteCellStat

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .firstTextBaseline) {
                Text("Cell \(cell.soma_id)")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Tokens.text)
                Spacer()
                Text(String(format: "%.1f µm", cell.total_length_um))
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(Tokens.text)
            }
            HStack(spacing: 12) {
                cellDetail("primary processes", "\(cell.n_primary_processes)")
                cellDetail("branch points", "\(cell.n_branch_points)")
            }
        }
        .padding(.vertical, 6)
    }

    private func cellDetail(_ label: String, _ value: String) -> some View {
        HStack(spacing: 3) {
            Text(value)
                .font(.system(size: 10.5, weight: .medium, design: .monospaced))
                .foregroundStyle(Tokens.textSecondary)
            Text(label)
                .font(.system(size: 10))
                .foregroundStyle(Tokens.textTertiary)
        }
    }
}

// MARK: — Info note (neutral — e.g. "no soma provided")
//
// Deliberately separate from `NeuriteOverlapCaveat` below: this note is
// about a specific run's input (missing soma data — an expected, benign
// state the user can fix by supplying soma positions), not a standing
// limitation of the algorithm itself.

private struct NeuriteInfoNote: View {
    let text: String

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Icon("info", size: 12)
                .foregroundStyle(Tokens.textTertiary)
                .padding(.top, 1)
            Text(text)
                .font(.system(size: 11.5))
                .foregroundStyle(Tokens.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(
            RoundedRectangle(cornerRadius: Tokens.Radius.md, style: .continuous)
                .fill(Tokens.bgSunken))
        .overlay(
            RoundedRectangle(cornerRadius: Tokens.Radius.md, style: .continuous)
                .strokeBorder(Tokens.border, lineWidth: 0.5))
    }
}

// MARK: — Overlap/limitation caveat
//
// Same warning-tinted visual language as `PseudoreplicationCaveat` in
// `Views/Compare/CompareView.swift` — this codebase's established pattern
// for a standing, honest, always-visible scientific-validity caveat (see
// that file's comment: "Researcher feedback... asked for a visible, honest
// caveat"). Shown UNCONDITIONALLY whenever `NeuritePanel` has a result — see
// that struct's doc comment for why. Text comes straight from `_neurite.py`'s
// `_CAVEAT` constant via the JSON `caveat` field, so the Python and Swift
// sides can never say two different things about the same limitation.

private struct NeuriteOverlapCaveat: View {
    let text: String

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Icon("info", size: 12)
                .foregroundStyle(Tokens.warning)
                .padding(.top, 1)
            Text(text)
                .font(.system(size: 11.5))
                .foregroundStyle(Tokens.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(
            RoundedRectangle(cornerRadius: Tokens.Radius.md, style: .continuous)
                .fill(Tokens.warning.opacity(0.10)))
        .overlay(
            RoundedRectangle(cornerRadius: Tokens.Radius.md, style: .continuous)
                .strokeBorder(Tokens.warning.opacity(0.28), lineWidth: 0.5))
    }
}
