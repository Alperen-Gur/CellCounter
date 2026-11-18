import SwiftUI

// MARK: - CalibrationSheet

/// Sets a pixel scale. From Home it sets the user's default for images
/// without a scale. From Results/Batch it applies to the open batch: by
/// default only to images without a scale of their own; replacing a scale
/// recorded in a file needs the explicit "Override the file's scale" choice.
/// When analysed images change scale and their model used the scale to
/// segment, the sheet asks whether to segment them again or only rescale.
struct CalibrationSheet: View {
    let current: Double
    let onClose: () -> Void
    /// Home: saves the user's default for images without a scale.
    let onSave: (Double, String) -> Void
    /// Bug #11: optional URL of the currently-open image for "Draw on scale bar" tab.
    var imageURL: URL? = nil
    /// False on Home: saving changes only the default for future imports.
    /// True from Results/Batch: the value applies to the open batch's images.
    var appliesToOpenBatch: Bool = false
    /// Lets the "Preset" tab list the user's presets and "Save as preset"
    /// store new ones. Nil-safe: without it, presets are not offered.
    var repos: Repositories? = nil
    /// The open batch's images and scales, read once when the sheet opens.
    var loadContext: (() -> ScaleChange.Context?)? = nil
    /// Applies a change to the open batch; `true` segments again the analysed
    /// images whose outlines depend on the scale.
    var onApply: ((ScaleChange.Plan, Bool) -> Void)? = nil

    enum CalibTab { case metadata, direct, drawline, preset }
    enum Scope: Hashable { case withoutScale, thisImage }

    @State private var tab: CalibTab
    @State private var val: Double
    /// Measured scale-bar length in image pixels. Starts at 0 ("nothing measured
    /// yet") so the drawline tab can't Save a stale value before the user draws.
    @State private var lineLength: Double = 0
    @State private var refUm: Double = 100
    @State private var selectedPreset: String = ""
    @State private var appeared = false
    @State private var metadataResult: EXIFCalibration.Result? = nil
    @State private var metadataCheckComplete = false
    @State private var context: ScaleChange.Context? = nil
    @State private var scope: Scope = .withoutScale
    @State private var overrideFiles = false
    /// Set while asking whether to segment analysed images again.
    @State private var pendingPlan: ScaleChange.Plan? = nil

    @Environment(AppTheme.self) private var theme

    init(current: Double,
         imageURL: URL? = nil,
         appliesToOpenBatch: Bool = false,
         repos: Repositories? = nil,
         loadContext: (() -> ScaleChange.Context?)? = nil,
         onApply: ((ScaleChange.Plan, Bool) -> Void)? = nil,
         onClose: @escaping () -> Void,
         onSave: @escaping (Double, String) -> Void) {
        self.current = current
        self.imageURL = imageURL
        self.appliesToOpenBatch = appliesToOpenBatch
        self.repos = repos
        self.loadContext = loadContext
        self.onApply = onApply
        self.onClose = onClose
        self.onSave = onSave
        // No made-up starting value: an unset scale starts empty.
        self._val = State(initialValue: current > 0 ? current : 0)
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
                CalibHeader(theme: theme,
                            appliesToOpenBatch: appliesToOpenBatch,
                            onClose: onClose)
                    .padding(.horizontal, 24)
                    .padding(.top, 20)
                    .padding(.bottom, 0)

                CalibTabBar(tab: $tab)
                    .padding(.horizontal, 24)
                    .padding(.top, 16)
                    .padding(.bottom, 18)

                Group {
                    switch tab {
                    case .metadata:
                        CalibMetadataTab(result: metadataResult,
                                         checkComplete: metadataCheckComplete)
                            .padding(.horizontal, 24)
                            .padding(.bottom, 22)
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

                if let repos, tab == .direct || tab == .drawline, saveValue > 0, pendingPlan == nil {
                    CalibSavePresetRow(value: saveValue, repos: repos)
                        .padding(.horizontal, 24)
                        .padding(.bottom, 16)
                }

                if batchMode, let context, pendingPlan == nil {
                    CalibScopeSection(context: context, value: saveValue,
                                      usesOwnFileScale: usesOwnFileScale,
                                      scope: $scope, overrideFiles: $overrideFiles)
                        .padding(.horizontal, 24)
                        .padding(.bottom, 18)
                }

                if let plan = pendingPlan, let context {
                    CalibResegmentChoice(plan: plan, context: context,
                                         onRerun: { apply(plan, resegment: true) },
                                         onRescale: { apply(plan, resegment: false) },
                                         onBack: { withAnimation(Tokens.Motion.ease) { pendingPlan = nil } })
                } else {
                    CalibFooter(saveTitle: batchMode ? "Apply" : "Save as default",
                                saveDisabled: saveDisabled,
                                onClose: onClose,
                                onSave: save)
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
            if appliesToOpenBatch { context = loadContext?() }
            detectMetadata()
        }
        .keyboardShortcut(.cancelAction)
        // Enter — save when valid
        .onKeyPress(.return) {
            guard pendingPlan == nil, !saveDisabled else { return .ignored }
            save()
            return .handled
        }
        .onChange(of: tab) { _, newTab in
            if newTab == .drawline { val = derivedVal }
            if newTab == .metadata, let metadataResult { val = metadataResult.pxPerUm }
        }
        .onChange(of: lineLength) { _, _ in
            if tab == .drawline { val = derivedVal }
        }
        .onChange(of: refUm) { _, _ in
            if tab == .drawline { val = derivedVal }
        }
    }

    private var provenanceSource: String {
        switch tab {
        case .metadata: return metadataResult?.source.provenanceKey ?? "metadata"
        case .direct: return ImageScale.typedSource
        case .drawline: return ImageScale.scaleBarSource
        case .preset: return ImageScale.presetSource(selectedPreset)
        }
    }

    /// The value the open tab would save.
    private var saveValue: Double {
        switch tab {
        case .metadata: return metadataResult?.pxPerUm ?? 0
        case .direct: return val
        case .drawline: return derivedVal
        case .preset: return selectedPreset.isEmpty ? 0 : val
        }
    }

    /// Applying to the open batch's images (Results/Batch).
    private var batchMode: Bool { appliesToOpenBatch && context != nil && onApply != nil }

    private var currentImage: ScaleChange.ImageState? { context?.currentImage }

    /// The open image goes back to its own file's scale.
    private var usesOwnFileScale: Bool {
        tab == .metadata && scope == .thisImage && currentImage?.file != nil
    }

    private var request: ScaleChange.Request? {
        guard batchMode, saveValue > 0 else { return nil }
        var source = provenanceSource
        // Another image's file value used for images without a scale is
        // recorded as such, not as "from file".
        if tab == .metadata, scope == .withoutScale, let name = currentImage?.fileName {
            source = ImageScale.otherFilePrefix + name
        }
        let target: ScaleChange.Scope
        switch scope {
        case .withoutScale:
            target = .imagesWithoutOwnScale
        case .thisImage:
            guard let id = context?.currentImageId else { return nil }
            target = .image(id)
        }
        return ScaleChange.Request(value: ImageScale.Value(pxPerUm: saveValue, source: source), scope: target,
                                   overrideFiles: overrideFiles, useFileScale: usesOwnFileScale)
    }

    private var saveDisabled: Bool {
        // B4-4: never a zero/negative px/µm (divide-by-zero downstream).
        guard saveValue > 0 else { return true }
        guard batchMode else { return false }
        if scope == .thisImage {
            guard let image = currentImage else { return true }
            // A file's scale is replaced only by an explicit override.
            if image.file != nil, !usesOwnFileScale, !overrideFiles { return true }
        }
        return false
    }

    private func save() {
        guard !saveDisabled else { return }
        guard batchMode, let request, let context else {
            onSave(saveValue, provenanceSource)
            onClose()
            return
        }
        let plan = ScaleChange.plan(request, context: context)
        guard !plan.isEmpty else { onClose(); return }
        if plan.offersResegmentation {
            withAnimation(Tokens.Motion.ease) { pendingPlan = plan }
            return
        }
        apply(plan, resegment: false)
    }

    private func apply(_ plan: ScaleChange.Plan, resegment: Bool) {
        onApply?(plan, resegment)
        onClose()
    }

    private func detectMetadata() {
        guard let imageURL else {
            metadataCheckComplete = true
            return
        }
        Task {
            let result = await Task.detached(priority: .utility) {
                EXIFCalibration.detectPxPerUm(at: imageURL)
            }.value
            metadataResult = result
            metadataCheckComplete = true
            if let result {
                val = result.pxPerUm
                tab = .metadata
            }
        }
    }
}

private struct CalibHeader: View {
    let theme: AppTheme
    let appliesToOpenBatch: Bool
    let onClose: () -> Void

    var body: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Pixel scale")
                    .font(.system(size: 18, weight: .bold))
                    .tracking(-0.01 * 18)
                    .foregroundStyle(Tokens.text)
                Text(appliesToOpenBatch
                     ? "Each image has its own scale. A scale in an image's file is used unless you override it."
                     : "Your default for images without a scale in their file. Images whose file has a scale keep it; analysed batches stay unchanged.")
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
            CalibTabItem(label: "Metadata", active: tab == .metadata) { tab = .metadata }
            CalibTabItem(label: "Pixel size", active: tab == .direct) { tab = .direct }
            CalibTabItem(label: "Scale bar", active: tab == .drawline) { tab = .drawline }
            CalibTabItem(label: "Preset", active: tab == .preset) { tab = .preset }
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

private struct CalibMetadataTab: View {
    let result: EXIFCalibration.Result?
    let checkComplete: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let result {
                HStack(alignment: .top, spacing: 12) {
                    Image(systemName: "checkmark.seal.fill")
                        .font(.system(size: 22))
                        .foregroundStyle(Tokens.success)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Physical pixel size found")
                            .font(.system(size: 13.5, weight: .semibold))
                            .foregroundStyle(Tokens.text)
                        Text("Read from \(result.source.description) · \(confidenceLabel(result.confidence)) confidence")
                            .font(.system(size: 11.5))
                            .foregroundStyle(Tokens.textTertiary)
                    }
                }
                HStack(spacing: 10) {
                    CalibrationValueCard(value: String(format: "%.5g", 1 / result.pxPerUm), unit: "µm / pixel")
                    Image(systemName: "arrow.left.arrow.right")
                        .foregroundStyle(Tokens.textTertiary)
                    CalibrationValueCard(value: String(format: "%.5g", result.pxPerUm), unit: "px / µm")
                }
                Text("No manual conversion is needed. Saving applies this exact scale and records its source in exports.")
                    .font(.system(size: 11.5))
                    .foregroundStyle(Tokens.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            } else if !checkComplete {
                HStack(spacing: 10) {
                    ProgressView().controlSize(.small)
                    Text("Reading microscope metadata…")
                        .font(.system(size: 12.5))
                        .foregroundStyle(Tokens.textSecondary)
                }
                .frame(maxWidth: .infinity, minHeight: 110)
            } else {
                HStack(alignment: .top, spacing: 12) {
                    Image(systemName: "info.circle")
                        .font(.system(size: 20))
                        .foregroundStyle(Tokens.textTertiary)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("No physical scale in this file")
                            .font(.system(size: 13.5, weight: .semibold))
                            .foregroundStyle(Tokens.text)
                        Text("Use Pixel size if the acquisition software reports µm/pixel, or Scale bar to measure a burnt-in reference precisely.")
                            .font(.system(size: 11.5))
                            .foregroundStyle(Tokens.textTertiary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .frame(maxWidth: .infinity, minHeight: 110, alignment: .topLeading)
            }
        }
    }

    private func confidenceLabel(_ confidence: EXIFCalibration.Confidence) -> String {
        switch confidence {
        case .high: return "high"
        case .medium: return "medium"
        case .low: return "low"
        }
    }
}

private struct CalibrationValueCard: View {
    let value: String
    let unit: String
    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(value)
                .font(.system(size: 17, weight: .semibold, design: .monospaced))
                .foregroundStyle(Tokens.text)
            Text(unit)
                .font(.system(size: 10.5))
                .foregroundStyle(Tokens.textTertiary)
        }
        .padding(.horizontal, 12).padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: Tokens.Radius.md).fill(Tokens.bgSunken))
    }
}

private struct CalibDirectTab: View {
    @Binding var val: Double
    @State private var unit: Unit = .micronsPerPixel

    private enum Unit: String, CaseIterable {
        case micronsPerPixel, pixelsPerMicron
        var label: String { self == .micronsPerPixel ? "µm / pixel" : "px / µm" }
    }

    private var displayedValue: Binding<Double> {
        Binding(
            get: {
                guard val > 0 else { return 0 }
                return unit == .micronsPerPixel ? 1 / val : val
            },
            set: { entered in
                guard entered > 0 else { val = 0; return }
                val = unit == .micronsPerPixel ? 1 / entered : entered
            })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Picker("Unit", selection: $unit) {
                ForEach(Unit.allCases, id: \.self) { Text($0.label).tag($0) }
            }
            .pickerStyle(.segmented)
            CalibInputBox(value: displayedValue, unit: unit.label)
            if val > 0 {
                Text(String(format: "Converted automatically: %.5g px / µm · %.5g µm / pixel", val, 1 / val))
                    .font(.system(size: 11.5, design: .monospaced))
                    .foregroundStyle(Tokens.textSecondary)
            }
            Text("Acquisition software usually reports physical pixel size in µm/pixel. Enter that number directly—Cellographer handles the reciprocal conversion.")
                .font(.system(size: 11.5))
                .foregroundStyle(Tokens.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
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
    @State private var loadedImage: NSImage? = nil
    @State private var sourcePixelSize: CGSize = .zero
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
                Text(derivedVal > 0 ? "\(ImageScale.format(derivedVal)) px / µm" : "— px / µm")
                    .font(.system(size: 12.5, weight: .semibold, design: .monospaced))
                    .foregroundStyle(derivedVal > 0 ? Tokens.text : Tokens.textTertiary)
                Spacer(minLength: 0)
            }
        }
        .task(id: imageURL) { await loadPreview() }
    }

    /// Apply the horizontal-snap constraint to a drag end point.
    private func snappedEnd(from start: CGPoint, to end: CGPoint) -> CGPoint {
        snapHorizontal ? CGPoint(x: end.x, y: start.y) : end
    }

    // MARK: - Preview area

    @ViewBuilder
    private var previewArea: some View {
        if imageURL != nil, let nsImage = loadedImage {
            // Real image: show it aspect-fitted and let the user drag a line on it
            GeometryReader { geo in
                ZStack {
                    Image(nsImage: nsImage)
                        .resizable()
                        .aspectRatio(sourcePixelSize, contentMode: .fit)
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
                            updateLineLengthFromPoints(s, e, in: geo.size)
                        }
                        .onEnded { v in
                            let s = v.startLocation
                            let e = snappedEnd(from: s, to: v.location)
                            lineStart = s
                            lineEnd = e
                            isDragging = false
                            updateLineLengthFromPoints(s, e, in: geo.size)
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
                } else {
                    ProgressView().controlSize(.small)
                }
            }
        }
    }

    /// Convert view-space points to image-pixel distances and update lineLength.
    private func updateLineLengthFromPoints(_ a: CGPoint, _ b: CGPoint, in viewSize: CGSize) {
        // Aspect-fit conversion shared with the cell-size measurement in
        // Analysis setup.
        guard let pixelDist = LineMeasurement.imagePixelLength(
            from: a, to: b, viewSize: viewSize, imageSize: sourcePixelSize) else { return }
        if pixelDist > 1 {
            lineLength = pixelDist
        }
    }

    private func loadPreview() async {
        guard let imageURL else {
            loadedImage = nil
            sourcePixelSize = .zero
            return
        }
        let result = await Task.detached(priority: .utility) {
            (ImageLoader.cachedReviewPreview(at: imageURL, maxPixelSize: 1800),
             ImageLoader.pixelSize(at: imageURL))
        }.value
        guard !Task.isCancelled else { return }
        loadedImage = result.0
        sourcePixelSize = result.1 ?? result.0?.size ?? .zero
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

    /// The user's presets, fetched from SwiftData on appear and after each
    /// inline-create. CellCounter ships none.
    @State private var userPresets: [CalibrationPresetRecord] = []
    @State private var addingNew: Bool = false
    @State private var newPresetName: String = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if userPresets.isEmpty {
                // Presets are the user's own: CellCounter ships none, since a
                // px/µm value is only right for the microscope it was measured on.
                Text("No saved presets yet. Measure a scale bar or type a value, then choose “Save as preset” and name it after your microscope and objective (for example “Nikon Ts2 · 10×”).")
                    .font(.system(size: 12))
                    .foregroundStyle(Tokens.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(14)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Tokens.bgSunken)
                    .clipShape(RoundedRectangle(cornerRadius: Tokens.Radius.md, style: .continuous))
            } else {
                VStack(spacing: 0) {
                    // SwiftData is the single source of truth for presets:
                    // Settings → Calibration presets and "Save as preset" write here.
                    ForEach(Array(userPresets.enumerated()), id: \.element.id) { idx, preset in
                        PresetRow(name: preset.name,
                                  pxPerUm: preset.pxPerUm,
                                  selected: selectedPreset == preset.name,
                                  theme: theme,
                                  note: CalibrationPreset.wasShipped(name: preset.name, pxPerUm: preset.pxPerUm)
                                      ? CalibrationPreset.shippedNote : nil,
                                  onTap: { onSelect(preset.name, preset.pxPerUm) },
                                  onDelete: repos.map { r in
                                      { r.deleteCalibrationPreset(preset); refresh() }
                                  })
                        if idx < userPresets.count - 1 {
                            Divider().padding(.horizontal, 14)
                        }
                    }
                }
                .background(Tokens.bgSunken)
                .clipShape(RoundedRectangle(cornerRadius: Tokens.Radius.md, style: .continuous))
            }

            // Inline "Save current value as preset" affordance — only offered
            // when a repo was wired up.
            if repos != nil {
                if addingNew {
                    HStack(spacing: 8) {
                        TextField("Preset name (e.g. \"Nikon Ts2 · 10×\")", text: $newPresetName)
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
    /// A warning shown under the value (presets older versions shipped).
    var note: String? = nil
    let onTap: () -> Void
    /// nil when there is no repository to delete from.
    let onDelete: (() -> Void)?

    @State private var hovering = false

    var body: some View {
        Button(action: onTap) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(name)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(Tokens.text)
                    Text("\(ImageScale.format(pxPerUm)) px / µm")
                        .font(.system(size: 11.5, design: .monospaced))
                        .foregroundStyle(Tokens.textTertiary)
                    if let note {
                        Text(note)
                            .font(.system(size: 11))
                            .foregroundStyle(Tokens.warning)
                            .fixedSize(horizontal: false, vertical: true)
                    }
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
    var saveTitle: String = "Save"
    let saveDisabled: Bool
    let onClose: () -> Void
    let onSave: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Spacer()
            Button("Cancel", action: onClose)
                .appButton(.standard)
            Button(saveTitle, action: onSave)
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

/// Which images of the open batch a value applies to. By default only images
/// without a scale of their own; a file's scale is replaced only when the
/// user ticks "Override the file's scale", which says what that does.
private struct CalibScopeSection: View {
    let context: ScaleChange.Context
    let value: Double
    let usesOwnFileScale: Bool
    @Binding var scope: CalibrationSheet.Scope
    @Binding var overrideFiles: Bool

    private var currentImage: ScaleChange.ImageState? { context.currentImage }

    /// Images whose file's scale this choice would replace.
    private var overridable: [ScaleChange.ImageState] {
        switch scope {
        case .withoutScale: return context.fileScaled
        case .thisImage:
            guard !usesOwnFileScale, let image = currentImage, image.file != nil else { return [] }
            return [image]
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Apply to")
                .font(.system(size: 11))
                .foregroundStyle(Tokens.textTertiary)
            Picker("Apply to", selection: $scope) {
                Text("Images without a scale (\(context.withoutOwnScaleCount))").tag(CalibrationSheet.Scope.withoutScale)
                if currentImage != nil {
                    Text("Only this image").tag(CalibrationSheet.Scope.thisImage)
                }
            }
            .pickerStyle(.radioGroup)
            .labelsHidden()
            .font(.system(size: 12.5))

            if scope == .withoutScale, context.withoutOwnScaleCount == 0, overridable.isEmpty == false, !overrideFiles {
                Text("Every image in this batch has a scale from its file, so this changes nothing unless you override the file's scale.")
                    .font(.system(size: 11.5))
                    .foregroundStyle(Tokens.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if usesOwnFileScale {
                Text("This image goes back to the scale recorded in its file.")
                    .font(.system(size: 11.5))
                    .foregroundStyle(Tokens.textTertiary)
            }
            if !overridable.isEmpty {
                Toggle(isOn: $overrideFiles) {
                    Text(overridable.count == 1 && scope == .thisImage
                         ? "Override the file's scale for this image"
                         : "Override the file's scale for \(ImageScale.countText(overridable.count))")
                        .font(.system(size: 12.5))
                }
                .toggleStyle(.checkbox)
                if overrideFiles, value > 0 {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Your value: \(ImageScale.format(value)) px/µm")
                        ForEach(ImageScale.overrideLines(yours: value, files: overridable.compactMap { $0.file?.pxPerUm }),
                                id: \.self) { line in
                            Text(line)
                        }
                        Text("Recorded as “manual override (file: … px/µm)”. Use this only if you know the file's scale is wrong.")
                            .foregroundStyle(Tokens.textTertiary)
                    }
                    .font(.system(size: 11.5))
                    .foregroundStyle(Tokens.warning)
                    .fixedSize(horizontal: false, vertical: true)
                } else if scope == .thisImage {
                    Text("This image's file records \(ImageScale.format(currentImage?.file?.pxPerUm ?? 0)) px/µm. Choose the Metadata tab to use it, or override it here.")
                        .font(.system(size: 11.5))
                        .foregroundStyle(Tokens.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .onChange(of: scope) { _, _ in overrideFiles = false }
    }
}

/// "Save as preset" after a scale-bar measurement or a typed value. Presets
/// are named by the user after their own microscope and objective.
private struct CalibSavePresetRow: View {
    let value: Double
    let repos: Repositories
    @State private var name = ""
    @State private var saved: String? = nil

    var body: some View {
        HStack(spacing: 8) {
            TextField("Save as preset, e.g. Nikon Ts2 · 10×", text: $name)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 12.5))
                .onSubmit(save)
            Button("Save as preset", action: save)
                .appButton(.standard, size: .sm)
                .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty || value <= 0)
            if let saved {
                Text("Saved “\(saved)”")
                    .font(.system(size: 11.5))
                    .foregroundStyle(Tokens.textTertiary)
                    .lineLimit(1)
            }
        }
    }

    private func save() {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, value > 0 else { return }
        repos.upsertCalibrationPreset(CalibrationPresetRecord(name: trimmed, pxPerUm: value))
        saved = trimmed
        name = ""
    }
}

/// Asked when analysed images change scale and their model used the scale to
/// decide how large a cell is in pixels.
private struct CalibResegmentChoice: View {
    let plan: ScaleChange.Plan
    let context: ScaleChange.Context
    let onRerun: () -> Void
    let onRescale: () -> Void
    let onBack: () -> Void

    private var example: (old: Double, new: Double)? {
        guard let id = plan.resegment.first,
              let old = context.images.first(where: { $0.id == id })?.measured?.pxPerUm,
              let new = plan.changed[id]?.pxPerUm else { return nil }
        return (old, new)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("\(ImageScale.countText(plan.changed.count)) already analysed change scale")
                .font(.system(size: 13.5, weight: .semibold))
                .foregroundStyle(Tokens.text)
            Text("The model was told the cell size in pixels from the old scale, so it looked for cells of the wrong size. Segmenting again at the new scale gives outlines that match it.")
            if let example {
                Text("Only rescaling keeps the outlines and converts their sizes. Those results are then marked “segmented at \(ImageScale.format(example.old)) px/µm, measured at \(ImageScale.format(example.new)) px/µm”.")
            }
            if plan.changed.count > plan.resegment.count {
                Text("\(ImageScale.countText(plan.changed.count - plan.resegment.count)) used a model that does not depend on the scale; their sizes are converted either way.")
            }
            HStack(spacing: 8) {
                Button("Back", action: onBack)
                    .appButton(.ghost)
                Spacer()
                Button("Only rescale sizes", action: onRescale)
                    .appButton(.standard)
                Button("Re-run segmentation for \(ImageScale.countText(plan.resegment.count)) (recommended)", action: onRerun)
                    .appButton(.primary)
            }
            .padding(.top, 4)
        }
        .font(.system(size: 12))
        .foregroundStyle(Tokens.textSecondary)
        .fixedSize(horizontal: false, vertical: true)
        .padding(.horizontal, 24)
        .padding(.vertical, 16)
        .background(Tokens.bgSunken)
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
            title: "Inspect, preview, then count",
            desc: "Import microscope images, check calibration and channels on a representative image, then preview the masks before processing your batch. You can inspect images before installing a detector."
        ),
        .init(
            title: "Every image has its own scale",
            desc: "Cellographer needs to know how many pixels make a micrometer (px/µm). Each image uses the scale recorded in its own file, so a folder can mix objectives. For images without one, draw a line on the scale bar or type px/µm, and save it as a preset named after your microscope and objective. Every size in µm, and the scaling used for segmentation, depends on it."
        ),
        .init(
            title: "Set the expected cell size",
            desc: "Before segmentation, images are scaled so a cell of this diameter matches the size the model was trained on, which changes both speed and results. Automatic uses the midpoint of your size classes; for best results, set it close to the typical diameter of your cells or measure one on the preview in Analysis setup."
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
                case 2: IlluCellSize(accentColor: theme.accentColor)
                case 3: IlluBins(accentColor: theme.accentColor)
                case 4: IlluTrain(accentColor: theme.accentColor)
                case 5: IlluLocal(accentColor: theme.accentColor, accentSoft: theme.accentSoft)
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

// MARK: Step 2 — A cell measured across its diameter

private struct IlluCellSize: View {
    let accentColor: Color

    var body: some View {
        Canvas { ctx, size in
            let midY = size.height * 0.45
            let neighbours: [(x: CGFloat, r: CGFloat)] = [(0.2, 20), (0.8, 24)]
            for cell in neighbours {
                let rect = CGRect(x: size.width * cell.x - cell.r, y: midY - cell.r, width: cell.r * 2, height: cell.r * 2)
                ctx.stroke(Path(ellipseIn: rect), with: .color(Tokens.textSecondary.opacity(0.6)), lineWidth: 1.5)
            }
            let r: CGFloat = 38
            let center = CGPoint(x: size.width * 0.5, y: midY)
            let rect = CGRect(x: center.x - r, y: center.y - r, width: r * 2, height: r * 2)
            ctx.fill(Path(ellipseIn: rect), with: .color(accentColor.opacity(0.15)))
            ctx.stroke(Path(ellipseIn: rect), with: .color(accentColor), lineWidth: 1.5)
            var line = Path()
            line.move(to: CGPoint(x: center.x - r, y: center.y))
            line.addLine(to: CGPoint(x: center.x + r, y: center.y))
            ctx.stroke(line, with: .color(accentColor), style: StrokeStyle(lineWidth: 2, lineCap: .round))
            for x in [center.x - r, center.x + r] {
                ctx.fill(Path(ellipseIn: CGRect(x: x - 3, y: center.y - 3, width: 6, height: 6)), with: .color(accentColor))
            }
            ctx.draw(
                Text("25 µm ≈ 65 px")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(accentColor),
                at: CGPoint(x: center.x, y: center.y + r + 18),
                anchor: .center
            )
        }
        .frame(width: 320, height: 140)
    }
}

// MARK: Step 3 — Ascending bin bars

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

// MARK: Step 4 — Loss curves

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

// MARK: Step 5 — Window outline + bars + check

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
