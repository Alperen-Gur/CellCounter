import SwiftUI

/// The strip stays beside the image while tools change. Run settings come from
/// the detection, never the model or preprocessing currently selected for later work.
struct AnalysisStateStrip: View {
    @Bindable var state: AppState
    var body: some View {
        if let image = state.currentImage {
            let detection = image.detection
            let run = detection?.runSettings
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 9) {
                    Label(AnalysisStateDescription.model(detectorId: detection?.detectorId,
                                                         savedModelName: run?.modelName),
                          systemImage: detection == nil ? "circle.dotted" : "checkmark.circle")
                        .lineLimit(1).help(detection?.detectorId ?? "No saved detection")
                    Spacer(minLength: 0)
                    Text(AnalysisStateDescription.review(pending: detection?.reviewPendingCount,
                                                          correctionCount: detection?.corrections.count ?? 0))
                        .foregroundStyle(Tokens.textTertiary)
                    if let batch = image.batch {
                        Button("Analysis setup…") { state.openAnalysisSetup(for: batch) }.buttonStyle(.plain)
                    }
                }
                HStack(spacing: 10) {
                    if let run {
                        Text("Run: channel \(run.segmentChannel < 0 ? "composite" : String(run.segmentChannel + 1)) · Z \(run.zProjection)")
                        Text(String(format: "%.3g px/µm at analysis", run.pxPerUm))
                            .help(run.calibrationSource)
                    } else if detection != nil {
                        Text("Original channel, projection and preprocessing were not recorded.")
                    } else {
                        Text("Preview the image and confirm settings before detection.")
                    }
                    Spacer(minLength: 0)
                    if let status = state.jobStatus(for: image.id) { Text(status).foregroundStyle(Color.accentColor) }
                }.foregroundStyle(Tokens.textTertiary)
                if let run, let batch = image.batch, abs(batch.pxPerUm - run.pxPerUm) > 0.000001 {
                    Text(String(format: "Measurements recalibrated to %.3g px/µm · original run calibration retained", batch.pxPerUm))
                        .foregroundStyle(Tokens.warning)
                }
            }
            .font(.system(size: 10.5))
            .padding(.horizontal, 16).padding(.vertical, 7)
            .background(Tokens.bgSunken)
        }
    }
}
