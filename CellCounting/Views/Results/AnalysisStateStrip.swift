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
                    // This image's own scale: the one its numbers are at.
                    if let scale = image.currentScale {
                        Text(ImageScale.caption(scale))
                            .foregroundStyle(Tokens.textSecondary)
                            .help("Every size of this image in µm uses this scale (\(scale.source)).")
                    } else {
                        Text("No scale").foregroundStyle(Tokens.warning)
                            .help(ImageScale.missingMessage)
                    }
                    if let run {
                        Text("Run: channel \(run.segmentChannel < 0 ? "composite" : String(run.segmentChannel + 1)) · Z \(run.zProjection)")
                        Text("Cell size: " + SizeHint.summary(SizeHint.resolve(run)))
                            .lineLimit(1)
                            .help("Expected cell size used to scale the image for segmentation")
                    } else if detection != nil {
                        Text("Original channel, projection and preprocessing were not recorded.")
                    } else {
                        Text("Preview the image and confirm settings before detection.")
                    }
                    Spacer(minLength: 0)
                    if let status = state.jobStatus(for: image.id) { Text(status).foregroundStyle(Color.accentColor) }
                }.foregroundStyle(Tokens.textTertiary)
                if let note = ImageScale.segmentationNote(segmented: run?.pxPerUm, measured: image.measuredScale?.pxPerUm) {
                    Text(note + " · outlines kept from the earlier scale")
                        .foregroundStyle(Tokens.warning)
                        .help("Sizes were converted to the new scale without segmenting again. Re-run to segment at the new scale.")
                }
                if let notice = ImageScale.notice(measured: image.measuredScale, effective: image.effectiveScale) {
                    HStack(spacing: 10) {
                        Label(notice.text, systemImage: "exclamationmark.triangle")
                            .foregroundStyle(Tokens.warning)
                            .lineLimit(2)
                        Spacer(minLength: 0)
                        Button("Re-run at \(ImageScale.format(image.effectiveScale?.pxPerUm ?? 0)) px/µm") {
                            state.reRunDetection(on: image, useSavedSettings: true)
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(Color.accentColor)
                        .disabled(!state.canRerunSavedImage(image))
                        if case .fileDisagrees(let measured, _) = notice {
                            Button("Keep \(ImageScale.format(measured))") { state.keepMeasuredScale(of: image) }
                                .buttonStyle(.plain)
                                .foregroundStyle(Color.accentColor)
                                .help("Keep these numbers and record \(ImageScale.format(measured)) px/µm as your override of the file's scale.")
                        }
                    }
                }
            }
            .font(.system(size: 10.5))
            .padding(.horizontal, 16).padding(.vertical, 7)
            .background(Tokens.bgSunken)
        }
    }
}
