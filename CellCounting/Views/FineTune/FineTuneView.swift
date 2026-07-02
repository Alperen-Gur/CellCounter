import SwiftUI

// MARK: — Shared state types

struct FTTrainState {
    var epoch: Int = 0
    var loss: Double = 2.4
    var vloss: Double = 2.5
    var eta: Int = 840
    var running: Bool = true
}

struct FTCurve {
    var train: [Double] = []
    var val: [Double] = []
}

struct FTMetrics {
    var ap50: Double
    var f1: Double
    var precision: Double
    var recall: Double
    var meanDiamError: Double
}

private let FT_STEPS = ["Dataset", "Annotate", "Split", "Configure", "Train", "Evaluate"]

struct FineTuneView: View {
    @Bindable var state: AppState

    @State private var step: Int = 0
    @State private var imageCount: Int = 0
    @State private var annotated: Int = 0
    @State private var trainPct: Int = 70
    @State private var valPct: Int = 20
    @State private var baseModel: String = "cp-cyto3"
    @State private var epochs: Int = 40
    @State private var lr: Double = 0.0002
    @State private var batchSize: Int = 8
    @State private var augment: Bool = true
    // Advanced toggles propagated to the Python sidecar args.
    @State private var earlyStop: Bool = true
    @State private var mixedPrecision: Bool = true
    @State private var training = FTTrainState()
    @State private var trainCurve = FTCurve()
    @State private var metrics: FTMetrics? = nil
    @State private var datasetURLs: [URL] = []
    @StateObject private var trainer = TrainingService()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                header
                stepper
                    .padding(.bottom, 22)

                switch step {
                case 0:
                    StepDataset(state: state,
                                imageCount: $imageCount, annotated: $annotated,
                                datasetURLs: $datasetURLs,
                                onNext: { step = 1 })
                case 1:
                    StepAnnotate(state: state,
                                 imageCount: imageCount, annotated: $annotated,
                                 onNext: { step = 2 }, onBack: { step = 0 })
                case 2:
                    StepSplit(imageCount: imageCount,
                              trainPct: $trainPct, valPct: $valPct,
                              onNext: { step = 3 }, onBack: { step = 1 })
                case 3:
                    StepConfigure(baseModel: $baseModel, epochs: $epochs,
                                  lr: $lr, batchSize: $batchSize, augment: $augment,
                                  earlyStop: $earlyStop,
                                  mixedPrecision: $mixedPrecision,
                                  trainer: trainer,
                                  onNext: { step = 4 }, onBack: { step = 2 })
                case 4:
                    StepTrain(epochs: epochs,
                              baseModel: baseModel, lr: lr,
                              batchSize: batchSize, augment: augment,
                              earlyStop: earlyStop,
                              mixedPrecision: mixedPrecision,
                              datasetURLs: datasetURLs, annotated: annotated,
                              training: $training, curve: $trainCurve,
                              trainer: trainer,
                              onComplete: { m in
                                  metrics = m
                                  step = 5
                              },
                              onBack: { step = 3 })
                default:
                    StepEvaluate(state: state,
                                 metrics: metrics, curve: trainCurve,
                                 trainer: trainer,
                                 imageCount: imageCount, annotated: annotated,
                                 onRestart: {
                                     trainer.cancel()
                                     trainCurve = FTCurve()
                                     training = FTTrainState()
                                     metrics = nil
                                     imageCount = 0
                                     annotated = 0
                                     datasetURLs = []
                                     step = 0
                                 },
                                 onDone: { state.view = .home })
                }
            }
            .frame(maxWidth: 1100, alignment: .leading)
            .padding(.horizontal, 32)
            .padding(.vertical, 24)
            .frame(maxWidth: .infinity, alignment: .top)
        }
        .background(Tokens.bg)
        // ⌘← / ⌘→ step navigation
        .onKeyPress(keys: [.leftArrow]) { press in
            guard press.modifiers.contains(.command), step > 0 else { return .ignored }
            step -= 1
            return .handled
        }
        .onKeyPress(keys: [.rightArrow]) { press in
            guard press.modifiers.contains(.command), step < FT_STEPS.count - 1 else { return .ignored }
            step += 1
            return .handled
        }
        // Space — pause / resume training (only on step 4 — Train)
        .onKeyPress(.space) {
            guard step == 4 else { return .ignored }
            if training.running {
                trainer.pause()
                training.running = false
            } else {
                trainer.resume()
                training.running = true
            }
            return .handled
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Fine-tune a model")
                .font(.system(size: 22, weight: .bold))
                .tracking(-0.44)
                .foregroundStyle(Tokens.text)
            Text("Train Cellpose or YOLO on your patient-derived samples — runs locally on this Mac.")
                .font(.system(size: 13))
                .foregroundStyle(Tokens.textTertiary)
        }
        .padding(.bottom, 14)
    }

    private var stepper: some View {
        HStack(spacing: 8) {
            ForEach(FT_STEPS.indices, id: \.self) { i in
                FTStepPill(index: i, label: FT_STEPS[i], currentStep: step)
                if i < FT_STEPS.count - 1 {
                    Rectangle()
                        .fill(Tokens.border)
                        .frame(width: 18, height: 1)
                }
            }
            Spacer()
        }
    }
}

// MARK: — Stepper pill

private struct FTStepPill: View {
    let index: Int
    let label: String
    let currentStep: Int
    @Environment(AppTheme.self) private var theme

    var body: some View {
        let active = index == currentStep
        let done = index < currentStep

        HStack(spacing: 8) {
            ZStack {
                Circle()
                    .fill(active ? Color.white.opacity(0.25)
                          : Color.black.opacity(0.12))
                    .frame(width: 18, height: 18)
                if done {
                    Image(systemName: "checkmark")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(active ? .white : theme.accentColor)
                } else {
                    Text("\(index + 1)")
                        .font(.system(size: 10.5, weight: .bold))
                        .foregroundStyle(active ? .white : (done ? theme.accentColor : Tokens.textTertiary))
                }
            }
            Text(label)
                .font(.system(size: 12.5, weight: active ? .semibold : .medium))
                .foregroundStyle(active ? .white
                                 : done ? theme.accentColor
                                 : Tokens.textTertiary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(
            Capsule().fill(active ? theme.accentColor
                           : done ? theme.accentSoft
                           : Tokens.bgSunken)
        )
    }
}

// MARK: — Shared "card" container

struct FTCard<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        content
            .padding(.horizontal, 24)
            .padding(.vertical, 22)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: Tokens.Radius.lg, style: .continuous)
                    .fill(Tokens.bgElevated)
            )
            .overlay(
                RoundedRectangle(cornerRadius: Tokens.Radius.lg, style: .continuous)
                    .strokeBorder(Tokens.border, lineWidth: 0.5)
            )
    }
}

struct FTSectionTitle: View {
    let title: String
    let desc: String?
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.system(size: 16, weight: .semibold))
                .tracking(-0.16)
                .foregroundStyle(Tokens.text)
            if let desc {
                Text(desc)
                    .font(.system(size: 13))
                    .foregroundStyle(Tokens.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.bottom, 18)
    }
}

// MARK: — Footer bar

struct FTFooterBar: View {
    var onBack: (() -> Void)? = nil
    var backLabel: String = "Back"
    var onNext: (() -> Void)? = nil
    var nextLabel: String = "Continue"
    var nextDisabled: Bool = false
    var primary: Bool = true

    var body: some View {
        HStack {
            if let onBack {
                Button(action: onBack) {
                    Text(backLabel)
                }
                .appButton(.standard, size: .md)
            } else {
                Spacer().frame(width: 0)
            }
            Spacer()
            if let onNext {
                Button(action: { if !nextDisabled { onNext() } }) {
                    HStack(spacing: 6) {
                        Text(nextLabel)
                        Icon("arrow", size: 12)
                    }
                }
                .appButton(primary ? .primary : .standard, size: .md)
                .disabled(nextDisabled)
                .opacity(nextDisabled ? 0.5 : 1)
            }
        }
        .padding(.top, 18)
    }
}
