import SwiftUI

/// Consolidated, low-click workflows inspired by the referenced Napari and
/// ImageJ plugins. Each action uses CellCounter's native persistence and
/// detector interfaces; no plugin binary is embedded.
struct AdvancedWorkflowsPanel: View {
    @Bindable var state: AppState
    let cells: [DetectedCell]
    @Binding var editorMode: EditableOverlay.EditorMode
    @Binding var selectedCellIds: Set<UUID>

    @State private var useDrift = true
    @State private var sequenceMessage: String? = nil
    @State private var isRunningSequence = false
    @State private var secondOpinionMessage: String? = nil

    var body: some View {
        VStack(spacing: 0) {
            promptSection
            Divider().overlay(Tokens.divider)
            sequenceSection
            Divider().overlay(Tokens.divider)
            curationSection
            Divider().overlay(Tokens.divider)
            labelsSection
            Divider().overlay(Tokens.divider)
            preprocessingSection
        }
    }

    private var promptSection: some View {
        WorkflowSection(title: "Prompt-assisted correction",
                        subtitle: "Click or box an object to replace tracing. Compatible SAM models reuse per-image embeddings; other models use the native contour fallback.") {
            HStack(spacing: 8) {
                workflowButton("Point prompt", icon: "scope",
                               active: editorMode == .promptPoint) {
                    editorMode = .promptPoint
                }
                workflowButton("Box prompt", icon: "viewfinder",
                               active: editorMode == .promptBox) {
                    editorMode = .promptBox
                }
            }
        }
    }

    private var sequenceSection: some View {
        WorkflowSection(title: "Sequence correction",
                        subtitle: "Propagate selected masks or interpolate missing labels through ordered Z-slices/timepoints.") {
            Toggle("Compensate acquisition drift", isOn: $useDrift)
                .font(.system(size: 11.5))
                .toggleStyle(.switch).controlSize(.small)

            HStack(spacing: 8) {
                Button {
                    runSequence { await state.propagateSelectedCells(selectedCellIds,
                                                                     useDrift: useDrift) }
                } label: {
                    Label("Propagate", systemImage: "square.stack.3d.up.forward")
                        .frame(maxWidth: .infinity)
                }
                .appButton(.primary, size: .sm)
                .disabled(selectedCellIds.isEmpty || isRunningSequence)

                Button {
                    runSequence { await state.interpolateSelectedCellToLast(selectedCellIds) }
                } label: {
                    Label("Interpolate", systemImage: "point.3.connected.trianglepath.dotted")
                        .frame(maxWidth: .infinity)
                }
                .appButton(.standard, size: .sm)
                .disabled(selectedCellIds.count != 1 || isRunningSequence)
            }
            if isRunningSequence {
                HStack(spacing: 6) { AppSpinner(); Text("Updating sequence…") }
                    .font(.system(size: 10.5)).foregroundStyle(Tokens.textTertiary)
            } else if let sequenceMessage {
                Text(sequenceMessage)
                    .font(.system(size: 10.5))
                    .foregroundStyle(Tokens.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Text("Select masks in View mode first. Interpolate uses the nearest final-frame mask as the second anchor.")
                    .font(.system(size: 10.5)).foregroundStyle(Tokens.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var curationSection: some View {
        WorkflowSection(title: "Fast curation",
                        subtitle: "Review tiled crops, compare saved detector results, or create a fresh second opinion.") {
            Button {
                UserDefaults.standard.set("grid", forKey: "cc-review-layout-v1")
                state.view = .reviewQueue
            } label: {
                Label("Open grid curator", systemImage: "square.grid.3x3")
                    .frame(maxWidth: .infinity)
            }
            .appButton(.standard, size: .sm)

            Button {
                state.activate(EnsembleDownloader.modelId)
                if let image = state.currentImage, state.detector != nil {
                    state.reRunDetection(on: image)
                    secondOpinionMessage = "Running the configured two-model ensemble. The current mask will be saved as a variant."
                } else {
                    secondOpinionMessage = "Install/configure both ensemble members in Models first."
                }
            } label: {
                Label("Run second opinion", systemImage: "square.split.2x1")
                    .frame(maxWidth: .infinity)
            }
            .appButton(.standard, size: .sm)

            if let secondOpinionMessage {
                Text(secondOpinionMessage)
                    .font(.system(size: 10.5)).foregroundStyle(Tokens.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            MaskCuratorPanel(state: state)
        }
    }

    private var labelsSection: some View {
        WorkflowSection(title: "Bulk labels",
                        subtitle: "Safe relabeling actions operate as one batched persistence edit.") {
            HStack(spacing: 8) {
                Button {
                    state.mergeSelectedCells(selectedCellIds)
                    selectedCellIds.removeAll()
                } label: {
                    Label("Merge selected", systemImage: "arrow.triangle.merge")
                        .frame(maxWidth: .infinity)
                }
                .appButton(.standard, size: .sm)
                .disabled(selectedCellIds.count < 2)

                Button {
                    state.removeCells(selectedCellIds)
                    selectedCellIds.removeAll()
                } label: {
                    Label("Delete", systemImage: "trash")
                        .frame(maxWidth: .infinity)
                }
                .appButton(.danger, size: .sm)
                .disabled(selectedCellIds.isEmpty)
            }

            let flagged = Set(cells
                .filter { $0.likelyDebris || $0.edgeTouching }.map(\.id))
            Button {
                state.removeCells(flagged)
            } label: {
                Label("Remove \(flagged.count) debris/edge flags", systemImage: "eraser")
                    .frame(maxWidth: .infinity)
            }
            .appButton(.standard, size: .sm)
            .disabled(flagged.isEmpty)
        }
    }

    private var preprocessingSection: some View {
        WorkflowSection(title: "Preprocessing & optimizer",
                        subtitle: "Optional presets affect the next segmentation only. GPU diffusion is used when compatible; CPU fallback is automatic.") {
            Picker("Preset", selection: $state.preprocessingPreset) {
                ForEach(PreprocessingPreset.allCases, id: \.self) { preset in
                    Text(preset.label).tag(preset)
                }
            }
            .pickerStyle(.menu)

            Toggle("Rolling-ball background correction", isOn: $state.backgroundSubtract)
                .font(.system(size: 11.5)).toggleStyle(.switch).controlSize(.small)
            Toggle("Split touching labels after detection", isOn: $state.watershedSplit)
                .font(.system(size: 11.5)).toggleStyle(.switch).controlSize(.small)

            if let recommendation = currentRecommendation {
                Label(recommendation, systemImage: "wand.and.stars")
                    .font(.system(size: 10.5))
                    .foregroundStyle(Tokens.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Button {
                if let image = state.currentImage { state.reRunDetection(on: image) }
            } label: {
                Label("Apply preset and re-segment", systemImage: "arrow.clockwise")
                    .frame(maxWidth: .infinity)
            }
            .appButton(.primary, size: .sm)
            .disabled(state.currentImage == nil || state.detector == nil)
        }
    }

    private var currentRecommendation: String? {
        let stats = state.currentImage?.detection?.imageStats ?? [:]
        if (stats["illumination_residual"] ?? 0) > 0.18 {
            return "Uneven illumination detected: CLAHE or rolling-ball correction is a good first parameter sweep."
        }
        if (stats["focus_score"] ?? 1) < 0.45 {
            return "Weak focus/noisy edges detected: try anisotropic diffusion before changing the detector."
        }
        return "No strong per-image warning. Batch Quality Insights can rank parameter opportunities across all fields."
    }

    private func runSequence(_ operation: @escaping @MainActor () async -> String) {
        guard !isRunningSequence else { return }
        isRunningSequence = true
        sequenceMessage = nil
        Task { @MainActor in
            sequenceMessage = await operation()
            isRunningSequence = false
        }
    }

    private func workflowButton(_ title: String, icon: String, active: Bool,
                                action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 6) { Icon(icon, size: 11); Text(title) }
                .frame(maxWidth: .infinity)
        }
        .appButton(active ? .primary : .standard, size: .sm)
    }
}

private struct WorkflowSection<Content: View>: View {
    let title: String
    let subtitle: String
    let content: Content

    init(title: String, subtitle: String, @ViewBuilder content: () -> Content) {
        self.title = title; self.subtitle = subtitle; self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionHeader(title: title)
            Text(subtitle)
                .font(.system(size: 10.5)).foregroundStyle(Tokens.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
            content
        }
        .padding(.horizontal, 18).padding(.vertical, 16)
    }
}

struct MaskCuratorPanel: View {
    @Bindable var state: AppState
    @State private var variants: [SegmentationVariantRecord] = []
    @State private var comparing: SegmentationVariantRecord?
    @State private var variantPage = 0

    var body: some View {
        Group {
            if !variants.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                Text("SAVED MASK VARIANTS")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Tokens.textTertiary)
                ForEach(Array(variants.dropFirst(variantPage * 8).prefix(8))) { variant in
                    VStack(alignment: .leading, spacing: 6) {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(variant.label).font(.system(size: 11.5, weight: .medium))
                                .foregroundStyle(Tokens.text).lineLimit(1)
                            Text("\(variant.cellCount) masks · \(Int(variant.meanConfidence * 100))% mean confidence")
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundStyle(Tokens.textTertiary)
                        }
                        HStack(spacing: 8) {
                        Button("Compare") { comparing = variant }.appButton(.ghost, size: .sm)
                        Button("Use") { apply(variant) }.appButton(.ghost, size: .sm)
                        Button {
                            state.repos.deleteSegmentationVariant(variant); refresh()
                        } label: { Image(systemName: "trash") }
                            .buttonStyle(.plain).foregroundStyle(Tokens.textTertiary)
                        Spacer()
                        }
                    }
                    .padding(8).background(Tokens.bgSunken)
                    .clipShape(RoundedRectangle(cornerRadius: Tokens.Radius.sm))
                }
                if variants.count > 8 {
                    HStack {
                        Button("Newer") { variantPage = max(0, variantPage - 1) }.disabled(variantPage == 0)
                        Spacer()
                        Text("\(variantPage + 1) / \((variants.count + 7) / 8)")
                        Spacer()
                        Button("Older") { variantPage += 1 }.disabled((variantPage + 1) * 8 >= variants.count)
                    }.font(.system(size: 10)).buttonStyle(.plain)
                }
            }
            .padding(.top, 4)
            }
        }
        .onAppear(perform: refresh)
        .onChange(of: state.currentImage?.id) { comparing = nil; refresh() }
        .onChange(of: state.currentImage?.detection?.id) { refresh() }
        .onReceive(NotificationCenter.default.publisher(for: .ccCorrectionsChanged)) { _ in refresh() }
        .sheet(item: $comparing) { variant in
            if let image = state.currentImage, image.id == variant.imageId {
                VariantComparisonView(state: state, image: image, variant: variant,
                                      onApply: { apply(variant) })
            }
        }
    }

    private func refresh() {
        guard let image = state.currentImage else { variants = []; return }
        variants = state.repos.segmentationVariants(for: image.id)
        variantPage = min(variantPage, max(0, (variants.count - 1) / 8))
    }

    private func apply(_ variant: SegmentationVariantRecord) {
        guard let image = state.currentImage, image.id == variant.imageId else { return }
        let result = state.repos.applySegmentationVariant(variant, to: image)
        NotificationCenter.default.post(name: .ccCorrectionsChanged, object: image.id,
                                        userInfo: ["reviewDelta": result?.reviewCountDelta ?? 0])
        refresh()
    }
}

struct QualityInsightsPanel: View {
    @Bindable var state: AppState
    @State private var snapshot: BatchInsightsSnapshot? = nil
    @State private var loading = false

    var body: some View {
        VStack(spacing: 0) {
            header
            if loading && snapshot == nil {
                HStack(spacing: 8) { AppSpinner(); Text("Computing once for this batch…") }
                    .font(.system(size: 11)).foregroundStyle(Tokens.textTertiary)
                    .padding(18)
            } else if let snapshot {
                recommendations(snapshot)
                Divider().overlay(Tokens.divider)
                histogram(title: "Confidence", values: snapshot.confidenceBins,
                          color: Color.accentColor)
                Divider().overlay(Tokens.divider)
                histogram(title: "Diameter", values: snapshot.diameterBins,
                          color: state.overlayPalette.binColor(2),
                          footer: String(format: "%.1f–%.1f µm (1st–99th percentile)",
                                         snapshot.diameterRange.lowerBound,
                                         snapshot.diameterRange.upperBound))
                if snapshot.drift.count > 1 {
                    Divider().overlay(Tokens.divider)
                    driftPlot(snapshot.drift)
                }
                if snapshot.ensembleAgreement + snapshot.ensembleDisagreement > 0 {
                    Divider().overlay(Tokens.divider)
                    agreement(snapshot)
                }
                Divider().overlay(Tokens.divider)
                riskList(snapshot.riskImages)
            }
        }
        .task(id: "\(state.currentBatch?.id.uuidString ?? "none")-\(state.currentBatch?.contentRevision ?? -1)") { await load(force: false) }
    }

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("QUALITY INSIGHTS").font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Tokens.textSecondary)
                Text("Revision-cached; recalculates only after masks or calibration change.")
                    .font(.system(size: 10.5)).foregroundStyle(Tokens.textTertiary)
            }
            Spacer()
            Button { Task { await load(force: true) } } label: {
                Image(systemName: "arrow.clockwise")
            }.buttonStyle(.plain).disabled(loading)
        }
        .padding(.horizontal, 18).padding(.vertical, 16)
    }

    private func recommendations(_ snapshot: BatchInsightsSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            ForEach(snapshot.recommendations, id: \.self) { recommendation in
                Label(recommendation, systemImage: "wand.and.stars")
                    .font(.system(size: 10.5)).foregroundStyle(Tokens.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }.padding(.horizontal, 18).padding(.bottom, 16)
    }

    private func histogram(title: String, values: [Int], color: Color,
                           footer: String? = nil) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(title.uppercased()).font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Tokens.textSecondary)
            CachedBarPlot(values: values, color: color).frame(height: 74)
            if let footer { Text(footer).font(.system(size: 9.5, design: .monospaced))
                    .foregroundStyle(Tokens.textTertiary) }
        }.padding(.horizontal, 18).padding(.vertical, 14)
    }

    private func driftPlot(_ values: [SequenceWorkflowService.DriftOffset]) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Text("CUMULATIVE DRIFT").font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Tokens.textSecondary)
            GeometryReader { geometry in
                let maxMagnitude = max(1, values.map(\.magnitudePx).max() ?? 1)
                Path { path in
                    for (index, value) in values.enumerated() {
                        let x = values.count > 1
                            ? geometry.size.width * CGFloat(index) / CGFloat(values.count - 1) : 0
                        let y = geometry.size.height * (1 - CGFloat(value.magnitudePx / maxMagnitude))
                        if index == 0 { path.move(to: CGPoint(x: x, y: y)) }
                        else { path.addLine(to: CGPoint(x: x, y: y)) }
                    }
                }.stroke(Color.accentColor, style: StrokeStyle(lineWidth: 2, lineJoin: .round))
            }.frame(height: 66)
            Text(String(format: "Max %.1f px · used by drift-aware tracking/propagation",
                        values.map(\.magnitudePx).max() ?? 0))
                .font(.system(size: 9.5, design: .monospaced)).foregroundStyle(Tokens.textTertiary)
        }.padding(.horizontal, 18).padding(.vertical, 14)
    }

    private func agreement(_ snapshot: BatchInsightsSnapshot) -> some View {
        let total = snapshot.ensembleAgreement + snapshot.ensembleDisagreement
        let pct = total > 0 ? Double(snapshot.ensembleAgreement) / Double(total) * 100 : 0
        return VStack(alignment: .leading, spacing: 5) {
            Text("DETECTOR AGREEMENT").font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Tokens.textSecondary)
            Text(String(format: "%.1f%% agreement · %d disagreements",
                        pct, snapshot.ensembleDisagreement))
                .font(.system(size: 11, design: .monospaced)).foregroundStyle(Tokens.text)
        }.padding(.horizontal, 18).padding(.vertical, 14)
    }

    private func riskList(_ risks: [BatchInsightsSnapshot.RiskImage]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("REVIEW FIRST").font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Tokens.textSecondary)
            ForEach(risks.prefix(12)) { risk in
                Button { state.openImage(id: risk.imageId) } label: {
                    HStack(spacing: 8) {
                        Text(String(format: "%.0f", risk.score))
                            .font(.system(size: 11, weight: .bold, design: .monospaced))
                            .foregroundStyle(risk.score > 45 ? Tokens.danger : Tokens.warning)
                            .frame(width: 28, alignment: .trailing)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(risk.fileName).font(.system(size: 11.5, weight: .medium))
                                .foregroundStyle(Tokens.text).lineLimit(1)
                            Text(risk.reasons.joined(separator: " · "))
                                .font(.system(size: 9.5)).foregroundStyle(Tokens.textTertiary)
                                .lineLimit(1)
                        }
                        Spacer(); Image(systemName: "chevron.right")
                            .font(.system(size: 9)).foregroundStyle(Tokens.textTertiary)
                    }.padding(.vertical, 4).contentShape(Rectangle())
                }.buttonStyle(.plain)
            }
        }.padding(.horizontal, 18).padding(.vertical, 14)
    }

    private func load(force: Bool) async {
        loading = true
        snapshot = await state.batchInsights(force: force)
        loading = false
    }
}

private struct CachedBarPlot: View {
    let values: [Int]
    let color: Color
    var body: some View {
        Canvas { context, size in
            let maximum = max(1, values.max() ?? 1)
            let gap: CGFloat = 2
            let width = max(1, (size.width - gap * CGFloat(max(0, values.count - 1)))
                            / CGFloat(max(1, values.count)))
            for (index, value) in values.enumerated() {
                let fraction = CGFloat(value) / CGFloat(maximum)
                let height = max(value > 0 ? 2 : 0, size.height * fraction)
                let rect = CGRect(x: CGFloat(index) * (width + gap),
                                  y: size.height - height, width: width, height: height)
                context.fill(Path(roundedRect: rect, cornerRadius: 2), with: .color(color))
            }
        }
    }
}
