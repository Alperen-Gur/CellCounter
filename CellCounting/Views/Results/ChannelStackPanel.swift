import SwiftUI

// MARK: — Settings store shared with the detection layer

/// Persisted Z / channel choices for multi-plane, multi-channel acquisitions.
///
/// The panel below writes these; the detection layer reads them to build the
/// sidecar command line. They live in `UserDefaults` (not `AppState`) so both
/// sides can reach them without a new dependency in either direction.
///
/// Mapping onto `_cellpose_common.build_arg_parser()`:
///
/// | Key                   | CLI flag             | Default |
/// |-----------------------|----------------------|---------|
/// | `cc-z-project`        | `--z-project`        | `max`   |
/// | `cc-segment-channel`  | `--segment-channel`  | `0`     |
/// | `cc-channel-names`    | (display only)       | `[]`    |
///
/// `cc-channel-names` is a JSON `[String]` of *user overrides*, positional by
/// channel index. An empty entry means "keep whatever the file reported".
enum ChannelStackSettings {
    static let zProjectKey = "cc-z-project"
    static let segmentChannelKey = "cc-segment-channel"
    static let channelNamesKey = "cc-channel-names"

    /// Z-projection modes, in the order the segmented control shows them.
    /// Raw values are exactly the `--z-project` choices the sidecar accepts.
    enum ZProjection: String, CaseIterable, Identifiable {
        case max
        case sum
        case mean
        case none

        var id: String { rawValue }

        var label: String {
            switch self {
            case .max:  return "Max"
            case .sum:  return "Sum"
            case .mean: return "Mean"
            case .none: return "Single"
            }
        }

        var explanation: String {
            switch self {
            case .max:
                return "Brightest value per pixel across the stack. The usual "
                     + "choice for fluorescence — keeps every in-focus cell."
            case .sum:
                return "Adds every plane. Preserves total signal, so it suits "
                     + "quantification, but saturates bright regions."
            case .mean:
                return "Averages the planes. Suppresses noise at the cost of "
                     + "dimming anything only in focus on one plane."
            case .none:
                // Wording tracks `_imageio.load_planes` exactly: it indexes
                // `shape[zi] // 2` — a ZERO-BASED floor, i.e. the 3rd plane of
                // both a 4- and a 5-plane stack. (The previous copy said
                // "plane ⌈Z/2⌉", which is off by one for every even Z.)
                return "No projection — segments the central plane only "
                     + "(zero-based index Z\u{00F7}2 rounded down: the 3rd "
                     + "plane of a 4- or 5-plane stack, since plane 0 is "
                     + "usually the out-of-focus end)."
            }
        }
    }

    /// Current Z-projection mode, falling back to `.max` for an unset or
    /// unrecognised value.
    static var zProjection: ZProjection {
        let raw = UserDefaults.standard.string(forKey: zProjectKey) ?? ""
        return ZProjection(rawValue: raw) ?? .max
    }

    /// Zero-based index of the channel the segmenter runs on.
    static var segmentChannel: Int {
        max(0, UserDefaults.standard.integer(forKey: segmentChannelKey))
    }

    /// User-supplied channel-name overrides, positional by channel index.
    static var channelNameOverrides: [String] {
        guard let raw = UserDefaults.standard.string(forKey: channelNamesKey),
              let data = raw.data(using: .utf8),
              let names = try? JSONDecoder().decode([String].self, from: data)
        else { return [] }
        return names
    }

    /// Merge loader-reported names with the user's overrides.
    static func resolvedNames(detected: [String]) -> [String] {
        let overrides = channelNameOverrides
        return detected.enumerated().map { index, detectedName in
            let override = index < overrides.count ? overrides[index] : ""
            let trimmed = override.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { return trimmed }
            return detectedName.isEmpty ? "Ch\(index)" : detectedName
        }
    }

    /// Extra sidecar arguments implied by the current settings. Append these to
    /// whatever the detection service already builds.
    static func sidecarArguments() -> [String] {
        ["--z-project", zProjection.rawValue,
         "--segment-channel", String(segmentChannel)]
    }
}

// MARK: — Panel

/// Lets the user tell the sidecar how to flatten a Z-stack, which channel to
/// segment on, and what to call each channel.
///
/// Self-contained: it reads and writes `UserDefaults` through
/// `ChannelStackSettings`, so it can be dropped into any sidebar without
/// threading new state through `AppState`. Pass the channel names and Z depth
/// the loader reported for the current image; with the defaults (no channels,
/// one plane) it renders an explanatory empty state instead of dead controls.
struct ChannelStackPanel: View {
    /// Channel names reported by the image loader, in source order. Empty when
    /// nothing has been loaded yet or the source is single-channel.
    var detectedChannelNames: [String] = []
    /// Number of Z planes in the source. 1 means "not a stack".
    ///
    /// Pass **0 for "unknown"**. `_imageio` knows the plane count but never
    /// reports it back across the sidecar boundary (`image_stats` is a
    /// `[String: Double]` blob of QC/colony scalars and carries no `z_count`),
    /// so the app genuinely cannot tell a Z-stack from a single plane. Claiming
    /// "this image has a single focal plane" in that case would be a guess
    /// dressed up as a fact, AND it would grey out the one control a Z-stack
    /// user needs — so `0` keeps the projection picker live and says plainly
    /// that the setting governs the next run.
    var zPlaneCount: Int = 1
    /// Fired after any change, so the host can offer to re-run detection.
    var onChange: (() -> Void)? = nil

    @AppStorage(ChannelStackSettings.zProjectKey)
    private var zProjectRaw: String = ChannelStackSettings.ZProjection.max.rawValue
    @AppStorage(ChannelStackSettings.segmentChannelKey)
    private var segmentChannel: Int = 0
    @AppStorage(ChannelStackSettings.channelNamesKey)
    private var channelNamesJSON: String = "[]"

    /// Live edit buffer for the name fields, flushed into `channelNamesJSON`.
    @State private var nameDrafts: [String] = []
    /// Which channel's name field is expanded for editing.
    @State private var renaming: Bool = false

    @Environment(AppTheme.self) private var theme

    private var channelCount: Int { detectedChannelNames.count }
    /// False when the caller passed `0` — see `zPlaneCount`.
    private var zDepthKnown: Bool { zPlaneCount >= 1 }
    private var isStack: Bool { zPlaneCount > 1 }
    /// The projection picker is live for a known stack, and also whenever the
    /// depth is unknown — the setting still governs the next detection run.
    private var zControlEnabled: Bool { isStack || !zDepthKnown }
    private var isMultiChannel: Bool { channelCount > 1 }

    private var zProjection: ChannelStackSettings.ZProjection {
        ChannelStackSettings.ZProjection(rawValue: zProjectRaw) ?? .max
    }

    private var resolvedNames: [String] {
        detectedChannelNames.enumerated().map { index, detected in
            let draft = index < nameDrafts.count ? nameDrafts[index] : ""
            let trimmed = draft.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { return trimmed }
            return detected.isEmpty ? "Ch\(index)" : detected
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            SectionHeader(title: "Channels & Z", trailing: AnyView(sourceBadge))

            Divider().overlay(Tokens.divider)

            zSection

            Divider().overlay(Tokens.divider)

            channelSection

            if isMultiChannel {
                Divider().overlay(Tokens.divider)
                namesSection
            }
        }
        .onAppear { loadDrafts() }
        .onChange(of: detectedChannelNames) { _, _ in loadDrafts() }
    }

    // MARK: — Header badge

    @ViewBuilder
    private var sourceBadge: some View {
        if isStack || isMultiChannel {
            HStack(spacing: 5) {
                if isStack {
                    TagLabel(text: "\(zPlaneCount) Z", style: .accent)
                }
                if isMultiChannel {
                    TagLabel(text: "\(channelCount) ch", style: .accent)
                }
            }
        } else {
            EmptyView()
        }
    }

    // MARK: — Z projection

    private var zSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Icon("layers", size: 13)
                    .foregroundStyle(Tokens.textSecondary)
                Text("Z-projection")
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(Tokens.textSecondary)
                Spacer()
            }

            SegmentedPicker(
                value: Binding(
                    get: { zProjection },
                    set: { newValue in
                        guard newValue != zProjection else { return }
                        zProjectRaw = newValue.rawValue
                        onChange?()
                    }
                ),
                options: ChannelStackSettings.ZProjection.allCases.map {
                    (value: $0, label: $0.label)
                }
            )
            .frame(maxWidth: .infinity, alignment: .leading)
            .opacity(zControlEnabled ? 1 : 0.55)
            .disabled(!zControlEnabled)

            Text(zProjectionNote)
                .font(.system(size: 10.5))
                .foregroundStyle(Tokens.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
                .animation(Tokens.Motion.easeFast, value: zProjectRaw)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 16)
    }

    /// Honest copy for all three cases: known stack, known single plane, and
    /// unknown depth (which the app can't distinguish — see `zPlaneCount`).
    private var zProjectionNote: String {
        if isStack { return zProjection.explanation }
        if !zDepthKnown {
            return zProjection.explanation
                + " Applies to the next detection run; CellCounter can't read "
                + "the plane count back from the loader, so this is shown for "
                + "every image and is ignored for single-plane files."
        }
        return "This image has a single focal plane, so no projection is "
             + "applied. The setting is remembered for the next Z-stack."
    }

    // MARK: — Segmentation channel

    private var channelSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Icon("eye", size: 13)
                    .foregroundStyle(Tokens.textSecondary)
                Text("Segment on")
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(Tokens.textSecondary)
                Spacer()
            }

            if isMultiChannel {
                // Wraps naturally for acquisitions with many channels.
                FlowRow(spacing: 6) {
                    ForEach(Array(resolvedNames.enumerated()), id: \.offset) { index, name in
                        Chip(title: name,
                             active: index == clampedSegmentChannel,
                             dot: Tokens.binColor(index)) {
                            guard index != segmentChannel else { return }
                            segmentChannel = index
                            onChange?()
                        }
                    }
                }

                Text("Cells are detected in this channel only. Intensities are "
                     + "still measured for every cell in all \(channelCount) "
                     + "channels.")
                    .font(.system(size: 10.5))
                    .foregroundStyle(Tokens.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Text(channelCount == 1
                     ? "Single-channel image — everything is measured in "
                     + "\(resolvedNames.first ?? "Ch0")."
                     : "Load an image to choose a segmentation channel.")
                    .font(.system(size: 10.5))
                    .foregroundStyle(Tokens.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 16)
    }

    private var clampedSegmentChannel: Int {
        guard channelCount > 0 else { return 0 }
        return max(0, min(channelCount - 1, segmentChannel))
    }

    // MARK: — Channel names

    private var namesSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Icon("table", size: 13)
                    .foregroundStyle(Tokens.textSecondary)
                Text("Channel names")
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(Tokens.textSecondary)
                Spacer()
                Button {
                    withAnimation(Tokens.Motion.easeFast) { renaming.toggle() }
                } label: {
                    Text(renaming ? "Done" : "Rename")
                        .font(.system(size: 11.5))
                        .foregroundStyle(theme.accentColor)
                }
                .buttonStyle(.plain)
            }

            if renaming {
                VStack(spacing: 6) {
                    ForEach(Array(detectedChannelNames.enumerated()), id: \.offset) { index, detected in
                        HStack(spacing: 8) {
                            Circle()
                                .fill(Tokens.binColor(index))
                                .frame(width: 8, height: 8)
                            Text("\(index)")
                                .font(.system(size: 10.5, design: .monospaced))
                                .foregroundStyle(Tokens.textTertiary)
                                .frame(width: 14, alignment: .leading)
                            TextField(detected.isEmpty ? "Ch\(index)" : detected,
                                      text: bindingForDraft(index))
                                .textFieldStyle(.plain)
                                .font(.system(size: 12))
                                .foregroundStyle(Tokens.text)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 5)
                                .background(
                                    RoundedRectangle(cornerRadius: Tokens.Radius.sm,
                                                     style: .continuous)
                                        .fill(Tokens.bgSunken)
                                )
                                .overlay(
                                    RoundedRectangle(cornerRadius: Tokens.Radius.sm,
                                                     style: .continuous)
                                        .strokeBorder(Tokens.border, lineWidth: 0.5)
                                )
                        }
                    }
                }

                HStack {
                    Button("Reset to file") { resetDrafts() }
                        .appButton(.ghost, size: .sm)
                    Spacer()
                }
            } else {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(Array(resolvedNames.enumerated()), id: \.offset) { index, name in
                        HStack(spacing: 8) {
                            Circle()
                                .fill(Tokens.binColor(index))
                                .frame(width: 8, height: 8)
                            Text(name)
                                .font(.system(size: 12))
                                .foregroundStyle(Tokens.text)
                            Spacer()
                            if index == clampedSegmentChannel {
                                TagLabel(text: "segmented", style: .accent)
                            }
                        }
                    }
                }
            }

            Text("Names label the per-cell intensity columns in exports and the "
                 + "results table. They do not change the pixel data.")
                .font(.system(size: 10.5))
                .foregroundStyle(Tokens.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 16)
    }

    // MARK: — Draft handling

    private func bindingForDraft(_ index: Int) -> Binding<String> {
        Binding(
            get: { index < nameDrafts.count ? nameDrafts[index] : "" },
            set: { newValue in
                while nameDrafts.count <= index { nameDrafts.append("") }
                nameDrafts[index] = newValue
                saveDrafts()
            }
        )
    }

    /// Pull stored overrides into the edit buffer, sized to the current image.
    private func loadDrafts() {
        var stored = ChannelStackSettings.channelNameOverrides
        if stored.count < channelCount {
            stored.append(contentsOf: Array(repeating: "",
                                            count: channelCount - stored.count))
        } else if stored.count > channelCount {
            stored = Array(stored.prefix(channelCount))
        }
        nameDrafts = stored
        // A stale index from a previous image with more channels would leave
        // the chip row with nothing selected — snap it back into range.
        if channelCount > 0 && segmentChannel > channelCount - 1 {
            segmentChannel = channelCount - 1
        }
    }

    private func saveDrafts() {
        guard let data = try? JSONEncoder().encode(nameDrafts),
              let json = String(data: data, encoding: .utf8) else { return }
        channelNamesJSON = json
        onChange?()
    }

    private func resetDrafts() {
        nameDrafts = Array(repeating: "", count: channelCount)
        saveDrafts()
    }
}

// MARK: — Minimal wrapping row

/// Lays subviews out left-to-right, wrapping onto new lines. Used for the
/// channel chips, which can run to eight or more on a spectral acquisition.
private struct FlowRow: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize,
                      subviews: Subviews,
                      cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0
        var widest: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > 0 && x + size.width > maxWidth {
                widest = max(widest, x - spacing)
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
        widest = max(widest, x - spacing)
        return CGSize(width: min(widest, maxWidth), height: y + rowHeight)
    }

    func placeSubviews(in bounds: CGRect,
                       proposal: ProposedViewSize,
                       subviews: Subviews,
                       cache: inout ()) {
        var x = bounds.minX
        var y = bounds.minY
        var rowHeight: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > bounds.minX && x + size.width > bounds.maxX {
                x = bounds.minX
                y += rowHeight + spacing
                rowHeight = 0
            }
            subview.place(at: CGPoint(x: x, y: y),
                          proposal: ProposedViewSize(size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}
