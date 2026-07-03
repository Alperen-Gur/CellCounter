import SwiftUI

// MARK: — Demo banner

/// Persistent banner shown on every Fine-tune step. The wizard runs on
/// procedurally-generated synthetic data and (when no sidecar is installed)
/// simulated training, so every panel here is an illustrative preview — NOT
/// real training on the user's dataset. This makes that unmistakable.
struct FTDemoBanner: View {
    var message: String = "Preview only — this is an illustrative demo on synthetic data. The images, annotations, and metrics shown here are not from your dataset and are not real training results."

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Icon("triangle-alert", size: 13)
                .foregroundStyle(Tokens.warning)
                .padding(.top, 1)
            Text(message)
                .font(.system(size: 12))
                .foregroundStyle(Tokens.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: Tokens.Radius.md, style: .continuous)
                .fill(Tokens.warning.opacity(0.12))
        )
        .overlay(
            RoundedRectangle(cornerRadius: Tokens.Radius.md, style: .continuous)
                .strokeBorder(Tokens.warning.opacity(0.35), lineWidth: 0.5)
        )
        .padding(.bottom, 16)
    }
}

// MARK: — STEP 0: Dataset

struct StepDataset: View {
    @Bindable var state: AppState
    @Binding var imageCount: Int
    @Binding var annotated: Int
    @Binding var datasetURLs: [URL]
    var onNext: () -> Void
    @Environment(AppTheme.self) private var theme
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            FTCard {
                VStack(alignment: .leading, spacing: 0) {
                    FTSectionTitle(
                        title: "Bring your images",
                        desc: "Drop a folder of microscope images or pick from your library. ~50 images is enough for a useful fine-tune; 200+ for a robust one."
                    )

                    HStack(spacing: 12) {
                        FTDropZoneTile(
                            iconName: "folderup",
                            title: "Drop folder",
                            sub: "JPEG, PNG, TIFF, BMP",
                            buttonLabel: "Choose folder…",
                            buttonIcon: "folder",
                            primary: true
                        ) {
                            chooseFolder()
                        }
                        FTDropZoneTile(
                            iconName: "library",
                            title: "From library",
                            sub: "Use your processed batches",
                            buttonLabel: "Pick from library…",
                            buttonIcon: "image",
                            primary: false
                        ) {
                            pickFromLibrary()
                        }
                    }
                    .padding(.bottom, 18)

                    if imageCount > 0 {
                        HStack(spacing: 12) {
                            Image(systemName: "checkmark")
                                .font(.system(size: 14, weight: .semibold))
                                .foregroundStyle(theme.accentColor)
                            VStack(alignment: .leading, spacing: 2) {
                                Text("\(imageCount) images loaded")
                                    .font(.system(size: 13, weight: .semibold))
                                    .foregroundStyle(Tokens.text)
                                Text("\(annotated) have existing annotations · \(imageCount - annotated) need labeling")
                                    .font(.system(size: 12))
                                    .foregroundStyle(Tokens.textTertiary)
                            }
                            Spacer()
                            Button {
                                imageCount = 0
                                annotated = 0
                                datasetURLs = []
                            } label: {
                                HStack(spacing: 4) {
                                    Icon("x", size: 11)
                                    Text("Clear")
                                }
                            }
                            .appButton(.ghost, size: .sm)
                        }
                        .padding(14)
                        .background(
                            RoundedRectangle(cornerRadius: Tokens.Radius.lg, style: .continuous)
                                .fill(theme.accentSofterAdaptive(for: scheme))
                        )
                        .padding(.bottom, 18)
                    }
                }
            }
            FTFooterBar(onNext: onNext, nextDisabled: imageCount == 0)
        }
    }

    private func chooseFolder() {
        presentOpenPanel(allowedExtensions: Array(ImageLoader.supported),
                         allowFolders: true,
                         allowMultiple: false) { urls in
            Task { @MainActor in
                let collected = recursivelyCollect(urls)
                datasetURLs = collected
                imageCount = collected.count
                annotated = 0
            }
        }
    }

    private func pickFromLibrary() {
        let batches = state.repos.allBatches()
        var urls: [URL] = []
        var labeled = 0
        for b in batches {
            for img in b.images {
                urls.append(img.storedURL)
                if let det = img.detection, !det.cells.isEmpty { labeled += 1 }
            }
        }
        datasetURLs = urls
        imageCount = urls.count
        annotated = labeled
    }

    private func recursivelyCollect(_ urls: [URL]) -> [URL] {
        var out: [URL] = []
        let fm = FileManager.default
        for url in urls {
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: url.path, isDirectory: &isDir) else { continue }
            if isDir.boolValue {
                if let walker = fm.enumerator(at: url,
                                               includingPropertiesForKeys: [.isRegularFileKey],
                                               options: [.skipsHiddenFiles]) {
                    for case let child as URL in walker {
                        if ImageLoader.supported.contains(child.pathExtension.lowercased()) {
                            out.append(child)
                        }
                    }
                }
            } else if ImageLoader.supported.contains(url.pathExtension.lowercased()) {
                out.append(url)
            }
        }
        return out
    }
}

private struct FTDropZoneTile: View {
    let iconName: String
    let title: String
    let sub: String
    let buttonLabel: String
    let buttonIcon: String
    let primary: Bool
    let action: () -> Void

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: Tokens.Radius.lg, style: .continuous)
                .fill(Tokens.bgSunken)
            RoundedRectangle(cornerRadius: Tokens.Radius.lg, style: .continuous)
                .strokeBorder(
                    Tokens.borderStrong,
                    style: StrokeStyle(lineWidth: 1, dash: [5, 4])
                )
            VStack(spacing: 0) {
                Icon(iconName, size: 32)
                    .foregroundStyle(Tokens.textTertiary)
                    .padding(.bottom, 10)
                Text(title)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Tokens.text)
                Text(sub)
                    .font(.system(size: 12))
                    .foregroundStyle(Tokens.textTertiary)
                    .padding(.top, 4)
                Button(action: action) {
                    HStack(spacing: 6) {
                        Icon(buttonIcon, size: 12)
                        Text(buttonLabel)
                    }
                }
                .appButton(primary ? .primary : .standard, size: .md)
                .padding(.top, 14)
            }
            .padding(24)
        }
        .frame(minHeight: 180)
        .frame(maxWidth: .infinity)
    }
}

// MARK: — STEP 1: Annotate

struct StepAnnotate: View {
    @Bindable var state: AppState
    let imageCount: Int
    @Binding var annotated: Int
    var onNext: () -> Void
    var onBack: () -> Void

    @Environment(AppTheme.self) private var theme
    @Environment(\.colorScheme) private var scheme

    private let initialCells: [DetectedCell]
    @State private var liveCells: [DetectedCell] = []
    @State private var editorMode: EditableOverlay.EditorMode = .view
    @State private var annotateOverlayMode: OverlayMode = .bbox

    init(state: AppState, imageCount: Int, annotated: Binding<Int>,
         onNext: @escaping () -> Void, onBack: @escaping () -> Void) {
        self.state = state
        self.imageCount = imageCount
        self._annotated = annotated
        self.onNext = onNext
        self.onBack = onBack
        self.initialCells = ProceduralCells.generate(count: 120, seed: 99, width: 560, height: 360)
    }

    /// Walks all batches and returns the nth image-with-detection so we can record
    /// "accept" corrections against real DetectionRecords.
    private func detectionForImage(at index: Int) -> DetectionRecord? {
        var i = 0
        for batch in state.repos.allBatches() {
            for image in batch.images {
                if let det = image.detection {
                    if i == index { return det }
                    i += 1
                }
            }
        }
        return nil
    }

    private func approveCurrent() {
        if let det = detectionForImage(at: annotated) {
            // Marker correction representing "user reviewed and accepted this detection."
            let correction = CorrectionRecord(kind: "accept",
                                              cellId: UUID(),
                                              cx: 0, cy: 0, diameter: 0)
            state.repos.recordCorrection(correction, on: det)
        }
        annotated = min(imageCount, annotated + 1)
    }

    var body: some View {
        let minRequired = min(50, imageCount)
        let remaining = max(0, imageCount - annotated)
        let pct: Double = imageCount > 0 ? Double(annotated) / Double(imageCount) : 0

        return VStack(alignment: .leading, spacing: 0) {
            FTCard {
                VStack(alignment: .leading, spacing: 0) {
                    FTSectionTitle(
                        title: "Annotate cells",
                        desc: "Click cells the current model missed, or correct boxes that are wrong. You can also pre-label everything with the active model and just review it — much faster."
                    )

                    FTDemoBanner(message: "Preview only — this canvas shows synthetic sample cells, not your images. Annotations made here are illustrative and are not used to train a model.")

                    HStack(alignment: .top, spacing: 16) {
                        // canvas
                        GeometryReader { geo in
                            let srcW: CGFloat = 560
                            let srcH: CGFloat = 360
                            let scale = min(geo.size.width / srcW, geo.size.height / srcH)
                            let drawW = srcW * scale
                            let drawH = srcH * scale
                            let displayCells = liveCells.map { c in
                                DetectedCell(
                                    id: c.id,
                                    cx: c.cx * scale,
                                    cy: c.cy * scale,
                                    diameter: c.diameter,
                                    diameterPx: c.diameterPx * scale,
                                    confidence: c.confidence
                                )
                            }
                            ZStack(alignment: .topLeading) {
                                ZStack {
                                    CellSampleImage(cells: displayCells, seed: 99,
                                                    showOverlay: false,
                                                    overlayMode: annotateOverlayMode,
                                                    thresholds: [20, 30])
                                    EditableOverlay(
                                        cells: $liveCells,
                                        pxPerUm: state.pxPerUm,
                                        thresholds: [20, 30],
                                        overlayMode: annotateOverlayMode,
                                        uncertaintyThreshold: 0.55,
                                        viewScale: Double(scale),
                                        viewOffset: .zero,
                                        onEdit: nil,
                                        editorMode: $editorMode
                                    )
                                }
                                .frame(width: drawW, height: drawH)
                                .clipShape(RoundedRectangle(cornerRadius: Tokens.Radius.md))
                                .overlay(
                                    RoundedRectangle(cornerRadius: Tokens.Radius.md)
                                        .strokeBorder(Tokens.border, lineWidth: 0.5)
                                )

                                Text("image \(min(annotated + 1, imageCount)) of \(imageCount)")
                                    .font(.system(size: 11, design: .monospaced))
                                    .foregroundStyle(.white)
                                    .padding(.horizontal, 10).padding(.vertical, 4)
                                    .background(Color.black.opacity(0.55))
                                    .clipShape(RoundedRectangle(cornerRadius: 4))
                                    .padding(10)

                                VStack { Spacer()
                                    HStack { Spacer()
                                        annotateToolbar
                                            .padding(10)
                                    }
                                }
                                .frame(width: drawW, height: drawH)
                            }
                        }
                        .aspectRatio(560.0/360.0, contentMode: .fit)
                        .frame(maxWidth: .infinity)

                        // sidebar
                        VStack(alignment: .leading, spacing: 8) {
                            VStack(alignment: .leading, spacing: 0) {
                                HStack {
                                    Text("Annotation progress")
                                        .font(.system(size: 12, weight: .semibold))
                                        .foregroundStyle(Tokens.text)
                                    Spacer()
                                    Text("\(annotated)/\(imageCount)")
                                        .font(.system(size: 12, design: .monospaced))
                                        .foregroundStyle(Tokens.text)
                                }
                                .padding(.bottom, 6)
                                GeometryReader { geo in
                                    ZStack(alignment: .leading) {
                                        Capsule().fill(Tokens.border).frame(height: 4)
                                        Capsule().fill(theme.accentColor)
                                            .frame(width: max(0, geo.size.width * pct), height: 4)
                                    }
                                }
                                .frame(height: 4)
                                Text("\(remaining) images remaining")
                                    .font(.system(size: 11))
                                    .foregroundStyle(Tokens.textTertiary)
                                    .padding(.top, 6)
                            }
                            .padding(12)
                            .background(
                                RoundedRectangle(cornerRadius: Tokens.Radius.md).fill(Tokens.bgSunken)
                            )
                            .padding(.bottom, 6)

                            Button {
                                approveCurrent()
                            } label: {
                                HStack(spacing: 6) {
                                    Icon("check", size: 12)
                                    Text("Approve & next")
                                }
                                .frame(maxWidth: .infinity)
                            }
                            .appButton(.primary, size: .md)

                            Button {
                                annotated = imageCount
                            } label: {
                                HStack(spacing: 6) {
                                    Icon("sparkles", size: 12)
                                    Text("Auto-label remaining")
                                }
                                .frame(maxWidth: .infinity)
                            }
                            .appButton(.standard, size: .md)

                            Button {} label: {
                                Text("Skip image")
                                    .frame(maxWidth: .infinity)
                            }
                            .appButton(.ghost, size: .md)

                            VStack(alignment: .leading, spacing: 0) {
                                (Text("Tip: ").font(.system(size: 11.5, weight: .bold)).foregroundColor(Tokens.text)
                                 + Text("use auto-label, then spot-check 10–20% by hand. This usually gives the same training outcome at 5× the speed.")
                                    .font(.system(size: 11.5))
                                    .foregroundColor(Tokens.textSecondary))
                                .fixedSize(horizontal: false, vertical: true)
                                .lineSpacing(2)
                            }
                            .padding(12)
                            .background(
                                RoundedRectangle(cornerRadius: Tokens.Radius.md)
                                    .fill(theme.accentSofterAdaptive(for: scheme))
                            )
                            .padding(.top, 8)
                        }
                        .frame(width: 280)
                    }
                }
            }

            FTFooterBar(
                onBack: onBack,
                onNext: onNext,
                nextLabel: annotated < minRequired ? "Need ≥ \(minRequired) annotated" : "Continue to split",
                nextDisabled: annotated < minRequired
            )
        }
        .onAppear { if liveCells.isEmpty { liveCells = initialCells } }
    }

    private var annotateToolbar: some View {
        HStack(spacing: 4) {
            annotateModeButton(icon: "plus", mode: .add)
            annotateModeButton(icon: "minus", mode: .remove)
            annotateOverlayButton(icon: "bbox", overlay: .bbox)
            annotateOverlayButton(icon: "circle", overlay: .outline)
        }
        .padding(4)
        .background(
            RoundedRectangle(cornerRadius: Tokens.Radius.md)
                .fill(Tokens.bgToolbar)
                .overlay(
                    RoundedRectangle(cornerRadius: Tokens.Radius.md)
                        .strokeBorder(Tokens.border, lineWidth: 0.5)
                )
        )
        .shadow(color: .black.opacity(0.06), radius: 2, y: 1)
    }

    @ViewBuilder
    private func annotateModeButton(icon: String, mode: EditableOverlay.EditorMode) -> some View {
        let isActive = editorMode == mode
        Button {
            editorMode = (editorMode == mode) ? .view : mode
        } label: {
            Icon(icon, size: 11)
                .frame(width: 22, height: 22)
                .foregroundStyle(isActive ? Color.white : Tokens.textSecondary)
                .background(
                    RoundedRectangle(cornerRadius: Tokens.Radius.sm)
                        .fill(isActive ? theme.accentColor : Color.clear)
                )
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private func annotateOverlayButton(icon: String, overlay: OverlayMode) -> some View {
        let isActive = annotateOverlayMode == overlay
        Button {
            annotateOverlayMode = overlay
        } label: {
            Icon(icon, size: 11)
                .frame(width: 22, height: 22)
                .foregroundStyle(isActive ? Color.white : Tokens.textSecondary)
                .background(
                    RoundedRectangle(cornerRadius: Tokens.Radius.sm)
                        .fill(isActive ? theme.accentColor : Color.clear)
                )
        }
        .buttonStyle(.plain)
    }
}

// MARK: — STEP 2: Split

struct StepSplit: View {
    let imageCount: Int
    @Binding var trainPct: Int
    @Binding var valPct: Int
    var onNext: () -> Void
    var onBack: () -> Void

    @Environment(AppTheme.self) private var theme

    private var testPct: Int { max(0, 100 - trainPct - valPct) }
    private var trainN: Int { imageCount * trainPct / 100 }
    private var valN: Int { imageCount * valPct / 100 }
    private var testN: Int { imageCount - trainN - valN }

    /// Number of preview tiles — the real image count, clamped so very large
    /// datasets stay a readable grid.
    private static let maxPreviewTiles = 120
    private var previewCount: Int { min(imageCount, Self.maxPreviewTiles) }

    /// Re-shuffles on demand (the "Re-shuffle" button bumps the seed).
    @State private var shuffleSeed: Int = 42

    /// Shuffled preview indices for `previewCount` tiles.
    private var shuffled: [Int] {
        var rng = SeededRNG(shuffleSeed)
        var arr = Array(0..<max(0, previewCount))
        arr.sort { _, _ in rng.next() < 0.5 }
        return arr
    }

    init(imageCount: Int, trainPct: Binding<Int>, valPct: Binding<Int>,
         onNext: @escaping () -> Void, onBack: @escaping () -> Void) {
        self.imageCount = imageCount
        self._trainPct = trainPct
        self._valPct = valPct
        self.onNext = onNext
        self.onBack = onBack
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            FTCard {
                VStack(alignment: .leading, spacing: 0) {
                    FTSectionTitle(
                        title: "Split your dataset",
                        desc: "Train on the largest portion. Validate during training to catch overfitting. Hold a test set back — a real fine-tune only touches it once, at the very end, to report accuracy."
                    )

                    FTDemoBanner()

                    // Tri-segment bar
                    GeometryReader { geo in
                        let total = max(1, trainPct + valPct + testPct)
                        let w = geo.size.width
                        HStack(spacing: 0) {
                            FTSplitSeg(label: "Train · \(trainPct)%",
                                       width: w * Double(trainPct) / Double(total),
                                       bg: theme.accentColor, fg: .white)
                            FTSplitSeg(label: "Val · \(valPct)%",
                                       width: w * Double(valPct) / Double(total),
                                       bg: Tokens.bin3, fg: .white)
                            FTSplitSeg(label: "Test · \(testPct)%",
                                       width: w * Double(testPct) / Double(total),
                                       bg: Tokens.bin1, fg: .white)
                        }
                    }
                    .frame(height: 28)
                    .background(Tokens.bgSunken)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .strokeBorder(Tokens.border, lineWidth: 0.5)
                    )

                    // Sliders
                    VStack(spacing: 14) {
                        FTSplitSliderRow(
                            label: "Train", dot: theme.accentColor,
                            value: Binding(
                                get: { Double(trainPct) },
                                set: { v in
                                    let nv = min(Int(v), 90)
                                    trainPct = nv
                                    if nv + valPct > 95 { valPct = max(5, 100 - nv - 5) }
                                }
                            ), range: 40...90, count: trainN
                        )
                        FTSplitSliderRow(
                            label: "Validation", dot: Tokens.bin3,
                            value: Binding(
                                get: { Double(valPct) },
                                set: { v in
                                    valPct = min(Int(v), 100 - trainPct - 5)
                                }
                            ), range: 5...30, count: valN
                        )
                        HStack(spacing: 14) {
                            HStack(spacing: 8) {
                                RoundedRectangle(cornerRadius: 2).fill(Tokens.bin1).frame(width: 10, height: 10)
                                Text("Test").font(.system(size: 13)).foregroundStyle(Tokens.text)
                            }
                            .frame(width: 120, alignment: .leading)

                            Text("auto · \(testPct)%")
                                .font(.system(size: 11))
                                .foregroundStyle(Tokens.textTertiary)
                                .frame(maxWidth: .infinity, alignment: .leading)

                            HStack(spacing: 4) {
                                Text("\(testN)").font(.system(size: 13, design: .monospaced)).foregroundStyle(Tokens.text)
                                Text("img").font(.system(size: 13)).foregroundStyle(Tokens.textTertiary)
                            }
                            .frame(width: 80, alignment: .trailing)
                        }
                    }
                    .padding(.top, 22)

                    // Preview grid
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text(previewCount < imageCount
                                 ? "Preview · \(previewCount) of \(imageCount) images, shuffled"
                                 : "Preview · \(imageCount) images, shuffled")
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundStyle(Tokens.textSecondary)
                                .tracking(0.04 * 13)
                                .textCase(.uppercase)
                            Spacer()
                            Button {
                                shuffleSeed &+= 1
                            } label: {
                                HStack(spacing: 4) {
                                    Icon("settings", size: 11)
                                    Text("Re-shuffle")
                                }
                            }
                            .appButton(.ghost, size: .sm)
                        }

                        let cols = Array(repeating: GridItem(.flexible(), spacing: 4), count: 8)
                        LazyVGrid(columns: cols, spacing: 4) {
                            ForEach(shuffled.indices, id: \.self) { i in
                                let ratio = Double(i) / Double(shuffled.count)
                                let color: Color = {
                                    if ratio < Double(trainPct) / 100 { return theme.accentColor }
                                    if ratio < Double(trainPct + valPct) / 100 { return Tokens.bin3 }
                                    return Tokens.bin1
                                }()
                                FTDatasetCell(fill: color)
                                    .aspectRatio(1, contentMode: .fit)
                            }
                        }
                        .padding(4)
                        .background(
                            RoundedRectangle(cornerRadius: Tokens.Radius.md).fill(Tokens.bgSunken)
                        )
                    }
                    .padding(.top, 22)

                    // 3 checks
                    HStack(spacing: 12) {
                        SplitCheck(label: "Stratified", desc: "Each split has similar size distribution")
                        SplitCheck(label: "No leakage", desc: "Patient samples grouped to one split")
                        SplitCheck(label: "Seed locked", desc: "Same split every run — 'seed: 42'")
                    }
                    .padding(.top, 22)
                }
            }

            FTFooterBar(onBack: onBack, onNext: onNext, nextLabel: "Configure training")
        }
    }
}

private struct FTSplitSeg: View {
    let label: String
    let width: CGFloat
    let bg: Color
    let fg: Color
    var body: some View {
        Text(label)
            .font(.system(size: 11.5, weight: .semibold, design: .monospaced))
            .foregroundStyle(fg)
            .frame(width: max(0, width), height: 28)
            .background(bg)
    }
}

private struct FTSplitSliderRow: View {
    let label: String
    let dot: Color
    @Binding var value: Double
    let range: ClosedRange<Double>
    let count: Int

    var body: some View {
        HStack(spacing: 14) {
            HStack(spacing: 8) {
                RoundedRectangle(cornerRadius: 2).fill(dot).frame(width: 10, height: 10)
                Text(label).font(.system(size: 13)).foregroundStyle(Tokens.text)
            }
            .frame(width: 120, alignment: .leading)

            Slider(value: $value, in: range, step: 1)
                .controlSize(.small)
                .frame(maxWidth: .infinity)

            HStack(spacing: 4) {
                Text("\(count)").font(.system(size: 13, design: .monospaced)).foregroundStyle(Tokens.text)
                Text("img").font(.system(size: 13)).foregroundStyle(Tokens.textTertiary)
            }
            .frame(width: 80, alignment: .trailing)
        }
    }
}

private struct FTDatasetCell: View {
    let fill: Color

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 4).fill(Tokens.bgElevated)
            RoundedRectangle(cornerRadius: 4).fill(fill).opacity(0.88)
            Canvas { ctx, size in
                let inset: CGFloat = 4
                let r: CGFloat = 1
                let dots: [(CGFloat, CGFloat)] = [(0.3, 0.4), (0.7, 0.3), (0.5, 0.7)]
                for d in dots {
                    let x = inset + d.0 * (size.width - inset*2)
                    let y = inset + d.1 * (size.height - inset*2)
                    ctx.fill(Path(ellipseIn: CGRect(x: x-r, y: y-r, width: r*2, height: r*2)),
                             with: .color(.white.opacity(0.7)))
                }
            }
        }
    }
}

struct SplitCheck: View {
    let label: String
    let desc: String
    @Environment(AppTheme.self) private var theme

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            ZStack {
                Circle().fill(theme.accentColor)
                    .frame(width: 18, height: 18)
                Image(systemName: "checkmark")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(.white)
            }
            VStack(alignment: .leading, spacing: 1) {
                Text(label)
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(Tokens.text)
                Text(desc)
                    .font(.system(size: 11.5))
                    .foregroundStyle(Tokens.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: Tokens.Radius.md).fill(Tokens.bgSunken))
    }
}

// MARK: — STEP 3: Configure

struct StepConfigure: View {
    @Binding var baseModel: String
    @Binding var epochs: Int
    @Binding var lr: Double
    @Binding var batchSize: Int
    @Binding var augment: Bool
    /// Propagated to `TrainingService.start(...)` as the `--early-stop` flag.
    @Binding var earlyStop: Bool
    /// Propagated to `TrainingService.start(...)` as the `--mixed-precision` flag.
    @Binding var mixedPrecision: Bool
    /// Trainer is observed so we can show the resolved device name (mps/cuda/cpu).
    @ObservedObject var trainer: TrainingService
    var onNext: () -> Void
    var onBack: () -> Void

    @State private var advancedOpen = false
    @Environment(AppTheme.self) private var theme
    @Environment(\.colorScheme) private var scheme

    private let baseModels: [(String, String)] = [
        ("cp-cyto3", "Cellpose cyto3 (recommended)"),
        ("cp-nuclei", "Cellpose nuclei"),
        ("yo-s", "YOLOv11 small"),
        ("nuclephaser", "NuclePhaser"),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            FTCard {
                VStack(alignment: .leading, spacing: 0) {
                    FTSectionTitle(
                        title: "Training settings",
                        desc: "Defaults work for most datasets. Open advanced if you know what you're doing."
                    )

                    // Small device label so the user knows where training will run.
                    HStack(spacing: 6) {
                        Icon("cpu", size: 11)
                            .foregroundStyle(Tokens.textTertiary)
                        Text("Device · ")
                            .font(.system(size: 11.5))
                            .foregroundStyle(Tokens.textTertiary)
                        Text((trainer.device ?? "auto").uppercased())
                            .font(.system(size: 11.5, weight: .semibold, design: .monospaced))
                            .foregroundStyle(Tokens.textSecondary)
                    }
                    .padding(.bottom, 10)

                    ConfRow(label: "Base model", desc: "Starts from this model's weights") {
                        Menu {
                            ForEach(baseModels, id: \.0) { id, name in
                                Button(name) { baseModel = id }
                            }
                        } label: {
                            HStack(spacing: 4) {
                                Text(baseModels.first(where: { $0.0 == baseModel })?.1 ?? baseModel)
                                    .font(.system(size: 12))
                                Icon("chevron", size: 10)
                            }
                            .padding(.horizontal, 10).padding(.vertical, 5)
                            .background(
                                RoundedRectangle(cornerRadius: Tokens.Radius.md).fill(Tokens.bgSunken)
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: Tokens.Radius.md).strokeBorder(Tokens.border, lineWidth: 0.5)
                            )
                            .foregroundStyle(Tokens.text)
                        }
                        .menuStyle(.borderlessButton)
                        .fixedSize()
                    }

                    ConfRow(label: "Epochs", desc: "How many times we pass over the data") {
                        SliderRow(
                            value: Binding(get: { Double(epochs) }, set: { epochs = Int($0) }),
                            min: 5, max: 120, step: 1,
                            display: "\(epochs)", unit: "epochs"
                        )
                    }

                    ConfRow(label: "Learning rate", desc: "Lower = safer, slower") {
                        SliderRow(
                            value: Binding(get: { lr * 10000 }, set: { lr = $0 / 10000 }),
                            min: 1, max: 20, step: 1,
                            display: String(format: "%.4f", lr), unit: nil
                        )
                    }

                    ConfRow(label: "Batch size", desc: "Higher uses more memory") {
                        SliderRow(
                            value: Binding(get: { Double(batchSize) }, set: { batchSize = Int($0) }),
                            min: 2, max: 16, step: 1,
                            display: "\(batchSize)", unit: nil
                        )
                    }

                    ConfRow(label: "Augmentation",
                            desc: "Random flips, rotation, brightness — usually helps generalize") {
                        CustomToggle(isOn: $augment)
                    }

                    // Advanced disclosure
                    VStack(alignment: .leading, spacing: 0) {
                        Button {
                            withAnimation(Tokens.Motion.easeFast) { advancedOpen.toggle() }
                        } label: {
                            HStack(spacing: 6) {
                                Image(systemName: advancedOpen ? "chevron.down" : "chevron.right")
                                    .font(.system(size: 10, weight: .semibold))
                                Text("Advanced settings")
                                    .font(.system(size: 12.5, weight: .semibold))
                            }
                            .foregroundStyle(theme.accentColor)
                            .padding(.vertical, 6)
                        }
                        .buttonStyle(.plain)

                        if advancedOpen {
                            VStack(spacing: 0) {
                                ConfRow(label: "Optimizer", desc: nil) {
                                    Text("AdamW")
                                        .font(.system(size: 12))
                                        .padding(.horizontal, 10).padding(.vertical, 4)
                                        .background(RoundedRectangle(cornerRadius: Tokens.Radius.md).fill(Tokens.bgSunken))
                                        .overlay(RoundedRectangle(cornerRadius: Tokens.Radius.md).strokeBorder(Tokens.border, lineWidth: 0.5))
                                        .foregroundStyle(Tokens.text)
                                }
                                ConfRow(label: "Scheduler", desc: nil) {
                                    Text("Cosine, warmup 5%")
                                        .font(.system(size: 12))
                                        .padding(.horizontal, 10).padding(.vertical, 4)
                                        .background(RoundedRectangle(cornerRadius: Tokens.Radius.md).fill(Tokens.bgSunken))
                                        .overlay(RoundedRectangle(cornerRadius: Tokens.Radius.md).strokeBorder(Tokens.border, lineWidth: 0.5))
                                        .foregroundStyle(Tokens.text)
                                }
                                ConfRow(label: "Mixed precision", desc: "FP16 forward when GPU is available") {
                                    CustomToggle(isOn: $mixedPrecision)
                                }
                                ConfRow(label: "Early stopping", desc: "Stop if val loss stalls 10 epochs") {
                                    CustomToggle(isOn: $earlyStop)
                                }
                            }
                        }
                    }
                    .padding(.top, 14)

                    // Info box
                    HStack(alignment: .top, spacing: 12) {
                        Icon("info", size: 14)
                            .foregroundStyle(theme.accentColor)
                            .padding(.top, 2)
                        (Text("Estimated ").font(.system(size: 12)).foregroundColor(Tokens.textSecondary)
                         + Text("~14 minutes").font(.system(size: 12, weight: .bold)).foregroundColor(Tokens.text)
                         + Text(" on this Mac (M-series, no GPU server). Your image dimensions, batch size, and epoch count drive this — we'll show a live ETA once training starts.")
                            .font(.system(size: 12)).foregroundColor(Tokens.textSecondary))
                        .lineSpacing(2)
                        .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(14)
                    .background(
                        RoundedRectangle(cornerRadius: Tokens.Radius.md)
                            .fill(theme.accentSofterAdaptive(for: scheme))
                    )
                    .padding(.top, 18)
                }
            }

            FTFooterBar(onBack: onBack, onNext: onNext, nextLabel: "Start training")
        }
    }
}

struct ConfRow<Content: View>: View {
    let label: String
    let desc: String?
    @ViewBuilder let content: Content

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .center) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(label).font(.system(size: 13, weight: .medium)).foregroundStyle(Tokens.text)
                    if let desc {
                        Text(desc).font(.system(size: 11.5)).foregroundStyle(Tokens.textTertiary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer()
                content
            }
            .padding(.vertical, 14)
            Rectangle().fill(Tokens.divider).frame(height: 0.5)
        }
    }
}

struct SliderRow: View {
    @Binding var value: Double
    let min: Double
    let max: Double
    let step: Double
    let display: String
    let unit: String?

    var body: some View {
        HStack(spacing: 12) {
            Slider(value: $value, in: min...max, step: step)
                .controlSize(.small)
                .frame(width: 200)
            HStack(spacing: 4) {
                Text(display)
                    .font(.system(size: 13, weight: .semibold, design: .monospaced))
                    .foregroundStyle(Tokens.text)
                if let unit {
                    Text(unit).font(.system(size: 13)).foregroundStyle(Tokens.textTertiary)
                }
            }
            .frame(minWidth: 60, alignment: .trailing)
        }
        .frame(minWidth: 260)
    }
}

// MARK: — STEP 4: Train

struct StepTrain: View {
    let epochs: Int
    let baseModel: String
    let lr: Double
    let batchSize: Int
    let augment: Bool
    let earlyStop: Bool
    let mixedPrecision: Bool
    let datasetURLs: [URL]
    let annotated: Int
    @Binding var training: FTTrainState
    @Binding var curve: FTCurve
    @ObservedObject var trainer: TrainingService
    var onComplete: (FTMetrics) -> Void
    var onBack: () -> Void

    @Environment(AppTheme.self) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            FTCard {
                VStack(alignment: .leading, spacing: 0) {
                    HStack(alignment: .center) {
                        VStack(alignment: .leading, spacing: 4) {
                            HStack(spacing: 8) {
                                Text("Training in progress")
                                    .font(.system(size: 16, weight: .semibold))
                                    .tracking(-0.16)
                                    .foregroundStyle(Tokens.text)
                                if let stopped = trainer.earlyStopped {
                                    Text("Early-stopped at epoch \(stopped)")
                                        .font(.system(size: 10.5, weight: .semibold))
                                        .foregroundStyle(.white)
                                        .padding(.horizontal, 8)
                                        .padding(.vertical, 3)
                                        .background(Capsule().fill(theme.accentColor))
                                }
                            }
                            HStack(spacing: 0) {
                                Text("Epoch ").font(.system(size: 13)).foregroundStyle(Tokens.textSecondary)
                                Text("\(min(training.epoch, epochs)) / \(epochs)")
                                    .font(.system(size: 13, design: .monospaced))
                                    .foregroundStyle(Tokens.textSecondary)
                                Text(" · ETA ").font(.system(size: 13)).foregroundStyle(Tokens.textSecondary)
                                Text("\(training.eta/60)m \(String(format: "%02d", training.eta % 60))s")
                                    .font(.system(size: 13, design: .monospaced))
                                    .foregroundStyle(Tokens.textSecondary)
                                Text(" · ").font(.system(size: 13)).foregroundStyle(Tokens.textSecondary)
                                Text(training.running ? statusLabel : "paused")
                                    .font(.system(size: 13))
                                    .foregroundStyle(theme.accentColor)
                            }
                        }
                        Spacer()
                        HStack(spacing: 6) {
                            Button {
                                if training.running {
                                    trainer.pause()
                                    training.running = false
                                } else {
                                    trainer.resume()
                                    training.running = true
                                }
                            } label: {
                                HStack(spacing: 6) {
                                    Icon(training.running ? "pause" : "play", size: 12)
                                    Text(training.running ? "Pause" : "Resume")
                                }
                            }
                            .appButton(.standard, size: .md)

                            Button {
                                trainer.cancel()
                                onBack()
                            } label: {
                                HStack(spacing: 6) {
                                    Icon("stop", size: 12)
                                    Text("Stop")
                                }
                            }
                            .appButton(.danger, size: .md)
                        }
                    }
                    .padding(.bottom, 18)

                    FTDemoBanner(message: "Preview only — the fine-tune wizard is a non-functional demo. The loss curve and metrics below are illustrative and do not reflect real training on your dataset.")

                    // progress bar
                    GeometryReader { geo in
                        let pct = min(1.0, Double(training.epoch) / Double(max(1, epochs)))
                        ZStack(alignment: .leading) {
                            Capsule().fill(Tokens.bgSunken).frame(height: 6)
                            Capsule().fill(theme.accentColor)
                                .frame(width: geo.size.width * pct, height: 6)
                        }
                    }
                    .frame(height: 6)
                    .padding(.bottom, 22)

                    // chart
                    LossChart(curve: curve, epochs: epochs)
                        .frame(height: 200)
                        .padding(14)
                        .background(
                            RoundedRectangle(cornerRadius: Tokens.Radius.md).fill(Tokens.bgSunken)
                        )

                    HStack(spacing: 10) {
                        LiveMetric(label: "Train loss",
                                   value: String(format: "%.3f", training.loss),
                                   color: theme.accentColor, unit: nil)
                        LiveMetric(label: "Val loss",
                                   value: String(format: "%.3f", training.vloss),
                                   color: Tokens.bin3, unit: nil)
                        LiveMetric(label: "Best epoch",
                                   value: bestEpoch.map { "\($0)" } ?? "—",
                                   color: nil, unit: nil)
                        LiveMetric(label: "Device",
                                   value: (trainer.device ?? "—").uppercased(),
                                   color: nil, unit: nil)
                    }
                    .padding(.top, 16)
                }
            }
            FTFooterBar(onBack: { trainer.cancel(); onBack() }, backLabel: "Cancel training")
        }
        .onAppear { startIfNeeded() }
        .onDisappear { /* keep service alive — FineTuneView owns it */ }
        .onReceive(trainer.$progress) { newProgress in
            apply(newProgress)
        }
    }

    private var statusLabel: String {
        switch CellposeAvailability.detect() {
        case .available: return "running cellpose locally"
        default: return "running simulated training"
        }
    }

    /// 1-based epoch with the lowest validation loss so far, or nil until we
    /// have a val curve. Derived from the actual plotted curve rather than a
    /// fixed fraction of the current epoch.
    private var bestEpoch: Int? {
        guard let minIdx = curve.val.indices.min(by: { curve.val[$0] < curve.val[$1] }) else {
            return nil
        }
        return minIdx + 1
    }

    private func startIfNeeded() {
        switch trainer.progress {
        case .idle, .failed:
            trainer.start(epochs: epochs, baseModel: baseModel,
                          lr: lr, batchSize: batchSize, augment: augment,
                          imageURLs: datasetURLs, annotated: annotated,
                          earlyStop: earlyStop,
                          mixedPrecision: mixedPrecision)
            training.running = true
        case .paused:
            break // user manually paused
        case .running, .complete:
            break
        }
    }

    private func apply(_ progress: TrainingService.Progress) {
        switch progress {
        case .idle:
            break
        case .running(let epoch, _, let trainLoss, let valLoss, let eta):
            if epoch > training.epoch {
                curve.train.append(trainLoss)
                curve.val.append(valLoss)
            }
            training.epoch = epoch
            training.loss = trainLoss
            training.vloss = valLoss
            training.eta = eta
            training.running = true
        case .paused:
            training.running = false
        case .complete(let m):
            training.epoch = epochs
            training.running = false
            onComplete(m)
        case .failed:
            training.running = false
        }
    }
}

// MARK: — Loss chart

struct LossChart: View {
    let curve: FTCurve
    let epochs: Int
    @Environment(AppTheme.self) private var theme

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let h = geo.size.height
            let pad: CGFloat = 8
            let all = curve.train + curve.val + [2.5, 0.2]
            let maxY = all.max() ?? 1
            let minY = Swift.min(all.min() ?? 0, 0)
            let range = Swift.max(0.001, maxY - minY)

            let xs: (Int) -> CGFloat = { i in
                pad + CGFloat(i) / CGFloat(Swift.max(1, epochs - 1)) * (w - pad*2)
            }
            let ys: (Double) -> CGFloat = { v in
                pad + CGFloat(1 - (v - minY) / range) * (h - pad*2)
            }

            ZStack {
                // grid
                Path { p in
                    for t in [0.25, 0.5, 0.75] {
                        let y = pad + CGFloat(t) * (h - pad*2)
                        p.move(to: CGPoint(x: pad, y: y))
                        p.addLine(to: CGPoint(x: w - pad, y: y))
                    }
                }
                .stroke(Tokens.border, lineWidth: 0.5)

                // val line
                if curve.val.count > 1 {
                    Path { p in
                        for (i, v) in curve.val.enumerated() {
                            let pt = CGPoint(x: xs(i), y: ys(v))
                            if i == 0 { p.move(to: pt) } else { p.addLine(to: pt) }
                        }
                    }
                    .stroke(Tokens.bin3, lineWidth: 1.5)
                }
                // train line
                if curve.train.count > 1 {
                    Path { p in
                        for (i, v) in curve.train.enumerated() {
                            let pt = CGPoint(x: xs(i), y: ys(v))
                            if i == 0 { p.move(to: pt) } else { p.addLine(to: pt) }
                        }
                    }
                    .stroke(theme.accentColor, lineWidth: 1.5)
                }

                // legend
                VStack { HStack { Spacer()
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 6) {
                            Circle().fill(theme.accentColor).frame(width: 6, height: 6)
                            Text("train").font(.system(size: 11, design: .monospaced)).foregroundStyle(Tokens.textTertiary)
                        }
                        HStack(spacing: 6) {
                            Circle().fill(Tokens.bin3).frame(width: 6, height: 6)
                            Text("val").font(.system(size: 11, design: .monospaced)).foregroundStyle(Tokens.textTertiary)
                        }
                    }
                    .padding(8)
                    .background(RoundedRectangle(cornerRadius: 4).fill(Tokens.bgElevated))
                    .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(Tokens.border, lineWidth: 0.5))
                } ; Spacer() }
                .padding(4)
            }
        }
    }
}

// MARK: — Live + big metric cards

struct LiveMetric: View {
    let label: String
    let value: String
    let color: Color?
    let unit: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label.uppercased())
                .tracking(0.04 * 11)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Tokens.textTertiary)
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(value)
                    .font(.system(size: 20, weight: .semibold, design: .monospaced))
                    .foregroundStyle(color ?? Tokens.text)
                if let unit {
                    Text(unit).font(.system(size: 13)).foregroundStyle(Tokens.textTertiary)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 14).padding(.vertical, 12)
        .background(RoundedRectangle(cornerRadius: Tokens.Radius.md).fill(Tokens.bgSunken))
    }
}

struct BigMetric: View {
    let name: String
    let value: String
    /// Optional "vs baseline" delta. nil when there is no real baseline to
    /// compare against (e.g. the demo/synthetic path), so we never invent one.
    var delta: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(name.uppercased())
                .tracking(0.04 * 11)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Tokens.textTertiary)
            Text(value)
                .font(.system(size: 20, weight: .semibold, design: .monospaced))
                .foregroundStyle(Tokens.text)
            if let delta {
                Text("↑ \(delta) vs baseline")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(Tokens.success)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 14).padding(.vertical, 12)
        .background(RoundedRectangle(cornerRadius: Tokens.Radius.md).fill(Tokens.bgSunken))
    }
}

// MARK: — STEP 5: Evaluate

struct StepEvaluate: View {
    @Bindable var state: AppState
    let metrics: FTMetrics?
    let curve: FTCurve
    let trainer: TrainingService
    let imageCount: Int
    let annotated: Int
    var onRestart: () -> Void
    var onDone: () -> Void

    @Environment(AppTheme.self) private var theme
    @State private var modelName: String = "Oral mucosa keratinocytes v4"
    @State private var saved: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            FTCard {
                VStack(alignment: .leading, spacing: 0) {
                    HStack(alignment: .top, spacing: 14) {
                        ZStack {
                            RoundedRectangle(cornerRadius: 14, style: .continuous)
                                .fill(theme.accentSoft)
                                .frame(width: 56, height: 56)
                            Image(systemName: "checkmark")
                                .font(.system(size: 28, weight: .semibold))
                                .foregroundStyle(theme.accentColor)
                        }
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Training complete")
                                .font(.system(size: 16, weight: .semibold))
                                .foregroundStyle(Tokens.text)
                            Text("This is a preview of what the evaluation summary looks like.")
                                .font(.system(size: 13))
                                .foregroundStyle(Tokens.textSecondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }

                    FTDemoBanner(message: "Preview only — these figures are illustrative demo values on synthetic data, not a real evaluation of a model trained on your dataset. Do not cite these numbers.")
                        .padding(.top, 18)

                    sectionHeader("Test set performance").padding(.top, 4)

                    HStack(spacing: 10) {
                        BigMetric(name: "AP @ 0.5 IoU",
                                  value: metrics.map { String(format: "%.3f", $0.ap50) } ?? "—")
                        BigMetric(name: "F1",
                                  value: metrics.map { String(format: "%.3f", $0.f1) } ?? "—")
                        BigMetric(name: "Precision",
                                  value: metrics.map { String(format: "%.3f", $0.precision) } ?? "—")
                        BigMetric(name: "Recall",
                                  value: metrics.map { String(format: "%.3f", $0.recall) } ?? "—")
                    }
                    .padding(.top, 10)

                    HStack(spacing: 0) {
                        (Text("Mean diameter error: ").font(.system(size: 12.5, weight: .bold)).foregroundColor(Tokens.text)
                         + Text(metrics.map { String(format: "%.2f µm", $0.meanDiamError) } ?? "—")
                            .font(.system(size: 12.5, weight: .bold, design: .monospaced)).foregroundColor(Tokens.text)
                         + Text(" — illustrative demo value. A real fine-tune would report this against your held-out test set.")
                            .font(.system(size: 12.5)).foregroundColor(Tokens.textSecondary))
                        .fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 0)
                    }
                    .padding(12)
                    .background(RoundedRectangle(cornerRadius: Tokens.Radius.md).fill(Tokens.bgSunken))
                    .padding(.top, 10)

                    sectionHeader("Training history").padding(.top, 22)

                    LossChart(curve: curve, epochs: Swift.max(curve.train.count, 40))
                        .frame(height: 200)
                        .padding(14)
                        .background(
                            RoundedRectangle(cornerRadius: Tokens.Radius.md).fill(Tokens.bgSunken)
                        )
                        .padding(.top, 8)

                    sectionHeader("Save model").padding(.top, 22)

                    HStack(spacing: 10) {
                        HStack(spacing: 4) {
                            TextField("Model name", text: $modelName)
                                .textFieldStyle(.plain)
                                .font(.system(size: 14, weight: .medium))
                                .foregroundStyle(Tokens.text)
                            Text(".ccmodel")
                                .font(.system(size: 12, design: .monospaced))
                                .foregroundStyle(Tokens.textTertiary)
                        }
                        .padding(.horizontal, 12).padding(.vertical, 8)
                        .background(
                            RoundedRectangle(cornerRadius: Tokens.Radius.md).fill(Tokens.bgSunken)
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: Tokens.Radius.md).strokeBorder(Tokens.border, lineWidth: 0.5)
                        )
                        .frame(maxWidth: .infinity)

                        Button {
                            saveModel()
                        } label: {
                            HStack(spacing: 6) {
                                Icon(saved ? "check" : "download", size: 12)
                                Text(saved ? "Saved" : "Save to Models")
                            }
                        }
                        .appButton(.primary, size: .md)
                        .disabled(saved || metrics == nil)
                    }
                    .padding(.top, 8)

                    (Text("Saves to ").font(.system(size: 11.5)).foregroundColor(Tokens.textTertiary)
                     + Text("~/Library/Application Support/CellCounter/Models")
                        .font(.system(size: 11.5, design: .monospaced)).foregroundColor(Tokens.textTertiary)
                     + Text(" — appears alongside built-in models.").font(.system(size: 11.5)).foregroundColor(Tokens.textTertiary))
                    .padding(.top, 6)
                }
            }

            FTFooterBar(onBack: onRestart, backLabel: "Train another",
                        onNext: onDone, nextLabel: "Done")
        }
    }

    private func sectionHeader(_ title: String) -> some View {
        Text(title.uppercased())
            .tracking(0.04 * 13)
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(Tokens.textSecondary)
    }

    private func saveModel() {
        guard let metrics, !saved else { return }
        let trimmed = modelName.trimmingCharacters(in: .whitespacesAndNewlines)
        let baseId = slugify(trimmed.isEmpty ? "custom-model" : trimmed)
        // If the user-typed name already includes "v\d" suffix, peel it off for the id stem
        // so version numbering doesn't double up.
        let modelId = stripTrailingVersion(baseId)
        let version = (state.repos.modelVersions(for: modelId).map { $0.version }.max() ?? 0) + 1
        let checkpointName = "\(modelId)-v\(version).ccmodel"
        let checkpointURL = FileStore.shared.modelsDir.appendingPathComponent(checkpointName)

        // Move the trainer's checkpoint into a permanent slot (or copy the sidecar JSON).
        if let staged = trainer.lastCheckpointURL {
            try? FileManager.default.removeItem(at: checkpointURL)
            do {
                try FileManager.default.moveItem(at: staged, to: checkpointURL)
            } catch {
                // If move fails, fall back to writing an inline JSON blob so the path is real.
                writeInlineCheckpoint(at: checkpointURL, metrics: metrics)
            }
        } else {
            writeInlineCheckpoint(at: checkpointURL, metrics: metrics)
        }

        let metricMap: [String: Double] = [
            "ap50": metrics.ap50,
            "f1": metrics.f1,
            "precision": metrics.precision,
            "recall": metrics.recall,
            "meanDiamError": metrics.meanDiamError,
        ]
        let record = ModelVersionRecord(
            modelId: modelId,
            version: version,
            trainedOnImages: imageCount,
            trainedOnCorrections: annotated,
            checkpointPath: checkpointURL.path,
            metrics: metricMap
        )
        state.repos.recordModelVersion(record)

        // Surface in the Models screen.
        let displayName = trimmed.isEmpty ? "Custom model v\(version)" : trimmed
        let sizeMB = max(1, Int((try? FileManager.default
                                  .attributesOfItem(atPath: checkpointURL.path)[.size] as? Int) ?? 1024) / (1024 * 1024))
        let info = DetectionModelInfo(
            id: "\(modelId)-v\(version)",
            family: .custom,
            name: displayName,
            sizeMB: sizeMB,
            sizeLabel: "\(sizeMB) MB",
            desc: "Fine-tuned on \(imageCount) images · just now",
            state: .downloaded,
            speed: .fast,
            accuracy: .high,
            tags: ["custom"],
            custom: true,
            architecture: "Fine-tuned",
            trainingData: "User dataset · \(imageCount) images, \(annotated) annotated",
            paper: "User fine-tune",
            outputType: "Masks + boxes + outlines"
        )
        if !state.models.contains(where: { $0.id == info.id }) {
            state.models.append(info)
        }
        saved = true
    }

    private func writeInlineCheckpoint(at url: URL, metrics: FTMetrics) {
        let blob: [String: Any] = [
            "kind": "inline",
            "createdAt": ISO8601DateFormatter().string(from: Date()),
            "metrics": [
                "ap50": metrics.ap50,
                "f1": metrics.f1,
                "precision": metrics.precision,
                "recall": metrics.recall,
                "meanDiamError": metrics.meanDiamError,
            ],
            "imageCount": imageCount,
            "annotated": annotated,
        ]
        if let data = try? JSONSerialization.data(withJSONObject: blob, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: url, options: .atomic)
        }
    }

    private func slugify(_ s: String) -> String {
        let lowered = s.lowercased()
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz0123456789-")
        var out = ""
        var lastWasDash = false
        for scalar in lowered.unicodeScalars {
            if allowed.contains(scalar) {
                out.unicodeScalars.append(scalar)
                lastWasDash = (scalar == "-")
            } else if scalar == " " || scalar == "_" || scalar == "." {
                if !lastWasDash { out.append("-"); lastWasDash = true }
            }
        }
        while out.hasPrefix("-") { out.removeFirst() }
        while out.hasSuffix("-") { out.removeLast() }
        return out.isEmpty ? "custom-model" : out
    }

    /// "oral-mucosa-keratinocytes-v4" -> "oral-mucosa-keratinocytes"
    private func stripTrailingVersion(_ id: String) -> String {
        guard let range = id.range(of: "-v[0-9]+$", options: .regularExpression) else { return id }
        return String(id[..<range.lowerBound])
    }
}
