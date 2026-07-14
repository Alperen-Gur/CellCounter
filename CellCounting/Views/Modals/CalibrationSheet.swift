import SwiftUI

// MARK: - CalibrationSheet

struct CalibrationSheet: View {
    let current: Double
    let onClose: () -> Void
    let onSave: (Double) -> Void
    /// Bug #11: optional URL of the currently-open image for "Draw on scale bar" tab.
    var imageURL: URL? = nil
    /// Optional repository handle so the "Use preset" tab can show user
    /// presets alongside built-ins and the inline "New preset…" can persist
    /// a new `CalibrationPresetRecord` without a round-trip through Settings.
    /// Nil-safe: when not passed, the tab degrades to built-ins only.
    var repos: Repositories? = nil

    enum CalibTab { case direct, drawline, preset }

    @State private var tab: CalibTab
    @State private var val: Double
    /// Measured scale-bar length in image pixels. Starts at 0 ("nothing measured
    /// yet") so the drawline tab can't Save a stale value before the user draws.
    @State private var lineLength: Double = 0
    @State private var refUm: Double = 100
    @State private var selectedPreset: String = "Olympus IX73 — 20×"
    @State private var appeared = false

    @Environment(AppTheme.self) private var theme

    init(current: Double,
         imageURL: URL? = nil,
         repos: Repositories? = nil,
         onClose: @escaping () -> Void,
         onSave: @escaping (Double) -> Void) {
        self.current = current
        self.imageURL = imageURL
        self.repos = repos
        self.onClose = onClose
        self.onSave = onSave
        self._val = State(initialValue: current > 0 ? current : 5.2)
        // Reliability over cleverness: when an image is open, land on the
        // "Draw on scale bar" tab — clicking the burnt-in scale bar is the most
        // accurate calibration path. Fall back to manual entry when there's no
        // image to draw on.
        self._tab = State(initialValue: imageURL != nil ? .drawline : .direct)
    }

    private var derivedVal: Double { refUm > 0 ? lineLength / refUm : 0 }

    var body: some View {
        ZStack {
            Tokens.bgOverlay
                .background(.ultraThinMaterial)
                .ignoresSafeArea()
                .onTapGesture { onClose() }

            VStack(spacing: 0) {
                CalibHeader(theme: theme, onClose: onClose)
                    .padding(.horizontal, 24)
                    .padding(.top, 20)
                    .padding(.bottom, 0)

                CalibTabBar(tab: $tab)
                    .padding(.horizontal, 24)
                    .padding(.top, 16)
                    .padding(.bottom, 18)

                Group {
                    switch tab {
                    case .direct:
                        CalibDirectTab(val: $val)
                            .padding(.horizontal, 24)
                            .padding(.bottom, 22)
                    case .drawline:
                        CalibDrawlineTab(val: $val, lineLength: $lineLength, refUm: $refUm, derivedVal: derivedVal, theme: theme, imageURL: imageURL)
                            .padding(.horizontal, 24)
                            .padding(.bottom, 22)
                    case .preset:
                        CalibPresetTab(selectedPreset: $selectedPreset,
                                       currentVal: val,
                                       repos: repos,
                                       theme: theme) { name, pxPerUm in
                            selectedPreset = name
                            val = pxPerUm
                        }
                        .padding(.horizontal, 24)
                        .padding(.bottom, 22)
                    }
                }

                CalibFooter(
                    saveDisabled: {
                        switch tab {
                        case .direct: return val <= 0
                        case .drawline: return derivedVal <= 0
                        case .preset: return false
                        }
                    }(),
                    onClose: onClose
                ) {
                    let saveVal: Double
                    switch tab {
                    case .direct: saveVal = val
                    case .drawline: saveVal = derivedVal
                    case .preset: saveVal = CalibrationPreset.builtIn.first(where: { $0.name == selectedPreset })?.pxPerUm ?? val
                    }
                    // B4-4: guard against zero/negative pxPerUm to prevent divide-by-zero downstream
                    guard saveVal > 0 else { return }
                    onSave(saveVal)
                    onClose()
                }
            }
            .frame(width: 560)
            .background(Tokens.bg)
            .clipShape(RoundedRectangle(cornerRadius: Tokens.Radius.xl, style: .continuous))
            .shadow(color: .black.opacity(0.22), radius: 60, y: 24)
            .offset(y: appeared ? 0 : -12)
            .opacity(appeared ? 1 : 0)
            .scaleEffect(appeared ? 1 : 0.98)
        }
        .onAppear {
            withAnimation(Tokens.Motion.easeSlow) { appeared = true }
        }
        .keyboardShortcut(.cancelAction)
        // Enter — save when valid
        .onKeyPress(.return) {
            let saveDisabled: Bool
            switch tab {
            case .direct:    saveDisabled = val <= 0
            case .drawline:  saveDisabled = derivedVal <= 0
            case .preset:    saveDisabled = false
            }
            guard !saveDisabled else { return .ignored }
            let saveVal: Double
            switch tab {
            case .direct:   saveVal = val
            case .drawline: saveVal = derivedVal
            case .preset:   saveVal = CalibrationPreset.builtIn.first(where: { $0.name == selectedPreset })?.pxPerUm ?? val
            }
            guard saveVal > 0 else { return .ignored }
            onSave(saveVal)
            onClose()
            return .handled
        }
        .onChange(of: tab) { _, newTab in
            if newTab == .drawline { val = derivedVal }
        }
        .onChange(of: lineLength) { _, _ in
            if tab == .drawline { val = derivedVal }
        }
        .onChange(of: refUm) { _, _ in
            if tab == .drawline { val = derivedVal }
        }
    }
}

private struct CalibHeader: View {
    let theme: AppTheme
    let onClose: () -> Void

    var body: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Calibrate scale")
                    .font(.system(size: 18, weight: .bold))
                    .tracking(-0.01 * 18)
                    .foregroundStyle(Tokens.text)
                Text("Tells CellCounter how many pixels make a micrometer. Without this, sizes are wrong.")
                    .font(.system(size: 12.5))
                    .foregroundStyle(Tokens.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            Button(action: onClose) {
                Icon("x", size: 14)
                    .foregroundStyle(Tokens.textSecondary)
                    .frame(width: 26, height: 26)
                    .background(RoundedRectangle(cornerRadius: Tokens.Radius.md, style: .continuous).fill(Tokens.bgSunken))
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.cancelAction)
        }
    }
}

private struct CalibTabBar: View {
    @Binding var tab: CalibrationSheet.CalibTab

    var body: some View {
        HStack(spacing: 4) {
            CalibTabItem(label: "Enter scale", active: tab == .direct) { tab = .direct }
            CalibTabItem(label: "Draw on scale bar", active: tab == .drawline) { tab = .drawline }
            CalibTabItem(label: "Use preset", active: tab == .preset) { tab = .preset }
        }
        .padding(4)
        .background(RoundedRectangle(cornerRadius: Tokens.Radius.md, style: .continuous).fill(Tokens.bgSunken))
    }
}

private struct CalibTabItem: View {
    let label: String
    let active: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(label)
                .font(.system(size: 12.5, weight: .medium))
                .foregroundStyle(active ? Tokens.text : Tokens.textSecondary)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
                .padding(.horizontal, 12)
                .background(
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .fill(active ? Tokens.bgElevated : .clear)
                        .shadow(color: active ? .black.opacity(0.06) : .clear, radius: 1.5, y: 0.7)
                )
        }
        .buttonStyle(.plain)
        .animation(Tokens.Motion.easeFast, value: active)
    }
}

private struct CalibDirectTab: View {
    @Binding var val: Double

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            CalibInputBox(value: $val, unit: "px / µm")
            Text("For our 20× objective on the IX73, this is typically ")
                .font(.system(size: 12))
                .foregroundStyle(Tokens.textTertiary)
            + Text("5.2")
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(Tokens.textTertiary)
            + Text(". Check your microscope's manual or run the slide ruler calibration once.")
                .font(.system(size: 12))
                .foregroundStyle(Tokens.textTertiary)
        }
    }
}

private struct CalibInputBox: View {
    @Binding var value: Double
    let unit: String

    var body: some View {
        HStack(spacing: 10) {
            TextField("", value: $value, format: .number.precision(.fractionLength(2)))
                .font(.system(size: 18, weight: .semibold, design: .monospaced))
                .foregroundStyle(Tokens.text)
                .textFieldStyle(.plain)
                .frame(maxWidth: .infinity, alignment: .leading)
            Text(unit)
                .font(.system(size: 12.5))
                .foregroundStyle(Tokens.textTertiary)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(RoundedRectangle(cornerRadius: Tokens.Radius.md, style: .continuous).fill(Tokens.bgSunken))
    }
}

private struct CalibDrawlineTab: View {
    @Binding var val: Double
    @Binding var lineLength: Double
    @Binding var refUm: Double
    let derivedVal: Double
    let theme: AppTheme
    // Bug #11: optional real image URL
    var imageURL: URL? = nil

    // Line drawing state: first click sets lineStart, second (drag end) sets lineEnd.
    // Drag: press and drag to set both endpoints at once.
    @State private var lineStart: CGPoint? = nil
    @State private var lineEnd: CGPoint? = nil
    @State private var isDragging: Bool = false
    /// Constrain the drawn line to the horizontal axis. Scale bars are always
    /// horizontal, so this removes the length over-estimate you get from a
    /// slightly-tilted drag — a genuine accuracy win. Default on.
    @State private var snapHorizontal: Bool = true

    /// Common burnt-in scale-bar lengths (µm) offered as one-tap chips so the
    /// user never has to type the reference length.
    private let refPresets: [Double] = [10, 20, 25, 50, 100, 200, 250, 500, 1000]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            previewArea
                .aspectRatio(16/9, contentMode: .fit)
                .background(Tokens.bgSunken)
                .clipShape(RoundedRectangle(cornerRadius: Tokens.Radius.md, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: Tokens.Radius.md, style: .continuous)
                        .strokeBorder(Tokens.border, lineWidth: 0.5)
                )

            // Snap-to-horizontal toggle.
            HStack(spacing: 10) {
                CustomToggle(isOn: $snapHorizontal)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Snap to horizontal")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(Tokens.text)
                    Text("Keeps the measurement level with the scale bar")
                        .font(.system(size: 11))
                        .foregroundStyle(Tokens.textTertiary)
                }
                Spacer(minLength: 0)
            }

            HStack(spacing: 10) {
                CalibInputBox(value: $lineLength, unit: "px (line)")
                CalibInputBox(value: $refUm, unit: "µm (real)")
            }

            // One-tap reference-length chips — sets the "µm (real)" value.
            VStack(alignment: .leading, spacing: 6) {
                Text("Scale-bar length")
                    .font(.system(size: 11))
                    .foregroundStyle(Tokens.textTertiary)
                HStack(spacing: 5) {
                    ForEach(refPresets, id: \.self) { v in
                        let selected = abs(refUm - v) < 0.001
                        Button { refUm = v } label: {
                            Text(v.trimmedString)
                                .font(.system(size: 11.5, weight: .medium, design: .monospaced))
                                .foregroundStyle(selected ? theme.accentColor : Tokens.textSecondary)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 4)
                                .background(
                                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                                        .fill(selected ? theme.accentSoft : Tokens.bgSunken)
                                )
                                .overlay(
                                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                                        .strokeBorder(Tokens.borderStrong, lineWidth: 0.5)
                                )
                        }
                        .buttonStyle(.plain)
                    }
                }
            }

            HStack(spacing: 6) {
                Text("=")
                    .font(.system(size: 12.5))
                    .foregroundStyle(Tokens.textSecondary)
                Text(String(format: "%.2f px / µm", derivedVal))
                    .font(.system(size: 12.5, weight: .semibold, design: .monospaced))
                    .foregroundStyle(derivedVal > 0 ? Tokens.text : Tokens.textTertiary)
                if derivedVal > 0 {
                    Text("· \(AppState.objectiveLabel(for: derivedVal))")
                        .font(.system(size: 11.5))
                        .foregroundStyle(Tokens.textTertiary)
                }
                Spacer(minLength: 0)
            }
        }
    }

    /// Apply the horizontal-snap constraint to a drag end point.
    private func snappedEnd(from start: CGPoint, to end: CGPoint) -> CGPoint {
        snapHorizontal ? CGPoint(x: end.x, y: start.y) : end
    }

    // MARK: - Preview area

    @ViewBuilder
    private var previewArea: some View {
        if let url = imageURL, let nsImage = NSImage(contentsOf: url) {
            // Real image: show it aspect-fitted and let the user drag a line on it
            GeometryReader { geo in
                ZStack {
                    Image(nsImage: nsImage)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)

                    // Instruction label when no line drawn yet
                    if lineStart == nil {
                        Text("Drag across the scale bar to measure it")
                            .font(.system(size: 11.5, weight: .medium))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 5)
                            .background(Color.black.opacity(0.55).clipShape(RoundedRectangle(cornerRadius: 6)))
                    }

                    // Drawn line overlay
                    if let s = lineStart, let e = lineEnd {
                        Canvas { ctx, _ in
                            let accentColor = theme.accentColor
                            var path = Path()
                            path.move(to: s)
                            path.addLine(to: e)
                            ctx.stroke(path, with: .color(accentColor), style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                            let capR: CGFloat = 4
                            ctx.fill(Path(ellipseIn: CGRect(x: s.x - capR, y: s.y - capR, width: capR*2, height: capR*2)), with: .color(accentColor))
                            ctx.fill(Path(ellipseIn: CGRect(x: e.x - capR, y: e.y - capR, width: capR*2, height: capR*2)), with: .color(accentColor))

                            // Length label
                            let mid = CGPoint(x: (s.x + e.x) / 2, y: (s.y + e.y) / 2)
                            ctx.draw(
                                Text(String(format: "%.0f px", lineLength))
                                    .font(.system(size: 10, design: .monospaced))
                                    .foregroundStyle(accentColor),
                                at: CGPoint(x: mid.x, y: mid.y - 12),
                                anchor: .center
                            )
                        }
                        .allowsHitTesting(false)
                    }
                }
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { v in
                            let s = v.startLocation
                            let e = snappedEnd(from: s, to: v.location)
                            lineStart = s
                            lineEnd = e
                            isDragging = true
                            updateLineLengthFromPoints(s, e, in: geo.size, nsImage: nsImage)
                        }
                        .onEnded { v in
                            let s = v.startLocation
                            let e = snappedEnd(from: s, to: v.location)
                            lineStart = s
                            lineEnd = e
                            isDragging = false
                            updateLineLengthFromPoints(s, e, in: geo.size, nsImage: nsImage)
                        }
                )
                .cursor(.crosshair)
            }
        } else {
            // No image loaded — show mock preview with explanatory label
            ZStack {
                MicroscopePreviewCanvas(lineLength: lineLength, accentColor: theme.accentColor)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                if imageURL == nil {
                    VStack(spacing: 4) {
                        Spacer()
                        Text("Open an image to draw on its scale bar.")
                            .font(.system(size: 11.5, weight: .medium))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 5)
                            .background(Color.black.opacity(0.55).clipShape(RoundedRectangle(cornerRadius: 6)))
                            .padding(.bottom, 10)
                    }
                }
            }
        }
    }

    /// Convert view-space points to image-pixel distances and update lineLength.
    private func updateLineLengthFromPoints(_ a: CGPoint, _ b: CGPoint, in viewSize: CGSize, nsImage: NSImage) {
        guard viewSize.width > 0, viewSize.height > 0 else { return }
        let imgSize = nsImage.size
        guard imgSize.width > 0, imgSize.height > 0 else { return }

        // Aspect-fit scale: same logic SwiftUI uses for .aspectRatio(contentMode: .fit)
        let scaleX = viewSize.width / imgSize.width
        let scaleY = viewSize.height / imgSize.height
        let fitScale = min(scaleX, scaleY)

        // Convert point distance to image-pixel distance
        let dx = b.x - a.x
        let dy = b.y - a.y
        let viewDist = hypot(dx, dy)
        let pixelDist = viewDist / fitScale

        if pixelDist > 1 {
            lineLength = pixelDist
        }
    }
}

// MARK: - View+cursor helper (macOS only)

private extension View {
    func cursor(_ cursor: NSCursor) -> some View {
        self.onHover { inside in
            if inside { cursor.push() } else { NSCursor.pop() }
        }
    }
}

private struct MicroscopePreviewCanvas: View {
    let lineLength: Double
    let accentColor: Color

    var body: some View {
        Canvas { ctx, size in
            let w = size.width, h = size.height

            // Radial gradient background (grayscale microscope look)
            let center = CGPoint(x: w * 0.5, y: h * 0.5)
            let gradient = Gradient(colors: [
                Color(OKLCH(0.75, 0.005, 60)),
                Color(OKLCH(0.55, 0.005, 60))
            ])
            ctx.drawLayer { c in
                c.addFilter(.blur(radius: 0))
                let path = Path(ellipseIn: CGRect(x: 0, y: 0, width: w, height: h))
                c.fill(path, with: .linearGradient(gradient,
                    startPoint: center,
                    endPoint: CGPoint(x: w, y: h)))
            }

            // Scale bar white box
            let barX: CGFloat = w * 0.125
            let barY: CGFloat = h * 0.78
            let barW: CGFloat = w * 0.25
            let barH: CGFloat = 6
            var barRect = Path()
            barRect.addRoundedRect(in: CGRect(x: barX, y: barY, width: barW, height: barH), cornerSize: CGSize(width: 1, height: 1))
            ctx.fill(barRect, with: .color(.white))
            ctx.stroke(barRect, with: .color(.black.opacity(0.35)), lineWidth: 0.5)

            // Scale bar label
            ctx.draw(
                Text("100 µm")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(Color.white),
                at: CGPoint(x: barX + barW / 2, y: barY + 18),
                anchor: .center
            )

            // User-drawn line in accent color
            // Map lineLength (px) to screen proportionally; cap at bar width
            let maxLinePx: CGFloat = barW
            let scaledLineW = min(CGFloat(lineLength) / 520 * w, maxLinePx * 1.2)
            let lineX1 = barX
            let lineX2 = lineX1 + scaledLineW
            let lineY = barY + 3

            var linePath = Path()
            linePath.move(to: CGPoint(x: lineX1, y: lineY))
            linePath.addLine(to: CGPoint(x: lineX2, y: lineY))
            ctx.stroke(linePath, with: .color(accentColor), style: StrokeStyle(lineWidth: 2.5, lineCap: .round))

            // End caps
            let capR: CGFloat = 3
            ctx.fill(Path(ellipseIn: CGRect(x: lineX1 - capR, y: lineY - capR, width: capR*2, height: capR*2)), with: .color(accentColor))
            ctx.fill(Path(ellipseIn: CGRect(x: lineX2 - capR, y: lineY - capR, width: capR*2, height: capR*2)), with: .color(accentColor))

            // Length label above line
            ctx.draw(
                Text(String(format: "%.0f px", lineLength))
                    .font(.system(size: 9.5, design: .monospaced))
                    .foregroundStyle(accentColor),
                at: CGPoint(x: (lineX1 + lineX2) / 2, y: lineY - 10),
                anchor: .center
            )
        }
    }
}

private struct CalibPresetTab: View {
    @Binding var selectedPreset: String
    let currentVal: Double
    let repos: Repositories?
    let theme: AppTheme
    let onSelect: (String, Double) -> Void

    /// User-saved presets fetched from SwiftData on appear and after each
    /// inline-create. The built-in array is unchanged.
    @State private var userPresets: [CalibrationPresetRecord] = []
    @State private var addingNew: Bool = false
    @State private var newPresetName: String = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(spacing: 0) {
                // SwiftData is the single source of truth for presets:
                // `Repositories.init` seeds `CalibrationPreset.builtIn` into the
                // store on first launch, then Settings → Calibration presets +
                // this sheet's inline "+ Save current value…" both write through
                // here too. Looping `builtIn` separately would duplicate those
                // four rows. If the store is empty (legacy install before the
                // seed code shipped, or all presets deleted by the user), we
                // fall back to the hardcoded array so the tab is never empty.
                let rows: [(id: AnyHashable, name: String, px: Double, record: CalibrationPresetRecord?)] = {
                    if !userPresets.isEmpty {
                        return userPresets.map {
                            (AnyHashable($0.id), $0.name, $0.pxPerUm, Optional($0))
                        }
                    }
                    return CalibrationPreset.builtIn.map {
                        (AnyHashable($0.id), $0.name, $0.pxPerUm, nil)
                    }
                }()
                ForEach(Array(rows.enumerated()), id: \.element.id) { idx, row in
                    PresetRow(name: row.name,
                              pxPerUm: row.px,
                              selected: selectedPreset == row.name,
                              theme: theme,
                              onTap: { onSelect(row.name, row.px) },
                              onDelete: row.record.flatMap { rec in
                                  repos.map { r in
                                      { r.deleteCalibrationPreset(rec); refresh() }
                                  }
                              })
                    if idx < rows.count - 1 {
                        Divider().padding(.horizontal, 14)
                    }
                }
            }
            .background(Tokens.bgSunken)
            .clipShape(RoundedRectangle(cornerRadius: Tokens.Radius.md, style: .continuous))

            // Inline "Save current value as preset" affordance — only offered
            // when a repo was wired up.
            if repos != nil {
                if addingNew {
                    HStack(spacing: 8) {
                        TextField("Preset name (e.g. \"IX73 — 20×\")", text: $newPresetName)
                            .textFieldStyle(.plain)
                            .font(.system(size: 12.5))
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .background(
                                RoundedRectangle(cornerRadius: Tokens.Radius.sm, style: .continuous)
                                    .fill(Tokens.bgSunken)
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: Tokens.Radius.sm, style: .continuous)
                                    .strokeBorder(Tokens.borderStrong, lineWidth: 0.5)
                            )
                            .onSubmit { commitNewPreset() }
                        Text(String(format: "%.2f px/µm", currentVal))
                            .font(.system(size: 11.5, design: .monospaced))
                            .foregroundStyle(Tokens.textTertiary)
                        Button("Cancel") { addingNew = false; newPresetName = "" }
                            .appButton(.standard, size: .sm)
                        Button("Save", action: commitNewPreset)
                            .appButton(.primary, size: .sm)
                            .disabled(newPresetName.trimmingCharacters(in: .whitespaces).isEmpty
                                      || currentVal <= 0)
                    }
                } else {
                    Button {
                        newPresetName = ""
                        addingNew = true
                    } label: {
                        HStack(spacing: 6) {
                            Icon("plus", size: 12)
                            Text("Save current value as new preset…")
                        }
                    }
                    .appButton(.ghost, size: .sm)
                    .disabled(currentVal <= 0)
                }
            }
        }
        .onAppear { refresh() }
    }

    private func refresh() {
        userPresets = repos?.calibrationPresets() ?? []
    }

    private func commitNewPreset() {
        guard let repos else { return }
        let trimmed = newPresetName.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, currentVal > 0 else { return }
        let rec = CalibrationPresetRecord(name: trimmed, pxPerUm: currentVal)
        repos.upsertCalibrationPreset(rec)
        addingNew = false
        newPresetName = ""
        refresh()
        selectedPreset = trimmed
    }
}

private struct PresetRow: View {
    let name: String
    let pxPerUm: Double
    let selected: Bool
    let theme: AppTheme
    let onTap: () -> Void
    /// nil for built-in fallback rows (no SwiftData record to delete).
    let onDelete: (() -> Void)?

    @State private var hovering = false

    var body: some View {
        Button(action: onTap) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(name)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(Tokens.text)
                    Text(String(format: "%.1f px / µm", pxPerUm))
                        .font(.system(size: 11.5, design: .monospaced))
                        .foregroundStyle(Tokens.textTertiary)
                }
                Spacer()
                if hovering, let onDelete {
                    Button(action: onDelete) {
                        Icon("trash", size: 12)
                            .foregroundStyle(Tokens.textTertiary)
                            .frame(width: 22, height: 22)
                    }
                    .buttonStyle(.plain)
                    .help("Delete preset")
                }
                if selected {
                    Icon("check", size: 14)
                        .foregroundStyle(theme.accentColor)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(hovering ? Tokens.hover : Color.clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(Tokens.Motion.easeFast, value: hovering)
    }
}

private struct CalibFooter: View {
    let saveDisabled: Bool
    let onClose: () -> Void
    let onSave: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Spacer()
            Button("Cancel", action: onClose)
                .appButton(.standard)
            Button("Save calibration", action: onSave)
                .appButton(.primary)
                // B4-4: disable save when derived or entered value is zero/negative
                .disabled(saveDisabled)
                .opacity(saveDisabled ? 0.5 : 1.0)
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 14)
        .background(Tokens.bgSunken)
        .overlay(
            Divider().frame(maxWidth: .infinity, maxHeight: 0.5), alignment: .top
        )
    }
}

// MARK: - OnboardingSheet

struct OnboardingSheet: View {
    let onClose: () -> Void

    @State private var step: Int = 0
    @State private var appeared = false

    @Environment(AppTheme.self) private var theme

    private let steps = OnboardingStep.all

    var body: some View {
        ZStack {
            Tokens.bgOverlay
                .background(.ultraThinMaterial)
                .ignoresSafeArea()
            // Backdrop tap does NOT dismiss onboarding (per prototype)

            VStack(spacing: 0) {
                ZStack(alignment: .topTrailing) {
                    OnboardHero(step: step, theme: theme)
                        .frame(height: 220)
                    Button(action: onClose) {
                        Icon("x", size: 13)
                            .foregroundStyle(.white.opacity(0.85))
                            .frame(width: 26, height: 26)
                            .background(
                                RoundedRectangle(cornerRadius: Tokens.Radius.md, style: .continuous)
                                    .fill(Color.black.opacity(0.30))
                            )
                    }
                    .buttonStyle(.plain)
                    .padding(10)
                }

                OnboardBody(
                    step: step,
                    totalSteps: steps.count,
                    title: steps[step].title,
                    desc: steps[step].desc,
                    onBack: step > 0 ? { withAnimation(Tokens.Motion.ease) { step -= 1 } } : nil,
                    onNext: {
                        if step == steps.count - 1 {
                            onClose()
                        } else {
                            withAnimation(Tokens.Motion.ease) { step += 1 }
                        }
                    },
                    isLast: step == steps.count - 1,
                    theme: theme
                )
            }
            .frame(width: 520)
            .background(Tokens.bg)
            .clipShape(RoundedRectangle(cornerRadius: Tokens.Radius.xl, style: .continuous))
            .shadow(color: .black.opacity(0.22), radius: 60, y: 24)
            .offset(y: appeared ? 0 : -12)
            .opacity(appeared ? 1 : 0)
            .scaleEffect(appeared ? 1 : 0.98)
        }
        .onAppear {
            withAnimation(Tokens.Motion.easeSlow) { appeared = true }
        }
        .keyboardShortcut(.cancelAction)
        // Enter — Next / Get started
        .onKeyPress(.return) {
            if step == steps.count - 1 {
                onClose()
            } else {
                withAnimation(Tokens.Motion.ease) { step += 1 }
            }
            return .handled
        }
    }
}

private struct OnboardingStep {
    let title: String
    let desc: String

    static let all: [OnboardingStep] = [
        .init(
            title: "Drop an image, get a count",
            desc: "Drag any microscope image onto CellCounter and Cellpose detects your cells in seconds — colored by size bin, counted in the sidebar, broken down in the histogram."
        ),
        .init(
            title: "Calibrate per objective",
            desc: "Tell CellCounter how many pixels equal a micrometer. Draw on a scale bar, pick a saved preset, or let it read the value straight from your image's EXIF metadata."
        ),
        .init(
            title: "Correct detections, improve your model",
            desc: "Add, remove, or merge cells directly on the image. Build a ground-truth set, get live Precision/Recall/F1 scores, and fine-tune a custom model on your own samples when built-ins fall short."
        ),
        .init(
            title: "Bin by size, export for publication",
            desc: "Set your own µm thresholds and cells are colored, counted, and charted by bin. Export an annotated PNG, a CSV, ImageJ ROIs, or a full PDF lab-journal report with a reproducibility stamp."
        ),
        .init(
            title: "Stays on your Mac",
            desc: "No cloud, no accounts, no telemetry. Every image, every measurement, every annotation, and every fine-tuned model lives entirely on this machine."
        ),
    ]
}

private struct OnboardHero: View {
    let step: Int
    let theme: AppTheme

    var body: some View {
        ZStack {
            // Background: radial accent gradient + bgSunken
            Tokens.bgSunken
            RadialGradient(
                gradient: Gradient(colors: [theme.accentSoft, .clear]),
                center: UnitPoint(x: 0.3, y: 0.4),
                startRadius: 0,
                endRadius: 200
            )

            // Step illustration
            Group {
                switch step {
                case 0: IlluCells(accentColor: theme.accentColor)
                case 1: IlluCalibrate(accentColor: theme.accentColor)
                case 2: IlluBins(accentColor: theme.accentColor)
                case 3: IlluTrain(accentColor: theme.accentColor)
                case 4: IlluLocal(accentColor: theme.accentColor, accentSoft: theme.accentSoft)
                default: EmptyView()
                }
            }
            .transition(.opacity.combined(with: .scale(scale: 0.96)))
        }
        .clipShape(Rectangle())
        .animation(Tokens.Motion.ease, value: step)
    }
}

// MARK: Step 0 — Scattered cells colored by bin

private struct IlluCells: View {
    let accentColor: Color

    private static let cells: [DetectedCell] = ProceduralCells.generate(count: 28, seed: 5, width: 400, height: 180, pxPerUm: 5.2)

    var body: some View {
        Canvas { ctx, size in
            let scaleX = size.width / 400
            let scaleY = size.height / 180
            for (i, cell) in Self.cells.enumerated() {
                let cx = CGFloat(cell.cx) * scaleX
                let cy = CGFloat(cell.cy) * scaleY
                let r  = CGFloat(cell.diameterPx) * min(scaleX, scaleY) / 2
                let binColor = Tokens.binColor(i % 5)
                let rect = CGRect(x: cx - r, y: cy - r, width: r * 2, height: r * 2)
                let ellipse = Path(ellipseIn: rect)
                ctx.fill(ellipse, with: .color(binColor.opacity(0.15)))
                ctx.stroke(ellipse, with: .color(binColor), style: StrokeStyle(lineWidth: 1.5))
            }
        }
        .frame(width: 400, height: 180)
    }
}

// MARK: Step 1 — Ruler with accent bar

private struct IlluCalibrate: View {
    let accentColor: Color

    var body: some View {
        Canvas { ctx, size in
            let midY: CGFloat = size.height * 0.5
            let x0: CGFloat = size.width * 0.125
            let x1: CGFloat = size.width * 0.875
            let tickCount = 11

            // Baseline
            var base = Path()
            base.move(to: CGPoint(x: x0, y: midY))
            base.addLine(to: CGPoint(x: x1, y: midY))
            ctx.stroke(base, with: .color(Tokens.textSecondary.opacity(0.7)), lineWidth: 1.5)

            // Ticks
            for t in 0..<tickCount {
                let tx = x0 + CGFloat(t) * (x1 - x0) / CGFloat(tickCount - 1)
                let isMid = t == tickCount / 2
                var tick = Path()
                tick.move(to: CGPoint(x: tx, y: midY - (isMid ? 14 : 8)))
                tick.addLine(to: CGPoint(x: tx, y: midY))
                ctx.stroke(tick, with: .color(Tokens.textSecondary.opacity(0.7)), lineWidth: isMid ? 1.5 : 1)
            }

            // Accent bar
            let barY = midY + 20
            let barX0 = x0
            let barX1 = x0 + (x1 - x0) * 0.42
            var bar = Path()
            bar.addRoundedRect(in: CGRect(x: barX0, y: barY, width: barX1 - barX0, height: 6), cornerSize: CGSize(width: 2, height: 2))
            ctx.fill(bar, with: .color(accentColor))

            // Label
            ctx.draw(
                Text("100 µm = 520 px")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(accentColor),
                at: CGPoint(x: (barX0 + barX1) / 2, y: barY + 20),
                anchor: .center
            )
        }
        .frame(width: 320, height: 140)
    }
}

// MARK: Step 2 — Ascending bin bars

private struct IlluBins: View {
    let accentColor: Color

    var body: some View {
        Canvas { ctx, size in
            let barCount = 5
            let barW: CGFloat = 36
            let spacing: CGFloat = 48
            let baseY: CGFloat = size.height * 0.78
            let totalW = CGFloat(barCount - 1) * spacing + barW
            let startX = (size.width - totalW) / 2

            for i in 0..<barCount {
                let barH: CGFloat = 18 + CGFloat(i) * 18
                let x = startX + CGFloat(i) * spacing
                var rect = Path()
                rect.addRoundedRect(in: CGRect(x: x, y: baseY - barH, width: barW, height: barH), cornerSize: CGSize(width: 3, height: 3))
                ctx.fill(rect, with: .color(Tokens.binColor(i)))
            }

            // Axis line
            var axis = Path()
            axis.move(to: CGPoint(x: startX - 4, y: baseY))
            axis.addLine(to: CGPoint(x: startX + totalW + 8, y: baseY))
            ctx.stroke(axis, with: .color(Tokens.textSecondary.opacity(0.6)), lineWidth: 1)

            // Label
            ctx.draw(
                Text("cell diameter →")
                    .font(.system(size: 10.5, design: .monospaced))
                    .foregroundStyle(Tokens.textTertiary),
                at: CGPoint(x: size.width / 2, y: baseY + 18),
                anchor: .center
            )
        }
        .frame(width: 320, height: 160)
    }
}

// MARK: Step 3 — Loss curves

private struct IlluTrain: View {
    let accentColor: Color

    var body: some View {
        Canvas { ctx, size in
            let x0: CGFloat = 28, y0: CGFloat = 24
            let x1: CGFloat = size.width - 28, y1: CGFloat = size.height - 30

            // Axis
            var axis = Path()
            axis.move(to: CGPoint(x: x0, y: y0))
            axis.addLine(to: CGPoint(x: x0, y: y1))
            axis.addLine(to: CGPoint(x: x1, y: y1))
            ctx.stroke(axis, with: .color(Tokens.textSecondary.opacity(0.5)), lineWidth: 0.8)

            // Accent (solid) loss curve — decaying from top-left
            var curve1 = Path()
            curve1.move(to: CGPoint(x: x0, y: y0 + 6))
            curve1.addCurve(
                to: CGPoint(x: x1, y: y1 - 8),
                control1: CGPoint(x: x0 + (x1-x0)*0.35, y: y0 + 30),
                control2: CGPoint(x: x0 + (x1-x0)*0.65, y: y1 - 24)
            )
            ctx.stroke(curve1, with: .color(accentColor), style: StrokeStyle(lineWidth: 2, lineCap: .round))

            // Bin3 (dashed) validation curve — slightly higher
            var curve2 = Path()
            curve2.move(to: CGPoint(x: x0, y: y0 + 14))
            curve2.addCurve(
                to: CGPoint(x: x1, y: y1 - 4),
                control1: CGPoint(x: x0 + (x1-x0)*0.35, y: y0 + 44),
                control2: CGPoint(x: x0 + (x1-x0)*0.65, y: y1 - 18)
            )
            ctx.stroke(curve2, with: .color(Tokens.bin3), style: StrokeStyle(lineWidth: 2, lineCap: .round, dash: [4, 4]))

            // "loss" label
            ctx.draw(
                Text("loss")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(Tokens.textTertiary),
                at: CGPoint(x: x0 - 4, y: y0),
                anchor: .bottomTrailing
            )
        }
        .frame(width: 300, height: 150)
    }
}

// MARK: Step 4 — Window outline + bars + check

private struct IlluLocal: View {
    let accentColor: Color
    let accentSoft: Color

    var body: some View {
        Canvas { ctx, size in
            let winX: CGFloat = size.width * 0.2
            let winY: CGFloat = size.height * 0.1
            let winW: CGFloat = size.width * 0.6
            let winH: CGFloat = size.height * 0.72

            // Window outline
            var win = Path()
            win.addRoundedRect(in: CGRect(x: winX, y: winY, width: winW, height: winH), cornerSize: CGSize(width: 10, height: 10))
            ctx.stroke(win, with: .color(Tokens.textSecondary.opacity(0.6)), lineWidth: 1.5)

            // Three accent bars inside
            let barOffsets: [CGFloat] = [0.28, 0.42, 0.56]
            let barWidths: [CGFloat] = [0.72, 0.54, 0.63]
            for (j, offY) in barOffsets.enumerated() {
                let bx = winX + winW * 0.1
                let by = winY + winH * offY
                let bw = winW * barWidths[j]
                var barPath = Path()
                barPath.addRoundedRect(in: CGRect(x: bx, y: by, width: bw, height: 6), cornerSize: CGSize(width: 3, height: 3))
                ctx.fill(barPath, with: .color(accentColor.opacity(0.4)))
            }

            // Accent circle with checkmark at bottom center
            let cx = size.width / 2
            let cy = winY + winH + 22
            let cr: CGFloat = 14
            ctx.fill(Path(ellipseIn: CGRect(x: cx - cr, y: cy - cr, width: cr*2, height: cr*2)), with: .color(accentSoft))

            var check = Path()
            check.move(to: CGPoint(x: cx - 5.5, y: cy))
            check.addLine(to: CGPoint(x: cx - 1.5, y: cy + 4))
            check.addLine(to: CGPoint(x: cx + 6, y: cy - 5))
            ctx.stroke(check, with: .color(accentColor), style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
        }
        .frame(width: 280, height: 160)
    }
}

// MARK: Onboarding body + actions

private struct OnboardBody: View {
    let step: Int
    let totalSteps: Int
    let title: String
    let desc: String
    let onBack: (() -> Void)?
    let onNext: () -> Void
    let isLast: Bool
    let theme: AppTheme

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(title)
                .font(.system(size: 22, weight: .bold))
                .tracking(-0.02 * 22)
                .foregroundStyle(Tokens.text)
                .padding(.bottom, 6)

            Text(desc)
                .font(.system(size: 13.5))
                .foregroundStyle(Tokens.textSecondary)
                .lineSpacing((1.55 - 1.0) * 13.5)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.bottom, 18)

            HStack(spacing: 8) {
                // Pagination dots
                HStack(spacing: 5) {
                    ForEach(0..<totalSteps, id: \.self) { j in
                        Circle()
                            .fill(j == step ? theme.accentColor : Tokens.borderStrong)
                            .frame(width: 7, height: 7)
                            .animation(Tokens.Motion.easeFast, value: step)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                if let back = onBack {
                    Button("Back", action: back).appButton(.standard)
                }

                Button(action: onNext) {
                    HStack(spacing: 6) {
                        Text(isLast ? "Get started" : "Next")
                        if !isLast { Icon("arrow", size: 12) }
                    }
                }
                .appButton(.primary)
            }
        }
        .padding(.horizontal, 28)
        .padding(.vertical, 22)
        .padding(.bottom, 2)
    }
}
