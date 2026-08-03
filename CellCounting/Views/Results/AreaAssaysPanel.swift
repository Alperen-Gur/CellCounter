import SwiftUI

// MOUNTED BY `ResultsView.swift`'s `AdditionalAssaysSection`:
//
//       AreaAssaysPanel(state: state)
//
//   It draws its own leading `Divider()` so it matches its neighbours in that
//   group, every one of which owns its separator (they hide themselves, and a
//   caller-drawn rule would survive the hide).
//
// Unlike the passive readout panels next to it (Colonies, Measurements),
// this one is an interactive tool: the user picks an image/mask file (or
// several, for a wound-healing time series) and taps Run. It does NOT read
// `state.currentImage?.detection` — confluence/scratch-wound/spheroid work
// off a plain image or an externally-supplied mask file, independent of
// whatever detector produced `state.currentImage`'s cells (see
// `CellCounting/python/_assays_area.py`'s module docstring). `state` is
// used only for convenience defaults (`state.pxPerUm`) and is never
// mutated — results live in local `@State` and are NOT persisted to the
// SwiftData store (no `Records.swift`/`AppState.swift` change owns a slot
// for them yet).
//
// RESULT LIFETIME — corrected. An earlier draft of this note claimed
// "switching images or panels clears them". It does not, and it deliberately
// must not: a result here belongs to the FILE the user picked in this panel,
// not to `state.currentImage`, so paging the batch strip has no bearing on
// whether it is still valid. (Contrast the per-cell assays — Puncta, Spatial,
// Neurite — whose inputs ARE the current image's cells and which therefore
// invalidate on an `AssayResultKey` mismatch.) Results here live until the
// user picks a different file, re-runs, or leaves the Results view.

/// Confluence, scratch/wound-healing, and spheroid/organoid area assays —
/// see each sub-view's doc comment for what it measures.
struct AreaAssaysPanel: View {
    @Bindable var state: AppState

    private enum Mode: Hashable { case confluence, scratchWound, spheroid }
    @State private var mode: Mode = .confluence

    var body: some View {
        VStack(spacing: 0) {
            // Own leading divider — see the header note.
            Divider().overlay(Tokens.divider)

            VStack(spacing: 0) {
                SectionHeader(title: "Area Assays")

                SegmentedPicker(value: $mode, options: [
                    (value: Mode.confluence, label: "Confluence"),
                    (value: Mode.scratchWound, label: "Wound"),
                    (value: Mode.spheroid, label: "Spheroid"),
                ])
                .padding(.bottom, 14)

                Group {
                    switch mode {
                    case .confluence:   ConfluenceAssayView(state: state)
                    case .scratchWound: ScratchWoundAssayView(state: state)
                    case .spheroid:     SpheroidAssayView(state: state)
                    }
                }
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 18)
        }
    }
}

// MARK: — Shared bits

private enum AreaAssayFileTypes {
    static let image = ["png", "jpg", "jpeg", "tif", "tiff", "bmp"]
    static let mask  = ["png", "tif", "tiff", "bmp"]
}

/// Parses a comma-separated list of numbers ("0, 6, 12, 24"). Returns nil
/// if the string is empty OR any entry fails to parse — callers treat a nil
/// result as "don't guess; either omit the timepoints or ask the user to
/// fix the text" rather than silently dropping bad entries.
private func parseTimepointsText(_ text: String) -> [Double]? {
    let trimmed = text.trimmingCharacters(in: .whitespaces)
    guard !trimmed.isEmpty else { return nil }
    let parts = trimmed.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
    let values = parts.compactMap { Double($0) }
    return values.count == parts.count && !values.isEmpty ? values : nil
}

/// Single-file picker button + the currently-picked filename.
private struct FilePickerRow: View {
    let label: String
    let pickedURL: URL?
    let allowedExtensions: [String]
    let onPick: (URL) -> Void

    var body: some View {
        HStack(spacing: 8) {
            Button {
                presentOpenPanel(allowedExtensions: allowedExtensions,
                                 allowFolders: false, allowMultiple: false) { urls in
                    if let first = urls.first { onPick(first) }
                }
            } label: {
                HStack(spacing: 6) {
                    Icon("folderup", size: 12)
                    Text(label)
                }
            }
            .appButton(.standard, size: .sm)

            Text(pickedURL?.lastPathComponent ?? "No file selected")
                .font(.system(size: 11))
                .foregroundStyle(pickedURL == nil ? Tokens.textTertiary : Tokens.textSecondary)
                .lineLimit(1)
                .truncationMode(.middle)
        }
    }
}

/// Multi-file picker for the scratch-wound time series — one image is
/// "single frame", 2+ is "series". Selections are sorted by filename (the
/// only ordering NSOpenPanel doesn't already guarantee is meaningful) so a
/// t0_/t1_/t2_-style naming convention produces the right chronological order.
private struct MultiFilePickerRow: View {
    let pickedURLs: [URL]
    let onPick: ([URL]) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Button {
                    presentOpenPanel(allowedExtensions: AreaAssayFileTypes.image,
                                     allowFolders: false, allowMultiple: true) { urls in
                        onPick(urls.sorted { $0.lastPathComponent < $1.lastPathComponent })
                    }
                } label: {
                    HStack(spacing: 6) {
                        Icon("folderup", size: 12)
                        Text("Choose frame(s)…")
                    }
                }
                .appButton(.standard, size: .sm)

                Text(pickedURLs.isEmpty ? "No frames selected" : "\(pickedURLs.count) frame(s)")
                    .font(.system(size: 11))
                    .foregroundStyle(pickedURLs.isEmpty ? Tokens.textTertiary : Tokens.textSecondary)
            }

            if pickedURLs.count > 1 {
                Text("Ordered by filename, oldest first — rename with a sortable prefix "
                     + "(t0_, t1_, t2_, …) if this isn't the right time order.")
                    .font(.system(size: 10))
                    .foregroundStyle(Tokens.textQuaternary)
                    .fixedSize(horizontal: false, vertical: true)

                VStack(alignment: .leading, spacing: 2) {
                    ForEach(Array(pickedURLs.enumerated()), id: \.offset) { i, url in
                        Text("\(i). \(url.lastPathComponent)")
                            .font(.system(size: 10.5, design: .monospaced))
                            .foregroundStyle(Tokens.textTertiary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }
            }
        }
    }
}

private struct RunButton: View {
    let title: String
    let isRunning: Bool
    let disabled: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                if isRunning {
                    AppSpinner()
                } else {
                    Icon("play", size: 11)
                }
                Text(isRunning ? "Running…" : title)
            }
            .frame(maxWidth: .infinity)
        }
        .appButton(.primary, size: .sm)
        .disabled(disabled || isRunning)
    }
}

/// Standard key/value row — mirrors `MeasurementsPanel`'s private `MeasRow`
/// / `ColoniesPanel`'s private `ColonyRow` (each file keeps its own copy
/// since both are `private` to their declaring file).
private struct AssayRow: View {
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
        .padding(.vertical, 3)
    }
}

/// Same shape as `AssayRow` but larger/bolder — the headline metric each
/// assay leads with (coverage %, gap area, object count).
private struct AssayHeroRow: View {
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
                    .font(.system(size: 15, weight: .semibold, design: .monospaced))
                    .foregroundStyle(Tokens.text)
                if !unit.isEmpty {
                    Text(unit)
                        .font(.system(size: 12))
                        .foregroundStyle(Tokens.textTertiary)
                }
            }
        }
        .padding(.vertical, 4)
    }
}

private struct ErrorText: View {
    let message: String
    var body: some View {
        Text(message)
            .font(.system(size: 11))
            .foregroundStyle(Tokens.danger)
            .fixedSize(horizontal: false, vertical: true)
    }
}

// MARK: — 1) Confluence

/// % of the field covered by cells — computed either from an existing
/// segmentation mask file (`_assays_area.confluence(mask:)`) or, mask-free,
/// by intensity-thresholding a raw image directly
/// (`_assays_area.confluence(image:)`). The most-used readout after
/// counting; see `AreaAssaysRunner.confluenceMask`/`confluenceThreshold`.
private struct ConfluenceAssayView: View {
    @Bindable var state: AppState

    private enum Source: Hashable { case thresholdImage, maskFile }
    @State private var source: Source = .thresholdImage
    @State private var pickedURL: URL? = nil
    @State private var invert = false
    @State private var isRunning = false
    @State private var result: ConfluenceResult? = nil
    @State private var errorMessage: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("% of the field covered by cells — the most-used readout after counting.")
                .font(.system(size: 11))
                .foregroundStyle(Tokens.textTertiary)
                .fixedSize(horizontal: false, vertical: true)

            SegmentedPicker(value: $source, options: [
                (value: Source.thresholdImage, label: "From image"),
                (value: Source.maskFile, label: "From mask"),
            ])
            .onChange(of: source) { _, _ in
                pickedURL = nil; result = nil; errorMessage = nil
            }

            FilePickerRow(
                label: source == .thresholdImage ? "Choose image…" : "Choose mask…",
                pickedURL: pickedURL,
                allowedExtensions: source == .thresholdImage ? AreaAssayFileTypes.image : AreaAssayFileTypes.mask
            ) { url in
                pickedURL = url; result = nil; errorMessage = nil
            }

            if source == .thresholdImage {
                HStack(spacing: 8) {
                    CustomToggle(isOn: $invert)
                    Text("Dark cells on a light field")
                        .font(.system(size: 11.5))
                        .foregroundStyle(Tokens.textSecondary)
                }
            }

            RunButton(title: "Run", isRunning: isRunning, disabled: pickedURL == nil) { run() }

            if let errorMessage { ErrorText(message: errorMessage) }
            if let result { resultView(result) }
        }
    }

    private func run() {
        guard let pickedURL else { return }
        errorMessage = nil
        result = nil
        isRunning = true
        let pxPerUm = state.pxPerUm
        let src = source
        let invertFlag = invert
        Task { @MainActor in
            defer { isRunning = false }
            do {
                if src == .maskFile {
                    result = try await AreaAssaysRunner.confluenceMask(maskURL: pickedURL, pxPerUm: pxPerUm)
                } else {
                    result = try await AreaAssaysRunner.confluenceThreshold(
                        imageURL: pickedURL, pxPerUm: pxPerUm, invert: invertFlag)
                }
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    @ViewBuilder
    private func resultView(_ r: ConfluenceResult) -> some View {
        VStack(spacing: 0) {
            AssayHeroRow(label: "Coverage", value: String(format: "%.1f", r.coverage_pct), unit: "%")
            AssayRow(label: "Covered area", value: String(format: "%.0f", r.covered_area_um2), unit: "µm²")
            AssayRow(label: "Uncovered area", value: String(format: "%.0f", r.uncovered_area_um2), unit: "µm²")
            AssayRow(label: "Total field area", value: String(format: "%.0f", r.total_area_um2), unit: "µm²")
            if let tv = r.threshold_value {
                AssayRow(label: "Threshold (\(r.threshold_method))", value: String(format: "%.0f", tv), unit: "")
            }
            if !r.ok || !r.message.isEmpty {
                Text(r.message)
                    .font(.system(size: 10.5))
                    .foregroundStyle(Tokens.warning)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 4)
            }
        }
    }
}

// MARK: — 2) Scratch / wound-healing

/// Cell-free "wound" gap area — one image for a single reading, or several
/// (in chronological order) for a per-timepoint closure table, % closure
/// relative to t=0, and a closure rate. THE classic keratinocyte migration
/// assay. See `_assays_area.scratch_wound` / `scratch_wound_series`.
private struct ScratchWoundAssayView: View {
    @Bindable var state: AppState

    @State private var pickedURLs: [URL] = []
    @State private var timepointsText: String = ""
    @State private var isRunning = false
    @State private var singleResult: ScratchWoundFrameResult? = nil
    @State private var seriesResult: ScratchWoundSeriesResult? = nil
    @State private var errorMessage: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Cell-free gap area over time. Pick one image for a single reading, "
                 + "or several (oldest first) for a closure table.")
                .font(.system(size: 11))
                .foregroundStyle(Tokens.textTertiary)
                .fixedSize(horizontal: false, vertical: true)

            MultiFilePickerRow(pickedURLs: pickedURLs) { urls in
                pickedURLs = urls
                singleResult = nil; seriesResult = nil; errorMessage = nil
            }

            if pickedURLs.count > 1 {
                timepointsField
            }

            RunButton(title: "Run", isRunning: isRunning, disabled: pickedURLs.isEmpty) { run() }

            if let errorMessage { ErrorText(message: errorMessage) }
            if let singleResult { singleResultView(singleResult) }
            if let seriesResult { seriesResultView(seriesResult) }
        }
    }

    private var timepointsField: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Timepoints, in hours (comma-separated, optional)")
                .font(.system(size: 10.5))
                .foregroundStyle(Tokens.textTertiary)
            TextField("e.g. 0, 6, 12, 24", text: $timepointsText)
                .font(.system(size: 11.5, design: .monospaced))
                .textFieldStyle(.plain)
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
                .background(RoundedRectangle(cornerRadius: Tokens.Radius.sm, style: .continuous)
                    .fill(Tokens.bgSunken))
                .overlay(RoundedRectangle(cornerRadius: Tokens.Radius.sm, style: .continuous)
                    .strokeBorder(Tokens.border, lineWidth: 0.5))
            if !timepointsText.trimmingCharacters(in: .whitespaces).isEmpty,
               parseTimepointsText(timepointsText) == nil {
                Text("Couldn't parse — expected \(pickedURLs.count) comma-separated numbers.")
                    .font(.system(size: 10))
                    .foregroundStyle(Tokens.warning)
            }
        }
    }

    private func run() {
        let urls = pickedURLs
        guard !urls.isEmpty else { return }
        errorMessage = nil
        singleResult = nil
        seriesResult = nil

        var tps: [Double]? = nil
        let trimmed = timepointsText.trimmingCharacters(in: .whitespaces)
        if !trimmed.isEmpty {
            guard let parsed = parseTimepointsText(trimmed), parsed.count == urls.count else {
                errorMessage = "Timepoints must be \(urls.count) comma-separated number(s) "
                    + "(one per image), or left blank."
                return
            }
            tps = parsed
        }

        isRunning = true
        let pxPerUm = state.pxPerUm
        Task { @MainActor in
            defer { isRunning = false }
            do {
                if urls.count == 1 {
                    singleResult = try await AreaAssaysRunner.scratchWoundSingle(
                        imageURL: urls[0], pxPerUm: pxPerUm)
                } else {
                    seriesResult = try await AreaAssaysRunner.scratchWoundSeries(
                        imageURLs: urls, pxPerUm: pxPerUm, timepointsHours: tps)
                }
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    @ViewBuilder
    private func singleResultView(_ r: ScratchWoundFrameResult) -> some View {
        VStack(spacing: 0) {
            AssayHeroRow(label: "Gap area", value: String(format: "%.0f", r.gap_area_um2), unit: "µm²")
            AssayRow(label: "Gap fraction", value: String(format: "%.1f", r.gap_fraction_pct), unit: "%")
            AssayRow(label: "Total field area", value: String(format: "%.0f", r.total_area_um2), unit: "µm²")
            if !r.message.isEmpty {
                Text(r.message)
                    .font(.system(size: 10.5))
                    .foregroundStyle(Tokens.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 4)
            }
        }
    }

    @ViewBuilder
    private func seriesResultView(_ r: ScratchWoundSeriesResult) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(spacing: 0) {
                AssayHeroRow(label: "Total closure", value: String(format: "%.1f", r.total_pct_closure), unit: "%")
                AssayRow(label: "Initial gap", value: String(format: "%.0f", r.initial_gap_area_um2), unit: "µm²")
                AssayRow(label: "Final gap", value: String(format: "%.0f", r.final_gap_area_um2), unit: "µm²")
                if let rate = r.closure_rate_um2_per_hr {
                    AssayRow(label: "Closure rate", value: String(format: "%.1f", rate), unit: "µm²/hr")
                }
            }
            timepointsTable(r.timepoints)
        }
    }

    @ViewBuilder
    private func timepointsTable(_ rows: [ScratchWoundTimepoint]) -> some View {
        VStack(spacing: 0) {
            HStack {
                Text("Frame").frame(width: 44, alignment: .leading)
                Text("Gap area").frame(maxWidth: .infinity, alignment: .trailing)
                Text("Closure").frame(width: 56, alignment: .trailing)
            }
            .font(.system(size: 10, weight: .medium))
            .foregroundStyle(Tokens.textTertiary)
            .padding(.bottom, 3)

            Divider().overlay(Tokens.divider)

            ForEach(rows) { row in
                HStack {
                    Text(row.time_hours.map { String(format: "%.0fh", $0) } ?? "#\(row.frame)")
                        .frame(width: 44, alignment: .leading)
                    Text(String(format: "%.0f µm²", row.gap_area_um2))
                        .frame(maxWidth: .infinity, alignment: .trailing)
                    Text(String(format: "%.0f%%", row.pct_closure))
                        .frame(width: 56, alignment: .trailing)
                }
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(Tokens.text)
                .padding(.vertical, 3)
            }
        }
    }
}

// MARK: — 3) Spheroid / organoid

/// Detects large round object(s) — spheroid(s) / organoid(s) — in a
/// (typically low-mag) image and reports area, equivalent diameter,
/// perimeter, and circularity per object. See `_assays_area.spheroids`.
private struct SpheroidAssayView: View {
    @Bindable var state: AppState

    @State private var pickedURL: URL? = nil
    @State private var darkObject = true
    @State private var isRunning = false
    @State private var result: SpheroidResult? = nil
    @State private var errorMessage: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Detects large round object(s) and reports size and shape per object.")
                .font(.system(size: 11))
                .foregroundStyle(Tokens.textTertiary)
                .fixedSize(horizontal: false, vertical: true)

            FilePickerRow(label: "Choose image…", pickedURL: pickedURL,
                         allowedExtensions: AreaAssayFileTypes.image) { url in
                pickedURL = url; result = nil; errorMessage = nil
            }

            HStack(spacing: 8) {
                CustomToggle(isOn: $darkObject)
                Text("Dark object on a light field (brightfield)")
                    .font(.system(size: 11.5))
                    .foregroundStyle(Tokens.textSecondary)
            }

            RunButton(title: "Run", isRunning: isRunning, disabled: pickedURL == nil) { run() }

            if let errorMessage { ErrorText(message: errorMessage) }
            if let result { resultView(result) }
        }
    }

    private func run() {
        guard let pickedURL else { return }
        errorMessage = nil
        result = nil
        isRunning = true
        let pxPerUm = state.pxPerUm
        let invertFlag = darkObject
        Task { @MainActor in
            defer { isRunning = false }
            do {
                result = try await AreaAssaysRunner.spheroid(
                    imageURL: pickedURL, pxPerUm: pxPerUm, invert: invertFlag)
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    @ViewBuilder
    private func resultView(_ r: SpheroidResult) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            AssayHeroRow(label: "Objects found", value: "\(r.count)", unit: "")
            if r.objects.isEmpty {
                Text(r.message.isEmpty ? "No qualifying object found." : r.message)
                    .font(.system(size: 10.5))
                    .foregroundStyle(Tokens.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                VStack(spacing: 6) {
                    ForEach(Array(r.objects.prefix(20))) { obj in
                        objectRow(obj)
                    }
                }
                if r.objects.count > 20 {
                    Text("+ \(r.objects.count - 20) more")
                        .font(.system(size: 10.5))
                        .foregroundStyle(Tokens.textTertiary)
                }
            }
        }
    }

    @ViewBuilder
    private func objectRow(_ obj: SpheroidObject) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Object \(obj.label)")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Tokens.text)
            HStack(spacing: 12) {
                miniStat("Ø", String(format: "%.0f", obj.equivalent_diameter_um), "µm")
                miniStat("Area", String(format: "%.0f", obj.area_um2), "µm²")
                miniStat("Circ.", String(format: "%.2f", obj.circularity), "")
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: Tokens.Radius.sm, style: .continuous)
            .fill(Tokens.bgSunken))
    }

    private func miniStat(_ label: String, _ value: String, _ unit: String) -> some View {
        HStack(spacing: 2) {
            Text("\(label):")
                .font(.system(size: 10))
                .foregroundStyle(Tokens.textTertiary)
            Text(unit.isEmpty ? value : "\(value) \(unit)")
                .font(.system(size: 10.5, design: .monospaced))
                .foregroundStyle(Tokens.textSecondary)
        }
    }
}
