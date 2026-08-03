import SwiftUI

// MOUNTED BY `ResultsView.swift`'s `AdditionalAssaysSection`:
//
//       PunctaPanel(state: state, cells: cells, roiCount: roiCount)
//
//   The panel does NOT re-derive the cell list. It receives `ResultsSidebar`'s
//   already confidence- and ROI-filtered `cells` verbatim, so (a) a filtered-out
//   cell can't receive spots here while being hidden everywhere else, and
//   (b) the panel re-evaluates whenever that array changes — it no longer
//   depends on the untracked `state.repos.rois(for:)` SwiftData fetch, which
//   SwiftUI could skip observing.
//
//   It draws its OWN leading `Divider()`, inside the same branch that decides
//   whether to render at all. That is deliberate: separators supplied by the
//   caller would still be emitted when the panel hides itself, stacking two
//   adjacent rules into one thick band.
//
// APPLICABILITY: renders `EmptyView` unless the current image has at least
// one visible detected cell — mirroring `MeasurementsPanel`/`ColoniesPanel`'s
// skip-when-there-is-nothing-to-show convention, so the sidebar gains no
// empty box for users who never run this assay.
//
// Results live in local `@State` and are NOT persisted (no `Records.swift`
// slot owns them yet). They are tagged with an `AssayResultKey` — image id
// PLUS cell count, confidence cutoff and ROI count — and dropped the moment
// any of those move, so a result can never be read against a cell set it was
// not computed from. See `AssayResultKey`'s doc comment for the full rationale.

/// Puncta / foci-counting results panel — γH2AX DNA-damage foci, FISH spots,
/// stress granules, and friends. Shows user-settable detection params (spot
/// size range, threshold, focus-count threshold), runs `puncta_detect.py` via
/// `PunctaRunner`, then renders the per-cell / per-spot readout.
struct PunctaPanel: View {
    @Bindable var state: AppState
    /// `ResultsSidebar`'s already confidence- and ROI-filtered cells — see the
    /// header note. Passed in rather than re-derived so this panel and
    /// `TotalBlock` can never disagree about which cells exist.
    let cells: [DetectedCell]
    /// ROI count for the current image, part of the staleness fingerprint.
    let roiCount: Int

    @State private var params = PunctaParams()
    @State private var settingsExpanded = true
    @State private var showAllSpots = false

    @State private var isRunning = false
    @State private var result: PunctaResult? = nil
    /// Fingerprint of the inputs `result` was computed from — see the header
    /// note and `AssayResultKey`.
    @State private var resultKey: AssayResultKey? = nil
    @State private var errorMessage: String? = nil

    @Environment(AppTheme.self) private var theme

    // MARK: — Inputs

    /// Number of channels the current detection carries, or 1 when it's a
    /// plain single-plane image. Drives whether the channel picker appears.
    private var channelCount: Int {
        max(cells.first?.channelIntensities?.count ?? 1, 1)
    }

    /// Fingerprint of the cell set as it stands RIGHT NOW.
    private var currentKey: AssayResultKey {
        let image = state.currentImage
        return AssayResultKey(imageId: image?.id,
                              cellCount: cells.count,
                              cutoff: image.map { state.effectiveConfidence(for: $0) } ?? 0,
                              roiCount: roiCount)
    }

    /// Nil unless `result` was computed from exactly the cell set on screen
    /// right now — not merely from the same image.
    private var activeResult: PunctaResult? {
        guard let resultKey, resultKey == currentKey else { return nil }
        return result
    }

    var body: some View {
        // Skip entirely when there are no cells to assign spots to.
        if cells.isEmpty { return AnyView(EmptyView()) }
        return AnyView(content)
    }

    private var content: some View {
        VStack(spacing: 0) {
            // Drawn here, not by the caller — a caller-supplied divider would
            // survive the `cells.isEmpty` guard above and double up with the
            // next panel's.
            Divider().overlay(Tokens.divider)

            panelBody
        }
        // Belt and braces alongside `AssayResultKey`: re-detection, split,
        // merge and multi-select delete all post this, and a re-run that
        // happens to return the same cell count would otherwise slip past a
        // count-based fingerprint.
        .onReceive(NotificationCenter.default.publisher(for: .ccCorrectionsChanged)) { _ in
            result = nil
            resultKey = nil
        }
    }

    private var panelBody: some View {
        VStack(spacing: 0) {
            SectionHeader(title: "Puncta / Foci")

            settingsSection

            if let errorMessage {
                Text(errorMessage)
                    .font(.system(size: 11))
                    .foregroundStyle(Tokens.danger)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.top, 10)
            }

            if let activeResult {
                Divider().overlay(Tokens.divider).padding(.vertical, 12)
                resultsSection(activeResult)
            } else {
                emptyState
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 18)
    }

    // MARK: — Run

    private func run() {
        guard let image = state.currentImage else {
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
        let imageURL = image.storedURL
        // PIXELS PER MICROMETRE — forwarded to `--pxPerUm` verbatim. Never the
        // reciprocal `pixel_size_um`; see PunctaRunner's header note.
        let pxPerUm = state.pxPerUm
        let cellsSnapshot = cells
        let paramsSnapshot = params

        Task { @MainActor in
            defer { isRunning = false }
            do {
                let r = try await PunctaRunner.detect(imageURL: imageURL,
                                                      pxPerUm: pxPerUm,
                                                      cells: cellsSnapshot,
                                                      params: paramsSnapshot)
                result = r
                resultKey = startKey
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    // MARK: — Detection settings

    private var settingsSection: some View {
        VStack(spacing: 0) {
            Button {
                withAnimation(Tokens.Motion.easeFast) { settingsExpanded.toggle() }
            } label: {
                HStack {
                    HStack(spacing: 6) {
                        Icon(settingsExpanded ? "chevron" : "chevronr", size: 11)
                            .foregroundStyle(Tokens.textTertiary)
                        Text("Detection settings")
                            .font(.system(size: 12.5, weight: .medium))
                            .foregroundStyle(Tokens.text)
                    }
                    Spacer()
                    Text(params.method.label)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(Tokens.textTertiary)
                }
            }
            .buttonStyle(.plain)

            if settingsExpanded {
                VStack(spacing: 10) {
                    SegmentedPicker(value: $params.method,
                                   options: PunctaParams.Method.allCases.map { (value: $0, label: $0.label) })

                    // Only meaningful for a multi-channel acquisition — a spot
                    // assay is usually run on ONE fluorescence channel, and
                    // silently pinning it to channel 0 would quantify the
                    // wrong stain.
                    if channelCount > 1 {
                        stepperRow("Channel", value: $params.channelIndex, range: 0...(channelCount - 1))
                    }

                    sliderRow("Min spot size", value: $params.minDiameterUm, range: 0.1...5.0, unit: "µm")
                    sliderRow("Max spot size", value: $params.maxDiameterUm, range: 0.2...20.0, unit: "µm")
                    sliderRow("Threshold", value: $params.threshold, range: 0.0...1.0, unit: "")
                    stepperRow("Focus-count threshold", value: $params.focusCountThreshold, range: 1...50)

                    assignmentModeNote

                    Button {
                        run()
                    } label: {
                        HStack(spacing: 6) {
                            if isRunning {
                                AppSpinner()
                            } else {
                                Image(systemName: "circle.grid.3x3.fill")
                                    .font(.system(size: 11))
                            }
                            Text(isRunning ? "Detecting…"
                                           : (activeResult == nil ? "Detect spots" : "Re-detect spots"))
                        }
                        .frame(maxWidth: .infinity)
                    }
                    .appButton(.primary, size: .sm)
                    .disabled(isRunning)
                }
                .padding(.top, 10)
            }
        }
    }

    /// States which assignment mode the next run will use. `puncta_detect.py`
    /// takes the exact polygon path only when EVERY cell has a contour;
    /// otherwise it falls back to nearest-centroid, which is coarser. Saying
    /// so beats letting the user assume mask-accurate assignment.
    private var assignmentModeNote: some View {
        Text(PunctaRunner.usesPolygonAssignment(cells)
             ? "\(cells.count) cell(s) — spots assigned by cell outline (exact)."
             : "\(cells.count) cell(s) — some have no outline, so spots are assigned to the "
               + "nearest cell centre (approximate). Re-run detection with a model that "
               + "emits contours for exact assignment.")
            .font(.system(size: 10))
            .foregroundStyle(Tokens.textQuaternary)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func sliderRow(_ label: String, value: Binding<Double>,
                           range: ClosedRange<Double>, unit: String) -> some View {
        VStack(spacing: 3) {
            HStack {
                Text(label)
                    .font(.system(size: 11.5))
                    .foregroundStyle(Tokens.textSecondary)
                Spacer()
                Text(unit.isEmpty ? String(format: "%.2f", value.wrappedValue)
                                  : String(format: "%.2f %@", value.wrappedValue, unit))
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(Tokens.textTertiary)
            }
            Slider(value: value, in: range).tint(theme.accentColor)
        }
    }

    private func stepperRow(_ label: String, value: Binding<Int>, range: ClosedRange<Int>) -> some View {
        HStack {
            Text(label)
                .font(.system(size: 11.5))
                .foregroundStyle(Tokens.textSecondary)
            Spacer()
            Stepper(value: value, in: range) {
                Text("\(value.wrappedValue)")
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(Tokens.text)
                    .frame(minWidth: 24)
            }
            .fixedSize()
        }
    }

    // MARK: — Empty state

    private var emptyState: some View {
        RoundedRectangle(cornerRadius: Tokens.Radius.sm)
            .fill(Tokens.bgSunken)
            .frame(height: 64)
            .overlay(
                Text(isRunning ? "Detecting spots…" : "No spot detection run yet")
                    .font(.system(size: 11))
                    .foregroundStyle(Tokens.textTertiary)
            )
            .overlay(
                RoundedRectangle(cornerRadius: Tokens.Radius.sm)
                    .strokeBorder(Tokens.border, lineWidth: 0.5)
            )
            .padding(.top, 12)
    }

    // MARK: — Results

    @ViewBuilder
    private func resultsSection(_ result: PunctaResult) -> some View {
        let totalSpots = result.summary?.totalSpots ?? 0

        if totalSpots == 0 {
            Text(result.message ?? "No spots detected.")
                .font(.system(size: 11.5))
                .foregroundStyle(Tokens.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
        } else {
            VStack(spacing: 4) {
                if let s = result.summary {
                    PunctaStatRow(label: "Total spots", value: "\(s.totalSpots)", unit: "")
                    PunctaStatRow(label: "Cells with spot data", value: "\(s.nCells)", unit: "")
                    PunctaStatRow(label: "Mean spots / cell",
                                 value: s.meanSpotsPerCell.map { String(format: "%.2f", $0) } ?? "—",
                                 unit: "")
                    PunctaStatRow(label: "Median spots / cell",
                                 value: s.medianSpotsPerCell.map { String(format: "%.1f", $0) } ?? "—",
                                 unit: "")
                    PunctaStatRow(label: "\(Int(s.focusCountThreshold))+ spots/cell",
                                 value: s.pctCellsAboveThreshold.map { String(format: "%.0f", $0) } ?? "—",
                                 unit: s.pctCellsAboveThreshold != nil ? "%" : "")
                    if s.nUnassignedSpots > 0 {
                        PunctaStatRow(label: "Unassigned spots", value: "\(s.nUnassignedSpots)", unit: "")
                    }
                }
                if let message = result.message {
                    Text(message)
                        .font(.system(size: 10.5))
                        .foregroundStyle(Tokens.textTertiary)
                        .padding(.top, 4)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            if !result.cells.isEmpty {
                Divider().overlay(Tokens.divider).padding(.vertical, 10)
                perCellTable(result.cells)
            }

            if !result.spots.isEmpty {
                Divider().overlay(Tokens.divider).padding(.vertical, 10)
                spotList(result.spots)
            }
        }
    }

    private func perCellTable(_ cells: [PunctaCellCount]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Per-cell spot counts")
                .font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(Tokens.textSecondary)
            ScrollView {
                LazyVStack(spacing: 2) {
                    ForEach(cells.sorted(by: { $0.spotCount > $1.spotCount })) { c in
                        HStack {
                            Text(c.cellLabel)
                                .font(.system(size: 10.5, design: .monospaced))
                                .foregroundStyle(Tokens.textSecondary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                            Spacer()
                            Text("\(c.spotCount)")
                                .font(.system(size: 11.5, design: .monospaced))
                                .foregroundStyle(Tokens.text)
                        }
                        .padding(.vertical, 2)
                    }
                }
            }
            .frame(maxHeight: 140)
        }
    }

    private func spotList(_ spots: [PunctaSpot]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Per-spot detail")
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(Tokens.textSecondary)
                Spacer()
                Text("\(spots.count) spot\(spots.count == 1 ? "" : "s")")
                    .font(.system(size: 10.5, design: .monospaced))
                    .foregroundStyle(Tokens.textTertiary)
            }
            ScrollView {
                LazyVStack(spacing: 2) {
                    ForEach(showAllSpots ? spots : Array(spots.prefix(25))) { spot in
                        HStack {
                            Text(String(format: "%.2f µm", spot.diameterUm))
                                .font(.system(size: 10.5, design: .monospaced))
                                .foregroundStyle(Tokens.textSecondary)
                            Spacer()
                            Text(String(format: "I=%.0f", spot.meanIntensity))
                                .font(.system(size: 10.5, design: .monospaced))
                                .foregroundStyle(Tokens.textTertiary)
                        }
                        .padding(.vertical, 1.5)
                    }
                }
            }
            .frame(maxHeight: 140)
            if spots.count > 25 {
                Button(showAllSpots ? "Show fewer" : "Show all \(spots.count)") {
                    showAllSpots.toggle()
                }
                .buttonStyle(.plain)
                .font(.system(size: 11))
                .foregroundStyle(theme.accentColor)
            }
        }
    }
}

/// Two-column key/value row — matches `MeasRow`/`ColonyRow`'s established
/// style (kept private + independently named so this file has no symbol
/// collision with either, both of which are private to their own files).
private struct PunctaStatRow: View {
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
