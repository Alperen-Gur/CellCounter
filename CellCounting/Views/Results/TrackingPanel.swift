import SwiftUI

// MOUNTED BY `ResultsView.swift`'s `AdditionalAssaysSection`:
//
//       TrackingPanel(state: state, roiSignal: roiSignal)
//
//   Unlike its per-image siblings this panel can't take the sidebar's `cells`
//   array — its input is EVERY frame in the batch, not the visible one — so it
//   still derives frames itself. It therefore needs `ResultsSidebar`'s
//   `roiSignal` explicitly: `state.repos.rois(for:)` is an untracked SwiftData
//   fetch, and without a value SwiftUI can observe, an ROI edit would not
//   re-evaluate this panel and its frame counts could disagree with
//   `TotalBlock`.
//
//   It draws its OWN leading `Divider()`, inside the same branch that decides
//   whether to render at all — a caller-supplied separator would still be
//   emitted for the (very common) single-image batch and double up with its
//   neighbour's.
//
// SERIES ORDER: frames are the CURRENT BATCH's images sorted by `importedAt`
// — the same ordering `AppState.currentImage` indexes into, so frame N here
// is the image the batch strip shows at position N. Drop a time-lapse as one
// batch, in acquisition order, and that ordering is the acquisition order.
//
// APPLICABILITY: renders `EmptyView` unless the current batch holds at least
// two images — a single still image is not a series, and putting a permanent
// "needs 2 frames" box in every single-image user's sidebar is exactly the
// clutter `MeasurementsPanel`/`ColoniesPanel` avoid by hiding themselves.
// Flip `minimumImagesInBatch` below to 1 if that call should go the other way.
// The DEGENERATE case inside a real series is never silent: when fewer than
// two frames actually carry detections the panel says so explicitly (see
// `seriesStatusNote`) and disables Run, and `TrackingRunner` throws a
// matching, specific message if it is reached anyway.
//
// Results live in local `@State`, are NOT persisted, and are tagged with a
// `SeriesResultKey` — batch id PLUS a per-frame cell-count and cutoff
// fingerprint — so tracks can never be read against a frame set they were not
// computed from. The batch id alone had the same blind spot an image id has
// for the per-image panels: re-detecting or editing any frame leaves it
// untouched. See `AssayResultKey`'s doc comment for the full rationale.

/// Cell tracking / migration results for one ordered image series. Runs
/// `track_cells.py` via `TrackingRunner`.
struct TrackingPanel: View {
    @Bindable var state: AppState
    /// `ResultsSidebar.roiSignal`, bumped on any ROI count change. Read inside
    /// `frames` purely so SwiftUI has an observable dependency for the
    /// untracked ROI fetch — see the header note.
    let roiSignal: Int

    /// Minimum images in the batch for this panel to appear at all — see the
    /// APPLICABILITY note above.
    private static let minimumImagesInBatch = 2

    /// Cap on how many individual track rows are listed inline. A series with
    /// hundreds of tracks would otherwise make this panel unusably tall — it
    /// already lives inside `ResultsSidebar`'s outer `ScrollView`, so it can't
    /// scroll independently without feeling broken. Sorted by total path
    /// length descending, so the rows shown are the most migratory (most
    /// informative) cells first.
    private static let maxListedTracks = 8

    @State private var frameIntervalText: String = "10"
    @State private var maxDisplacementUm: Double = 50

    @State private var isRunning = false
    @State private var result: TrackingPayload? = nil
    /// Fingerprint of the frame set `result` was computed from — see the
    /// header note and `SeriesResultKey`.
    @State private var resultKey: SeriesResultKey? = nil
    @State private var errorMessage: String? = nil

    @Environment(AppTheme.self) private var theme

    // MARK: — Inputs sourced from `state`

    /// The batch's images in series order (oldest import first) — the same
    /// sort `AppState.currentImage` applies, so indices line up with the
    /// batch strip.
    private var orderedImages: [ImageRecord] {
        (state.currentBatch?.images ?? []).sorted { $0.importedAt < $1.importedAt }
    }

    /// One centroid list per frame, in series order. Each frame is filtered by
    /// ITS OWN image's effective confidence and ROIs — the same derivation
    /// `ResultsSidebar.cells` uses for the visible frame. Frames with no
    /// detections stay in place as empty arrays so the frame INDEX keeps
    /// mapping to real elapsed time.
    private var frames: [[DetectedCell]] {
        _ = roiSignal  // observable dependency for the untracked ROI fetch below
        return orderedImages.map { image in
            let cutoff = state.effectiveConfidence(for: image)
            let confidenceFiltered = (image.detection?.cells ?? []).filter { $0.confidence >= cutoff }
            return ROIFilter.apply(cells: confidenceFiltered, rois: state.repos.rois(for: image.id))
        }
    }

    private var framesWithDetections: Int {
        frames.filter { !$0.isEmpty }.count
    }

    private var parsedFrameInterval: Double? {
        guard let v = Double(frameIntervalText.trimmingCharacters(in: .whitespaces)), v > 0 else { return nil }
        return v
    }

    private var canRun: Bool {
        framesWithDetections >= TrackingRunner.minimumFrames && parsedFrameInterval != nil
    }

    /// Fingerprint of the frame set as it stands RIGHT NOW.
    private var currentKey: SeriesResultKey {
        SeriesResultKey(batchId: state.currentBatchId,
                        frameCellCounts: frames.map(\.count),
                        frameCutoffs: orderedImages.map { state.effectiveConfidence(for: $0) })
    }

    /// Nil unless `result` was computed from exactly the frame set the batch
    /// holds right now — not merely from the same batch.
    private var activeResult: TrackingPayload? {
        guard let resultKey, resultKey == currentKey else { return nil }
        return result
    }

    private var sortedTracks: [CellTrack] {
        (activeResult?.tracks ?? []).sorted { $0.total_path_length_um > $1.total_path_length_um }
    }

    var body: some View {
        // A single still image is not a series — skip the panel entirely.
        if orderedImages.count < Self.minimumImagesInBatch { return AnyView(EmptyView()) }
        return AnyView(content)
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Drawn here, not by the caller — see the header note.
            Divider().overlay(Tokens.divider)

            panelBody
        }
        // Belt and braces alongside `SeriesResultKey` — re-detect / split /
        // merge / delete on ANY frame post this.
        .onReceive(NotificationCenter.default.publisher(for: .ccCorrectionsChanged)) { _ in
            result = nil
            resultKey = nil
        }
    }

    private var panelBody: some View {
        VStack(alignment: .leading, spacing: 0) {
            SectionHeader(title: "Cell tracking")

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
        guard let interval = parsedFrameInterval else {
            errorMessage = "Enter the acquisition interval in minutes (e.g. 10)."
            return
        }
        errorMessage = nil
        result = nil
        resultKey = nil
        isRunning = true

        // Captured BEFORE the run so an edit to any frame that lands while the
        // sidecar is working invalidates the result instead of being stamped
        // onto it.
        let startKey = currentKey
        let framesSnapshot = frames
        // PIXELS PER MICROMETRE — forwarded to `--px-per-um` verbatim. Never
        // the reciprocal `pixel_size_um`; see TrackingRunner's header note.
        let pxPerUm = state.pxPerUm
        let maxDisp = maxDisplacementUm

        Task { @MainActor in
            defer { isRunning = false }
            do {
                let r = try await TrackingRunner.track(frames: framesSnapshot,
                                                       pxPerUm: pxPerUm,
                                                       frameIntervalMin: interval,
                                                       maxDisplacementUm: maxDisp)
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
            Text("Links cell centroids across this batch's images, in import order, "
                 + "into per-cell tracks.")
                .font(.system(size: 11))
                .foregroundStyle(Tokens.textTertiary)
                .fixedSize(horizontal: false, vertical: true)

            seriesStatusNote

            VStack(alignment: .leading, spacing: 4) {
                Text("Minutes between frames")
                    .font(.system(size: 10.5))
                    .foregroundStyle(Tokens.textTertiary)
                TextField("e.g. 10", text: $frameIntervalText)
                    .font(.system(size: 11.5, design: .monospaced))
                    .textFieldStyle(.plain)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 6)
                    .background(RoundedRectangle(cornerRadius: Tokens.Radius.sm, style: .continuous)
                        .fill(Tokens.bgSunken))
                    .overlay(RoundedRectangle(cornerRadius: Tokens.Radius.sm, style: .continuous)
                        .strokeBorder(Tokens.border, lineWidth: 0.5))
                if parsedFrameInterval == nil {
                    Text("Enter a positive number — if your interval is in seconds, divide by 60.")
                        .font(.system(size: 10))
                        .foregroundStyle(Tokens.warning)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            VStack(spacing: 3) {
                HStack {
                    Text("Max step between frames")
                        .font(.system(size: 11.5))
                        .foregroundStyle(Tokens.textSecondary)
                    Spacer()
                    Text(String(format: "%.0f µm", maxDisplacementUm))
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(Tokens.textTertiary)
                }
                Slider(value: $maxDisplacementUm, in: 5...300).tint(theme.accentColor)
            }

            Button {
                run()
            } label: {
                HStack(spacing: 6) {
                    if isRunning {
                        AppSpinner()
                    } else {
                        Icon("play", size: 11)
                    }
                    Text(isRunning ? "Tracking…" : (activeResult == nil ? "Track cells" : "Re-track"))
                }
                .frame(maxWidth: .infinity)
            }
            .appButton(.primary, size: .sm)
            .disabled(isRunning || !canRun)
        }
    }

    /// Always states what the series actually contains, so a run that can't
    /// produce tracks is explained BEFORE the user presses the button — never
    /// a silently empty panel.
    @ViewBuilder
    private var seriesStatusNote: some View {
        if framesWithDetections < TrackingRunner.minimumFrames {
            TrackingInfoNote(text: framesWithDetections <= 1
                ? "Tracking needs at least 2 frames with detections; \(framesWithDetections) of "
                  + "\(orderedImages.count) image(s) in this batch \(framesWithDetections == 1 ? "has" : "have") "
                  + "any. Run detection on each frame first."
                : "Tracking needs at least \(TrackingRunner.minimumFrames) frames with detections.")
        } else {
            Text("\(orderedImages.count) frame(s) in this batch, \(framesWithDetections) with detections.")
                .font(.system(size: 10))
                .foregroundStyle(Tokens.textQuaternary)
        }
    }

    // MARK: — Results

    @ViewBuilder
    private func resultsSection(_ result: TrackingPayload) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            if let message = result.message {
                TrackingInfoNote(text: message)
                    .padding(.bottom, result.tracks.isEmpty ? 0 : 12)
            }

            if !result.tracks.isEmpty {
                VStack(spacing: 4) {
                    TrackStatRow(label: "Tracks", value: "\(result.summary.n_tracks)", unit: "")
                    TrackStatRow(label: "Mean speed",
                                 value: String(format: "%.2f", result.summary.mean_speed_um_per_min),
                                 unit: "µm/min")
                    TrackStatRow(label: "Mean directionality",
                                 value: String(format: "%.2f", result.summary.mean_directionality_ratio),
                                 unit: "")
                    TrackStatRow(label: "Mean duration",
                                 value: String(format: "%.1f", result.summary.mean_track_duration_min),
                                 unit: "min")
                }
                .padding(.bottom, 12)

                TrackPathsPreview(tracks: result.tracks)
                    .padding(.bottom, 12)

                VStack(spacing: 0) {
                    ForEach(Array(sortedTracks.prefix(Self.maxListedTracks).enumerated()), id: \.element.id) { i, track in
                        if i > 0 { Divider().overlay(Tokens.divider.opacity(0.6)) }
                        TrackRow(track: track)
                    }
                }

                if result.tracks.count > Self.maxListedTracks {
                    Text("+ \(result.tracks.count - Self.maxListedTracks) more track(s) — showing the \(Self.maxListedTracks) longest paths")
                        .font(.system(size: 10.5))
                        .foregroundStyle(Tokens.textTertiary)
                        .padding(.top, 8)
                }
            }
        }
    }
}

// MARK: — Summary row (matches ColonyRow / MeasRow styling)

private struct TrackStatRow: View {
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

// MARK: — Per-track row

private struct TrackRow: View {
    let track: CellTrack

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .firstTextBaseline) {
                Text("Track \(track.track_id)")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Tokens.text)
                Text("· frames \(track.start_frame)–\(track.end_frame)")
                    .font(.system(size: 10.5))
                    .foregroundStyle(Tokens.textTertiary)
                Spacer()
                Text(String(format: "%.2f µm/min", track.mean_speed_um_per_min))
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(Tokens.text)
            }
            HStack(spacing: 12) {
                trackDetail("path", String(format: "%.1f µm", track.total_path_length_um))
                trackDetail("net", String(format: "%.1f µm", track.net_displacement_um))
                trackDetail("dir.", String(format: "%.2f", track.directionality_ratio))
            }
        }
        .padding(.vertical, 6)
    }

    private func trackDetail(_ label: String, _ value: String) -> some View {
        HStack(spacing: 3) {
            Text(label)
                .font(.system(size: 10))
                .foregroundStyle(Tokens.textTertiary)
            Text(value)
                .font(.system(size: 10.5, design: .monospaced))
                .foregroundStyle(Tokens.textSecondary)
        }
    }
}

// MARK: — Info note (neutral — degenerate-input / no-op explanations)
//
// Deliberately NOT warning-tinted: a "single frame provided" message is an
// expected, benign state (see `_tracking.py`'s "Degrade gracefully" note),
// not a data-quality concern. Contrast with `NeuriteOverlapCaveat` in
// NeuritePanel.swift, which uses the warning tint because that caveat is a
// genuine scientific-validity limitation on every result, not just a
// no-data notice.

private struct TrackingInfoNote: View {
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

// MARK: — Track paths preview
//
// Splice point: a future integration pass can render track paths directly
// over the live viewer canvas (e.g. inside `RealImageViewer`'s ZStack —
// the same place `EditableOverlay` / `EditableROI` / `LineProfileTool`
// already layer, in `ResultsView.swift`) by feeding it the SAME
// `viewScale`/`viewOffset` those views take, instead of this preview's own
// fit-to-box transform. Kept fully self-contained here (no dependency on
// `RealImageViewer`, which this pass does not own) so the sidebar panel can
// show the track paths today, without that integration.
//
// Draws every track as a polyline in source-image pixel space, scaled to
// fit the preview box while preserving aspect ratio, colored by cycling
// through the app's existing 5-stop bin ramp (`Tokens.bins`) so it uses no
// new palette. A small filled dot marks each track's starting point.
struct TrackPathsPreview: View {
    let tracks: [CellTrack]
    var height: CGFloat = 150

    private var bounds: CGRect {
        let pts = tracks.flatMap(\.pathPx)
        guard !pts.isEmpty else { return CGRect(x: 0, y: 0, width: 1, height: 1) }
        let xs = pts.map(\.x)
        let ys = pts.map(\.y)
        let minX = xs.min() ?? 0
        let maxX = xs.max() ?? (minX + 1)
        let minY = ys.min() ?? 0
        let maxY = ys.max() ?? (minY + 1)
        return CGRect(x: minX, y: minY,
                      width: max(maxX - minX, 1),
                      height: max(maxY - minY, 1))
    }

    var body: some View {
        Canvas { context, size in
            let b = bounds
            let pad: CGFloat = 8
            let availW = max(size.width - pad * 2, 1)
            let availH = max(size.height - pad * 2, 1)
            let scale = min(availW / b.width, availH / b.height)

            func mapped(_ p: CGPoint) -> CGPoint {
                CGPoint(x: pad + (p.x - b.minX) * scale,
                        y: pad + (p.y - b.minY) * scale)
            }

            for (i, track) in tracks.enumerated() {
                let pts = track.pathPx.map(mapped)
                guard let first = pts.first else { continue }
                let color = Tokens.binColor(i % Tokens.bins.count)

                if pts.count >= 2 {
                    var path = Path()
                    path.move(to: pts[0])
                    for p in pts.dropFirst() { path.addLine(to: p) }
                    context.stroke(path, with: .color(color),
                                   style: StrokeStyle(lineWidth: 1.3, lineCap: .round, lineJoin: .round))
                }
                context.fill(Path(ellipseIn: CGRect(x: first.x - 2, y: first.y - 2, width: 4, height: 4)),
                             with: .color(color))
            }
        }
        .frame(height: height)
        .frame(maxWidth: .infinity)
        .background(
            RoundedRectangle(cornerRadius: Tokens.Radius.sm, style: .continuous)
                .fill(Tokens.bgSunken))
        .overlay(
            RoundedRectangle(cornerRadius: Tokens.Radius.sm, style: .continuous)
                .strokeBorder(Tokens.border, lineWidth: 0.5))
    }
}
