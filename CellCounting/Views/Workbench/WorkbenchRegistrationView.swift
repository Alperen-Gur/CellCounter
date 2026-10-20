import AppKit
import SwiftUI

struct WorkbenchRegistrationView: View {
    @Bindable var session: WorkbenchSession
    @Bindable var registration: WorkbenchRegistrationState
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var displayMode = "overlay"
    private var fixed: WorkbenchImage? { session.images.first { $0.id == registration.fixedID } }
    private var moving: WorkbenchImage? { session.images.first { $0.id == registration.movingID } }
    private var canEstimate: Bool {
        guard let fixed, let moving else { return false }
        return fixed.id != moving.id && fixed.width == moving.width && fixed.height == moving.height &&
            Double(fixed.width) * Double(fixed.height) <= 4_000_000 &&
            registration.maximumShift.isFinite && registration.maximumShift > 0 && registration.maximumShift <= 1_000_000
    }
    private var displayedImage: NSImage? {
        switch displayMode {
        case "fixed": return registration.fixedPreview
        case "moving": return registration.preview
        case "support": return registration.supportPreview
        default: return registration.overlay
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Image registration").font(.title2)
                Spacer()
                Button("Done") { dismiss() }.disabled(session.busy)
            }
            Text("Estimate or specify a 2D translation, inspect overlap and save a new image on the fixed grid. Rotation, scale and deformation are not estimated.")
                .font(.callout).foregroundStyle(.secondary)
            if let error = session.error { Text(error).foregroundStyle(.red).textSelection(.enabled) }
            HSplitView {
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        WorkbenchRegistrationSourceControls(session: session, title: "Fixed reference",
                            imageID: $registration.fixedID, channel: $registration.fixedChannel,
                            timeIndex: $registration.fixedTime, projection: $registration.fixedProjection)
                        WorkbenchRegistrationSourceControls(session: session, title: "Moving source",
                            imageID: $registration.movingID, channel: $registration.movingChannel,
                            timeIndex: $registration.movingTime, projection: $registration.movingProjection)
                        DisclosureGroup("Translation estimation") {
                            VStack(alignment: .leading, spacing: 8) {
                                Stepper("Subpixel upsampling: \(registration.upsampleFactor)",
                                        value: $registration.upsampleFactor, in: 1...100)
                                number("Maximum shift (pixels)", value: $registration.maximumShift)
                                Picker("Window", selection: $registration.window) {
                                    Text("Hann").tag("hann"); Text("None").tag("none")
                                }
                                Button("Estimate translation", action: session.estimateRegistration).disabled(!canEstimate)
                                Text("Estimation requires equal XY dimensions and at most 4 million pixels. Explicit shifts can be applied on a fixed grid up to 16 million pixels.")
                                    .font(.caption).foregroundStyle(.secondary)
                            }.padding(.top, 6)
                        }
                        number("X shift (pixels; positive moves right)", value: $registration.shiftX)
                        number("Y shift (pixels; positive moves down)", value: $registration.shiftY)
                        Picker("Interpolation", selection: $registration.interpolation) {
                            Text("Linear").tag("linear"); Text("Nearest").tag("nearest")
                        }
                        number("Fill outside measured support", value: $registration.fillValue)
                        TextField("Registered image name (optional)", text: $name).textFieldStyle(.roundedBorder)
                        HStack {
                            Button("Preview") { session.applyRegistration(name: name, previewOnly: true) }
                            Button("Save registered image") { session.applyRegistration(name: name, previewOnly: false) }
                                .buttonStyle(.borderedProminent)
                        }.disabled(!registration.validTransform || fixed == nil || moving == nil)
                        Text("Known XY pixel sizes must match. Output calibration comes from the fixed grid. A new analysis is required for the registered pixels.")
                            .font(.caption).foregroundStyle(.secondary)
                    }.padding(.trailing, 12)
                }.frame(minWidth: 340, idealWidth: 390, maxWidth: 430).disabled(session.busy)
                VStack(alignment: .leading, spacing: 10) {
                    Picker("Preview", selection: $displayMode) {
                        Text("Overlay").tag("overlay"); Text("Fixed").tag("fixed")
                        Text("Registered moving").tag("moving"); Text("Valid support").tag("support")
                    }.pickerStyle(.segmented)
                    if registration.previewCurrent, let image = displayedImage {
                        Image(nsImage: image).resizable().scaledToFit()
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                        if displayMode == "support" {
                            Text("White pixels have measured source support. Black pixels use the specified fill value.")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    } else {
                        ContentUnavailableView("Preview registration", systemImage: "square.3.layers.3d",
                            description: Text("Choose the two sources and a translation, then preview the aligned pixels and valid support."))
                    }
                    if registration.estimateContext == .object(registration.selection), let estimate = registration.estimate {
                        DisclosureGroup("Estimation quality and calibration") {
                            WorkbenchStructuredOutput(value: .object(["quality": estimate["quality"],
                                "calibration": estimate["calibration"], "convention": estimate["convention"]]))
                                .frame(height: 160)
                        }
                    }
                    if registration.previewCurrent, let support = registration.support {
                        Text("Valid support: \(100 * (support["overlapFraction"].number ?? 0), specifier: "%.1f")% · \(support["validPixelCount"].integer ?? 0) measured pixels · \(support["invalidPixelCount"].integer ?? 0) filled pixels")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }.padding(.leading, 12).frame(minWidth: 560)
            }
            HStack {
                if session.busy { ProgressView().controlSize(.small) }
                Text(session.status).font(.caption).foregroundStyle(.secondary)
                Spacer()
            }
        }.padding(24).frame(width: 1120, height: 760)
        .task { session.loadRegistration() }
        .onChange(of: registration.lastCreatedImageID) { _, id in if id != nil { dismiss() } }
    }
    private func number(_ title: String, value: Binding<Double>) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).font(.caption)
            TextField(title, value: value, format: .number).textFieldStyle(.roundedBorder)
        }
    }
}

private struct WorkbenchRegistrationSourceControls: View {
    @Bindable var session: WorkbenchSession
    let title: String
    @Binding var imageID: String
    @Binding var channel: Int
    @Binding var timeIndex: Int
    @Binding var projection: String
    private var selected: WorkbenchImage? { session.images.first { $0.id == imageID } }
    var body: some View {
        GroupBox(title) {
            VStack(alignment: .leading, spacing: 8) {
                WorkbenchImageChoice(session: session, selection: $imageID, title: "Image")
                if let image = selected {
                    Text("\(image.width) × \(image.height)").font(.caption).foregroundStyle(.secondary)
                    Picker("Channel", selection: $channel) {
                        ForEach(0..<image.channels, id: \.self) { Text("Channel \($0 + 1)").tag($0) }
                    }
                    if image.timeCount > 1 {
                        Stepper("Time \(timeIndex + 1)", value: $timeIndex, in: 0...(image.timeCount - 1))
                    }
                    if image.zCount > 1 {
                        Picker("Z projection", selection: $projection) {
                            Text("Maximum").tag("max"); Text("Mean").tag("mean"); Text("Middle").tag("middle")
                        }
                    }
                }
            }.padding(5)
        }.onChange(of: imageID) { _, _ in resetSelection() }
            .onAppear { resetSelection() }
    }
    private func resetSelection() {
        guard let image = selected else { return }
        let source = image.parameters ?? image.preferredSourceParameters
        channel = min(image.channels - 1, max(0, source["channel"].integer ?? 0))
        timeIndex = min(image.timeCount - 1, max(0, image.preferredVolumeSelection["timeIndex"].integer ?? 0))
        projection = source["zProjection"].string ?? "max"
    }
}
