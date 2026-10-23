import SwiftUI

struct WorkbenchReviewView: View {
    @Bindable var session: WorkbenchSession
    @Bindable var review: WorkbenchReviewState
    var embedded = false
    @Environment(\.dismiss) private var dismiss
    @State private var tab = "queue"
    @State private var imageIDs: Set<String> = []
    @State private var name = "Random quality control"
    @State private var unit = "image"
    @State private var sampleSize = 10
    @State private var seed = 42
    @State private var acceptedOnly = true
    @State private var blinded = true
    @State private var requiredReviews = 2
    @State private var reviewerOne = ""
    @State private var reviewerTwo = ""
    @State private var reviewerOneID = UUID().uuidString
    @State private var reviewerTwoID = UUID().uuidString
    @State private var allTimePoints = true
    @State private var flagState = "accepted"
    @State private var flagReason = ""
    @State private var decisionReason = ""
    @State private var errorType = "other"
    @State private var revealReason = ""
    @State private var showMasks = true
    @State private var slicePlane = "xy"
    @State private var sliceIndex = 0
    private var hasReason: Bool { !decisionReason.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    private var itemStale: Bool { review.selectedItem?["stale"].bool == true }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Review and quality control").font(.title2)
                WorkbenchSavedRecordAccess(session: session, catalogues: ["reviewSessions"])
                Spacer()
                Button("Refresh", action: session.loadReviews)
                if !embedded { Button("Done") { dismiss() } }
            }.disabled(session.busy)
            Text("Reviewer identities are declared locally and recorded with decisions. They are not authenticated accounts.")
                .font(.caption).foregroundStyle(.secondary)
            if let error = session.error { Text(error).foregroundStyle(.red).textSelection(.enabled) }
            Picker("Review section", selection: $tab) {
                Text("Review queue").tag("queue")
                Text("Create sample").tag("create")
                Text("Quality summary").tag("summary")
            }.pickerStyle(.segmented).disabled(session.busy)
            if tab == "create" { setup }
            else if tab == "summary" { summary }
            else { queue }
            HStack {
                if session.busy { ProgressView().controlSize(.small) }
                Text(session.status).font(.caption).foregroundStyle(.secondary)
                Spacer()
            }
        }.padding(embedded ? 16 : 24)
        .frame(width: embedded ? nil : 1120, height: embedded ? nil : 760)
        .frame(maxWidth: .infinity, maxHeight: .infinity).background(.background)
        .task {
            imageIDs = Set(session.selectedImage.map { session.viewingVolume ? ($0.volumeFrameCount > 0 ? [$0.id] : []) : ($0.cellCount != nil ? [$0.id] : []) } ?? [])
            session.loadReviews()
        }
        .onChange(of: review.selectedItemID) { _, _ in decisionReason = ""; errorType = "other" }
        .onChange(of: review.reviewerID) { _, _ in decisionReason = ""; errorType = "other" }
        .onChange(of: review.previewInfo) { _, value in
            slicePlane = value?["plane"].string ?? "xy"
            sliceIndex = (value?["index"].integer ?? 0) + 1
        }
    }

    private var setup: some View {
        HSplitView {
            VStack(alignment: .leading, spacing: 10) {
                Text("Sampling population").font(.headline)
                Text(session.viewingVolume
                    ? "Saved 3D analyses · Channel \(session.volume.channel + 1)"
                    : "Saved 2D analyses").font(.caption).foregroundStyle(.secondary)
                if session.viewingVolume { Toggle("Include all time points", isOn: $allTimePoints) }
                WorkbenchImageSelection(session: session, selection: $imageIDs,
                    eligible: { session.viewingVolume ? $0.volumeFrameCount > 0 : $0.cellCount != nil }, title: "Analyzed acquisitions",
                    filters: ["analysisTarget": .string(session.viewingVolume ? "volume" : "plane")])
                Text("Classify selected current inputs").font(.headline)
                Picker("State", selection: $flagState) {
                    Text("Accepted").tag("accepted")
                    Text("Needs review").tag("needs-review")
                    Text("Unclassified").tag("unclassified")
                }
                TextField("Classification note (optional)", text: $flagReason).textFieldStyle(.roundedBorder)
                Button("Save classification") {
                    session.flagReviewImages(imageIDs: imageIDs, state: flagState, reason: flagReason, allTimePoints: allTimePoints)
                }.disabled(imageIDs.isEmpty)
            }.padding(.trailing, 14).frame(minWidth: embedded ? 360 : 430)
            ScrollView {
                VStack(alignment: .leading, spacing: 11) {
                    TextField("Review session name", text: $name).textFieldStyle(.roundedBorder)
                    Picker("Sample unit", selection: $unit) {
                        Text("Whole images / time frames").tag("image")
                        Text("Detected objects").tag("cell")
                    }
                    Stepper("Requested sample: \(sampleSize)", value: $sampleSize, in: 1...1000)
                    TextField("Random seed", value: $seed, format: .number).textFieldStyle(.roundedBorder)
                    Toggle("Sample apparently accepted results only", isOn: $acceptedOnly)
                    Toggle("Hide image identities and prior decisions", isOn: $blinded)
                    Picker("Required independent reviews", selection: $requiredReviews) {
                        Text("One").tag(1); Text("Two").tag(2)
                    }
                    TextField("First reviewer name", text: $reviewerOne).textFieldStyle(.roundedBorder)
                    if requiredReviews == 2 {
                        TextField("Second reviewer name", text: $reviewerTwo).textFieldStyle(.roundedBorder)
                    }
                    Text("Sampling is random and reproducible from the seed. Whole-image checks can catch missed objects; sampling detected objects cannot estimate objects missed by every detector.")
                        .font(.caption).foregroundStyle(.secondary)
                    Button("Freeze random sample") {
                        var reviewers = [(id: reviewerOneID, name: reviewerOne.trimmingCharacters(in: .whitespacesAndNewlines))]
                        if requiredReviews == 2 {
                            reviewers.append((id: reviewerTwoID, name: reviewerTwo.trimmingCharacters(in: .whitespacesAndNewlines)))
                        }
                        session.createReview(name: name, imageIDs: imageIDs, allTimePoints: allTimePoints, unit: unit,
                            sampleSize: sampleSize, seed: seed, acceptedOnly: acceptedOnly, blinded: blinded,
                            reviewers: reviewers, requiredReviews: requiredReviews)
                        tab = "queue"
                    }.buttonStyle(.borderedProminent)
                        .disabled(imageIDs.isEmpty || name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ||
                            reviewerOne.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ||
                            (requiredReviews == 2 && reviewerTwo.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) ||
                            seed < 0 || seed > 4_294_967_295)
                }.padding(.leading, 14)
            }.frame(minWidth: embedded ? 360 : 430)
        }.disabled(session.busy)
    }

    private var sessionPicker: some View {
        Picker("Review session", selection: Binding(get: { review.selectedSessionID }, set: session.selectReviewSession)) {
            Text("Select a session").tag("")
            ForEach(Array(review.sessions.enumerated()), id: \.offset) { _, value in
                Text(value["name"].string ?? "Review").tag(value["id"].string ?? "")
            }
        }.disabled(session.busy)
    }

    private var queue: some View {
        VStack(alignment: .leading, spacing: 10) {
            sessionPicker
            if let current = review.session {
                HStack {
                    Picker("Declared reviewer", selection: Binding(get: { review.reviewerID }, set: session.selectReviewer)) {
                        ForEach(Array(current["reviewers"].array.enumerated()), id: \.offset) { _, reviewer in
                            Text(reviewer["name"].string ?? "Reviewer").tag(reviewer["id"].string ?? "")
                        }
                    }.frame(maxWidth: 380).disabled(session.busy)
                    Text(review.blinded ? "Presentation blinded" : "Presentation unblinded")
                        .font(.caption).foregroundStyle(review.blinded ? Color.secondary : Color.orange)
                    Spacer()
                    Text("\(current["sampleSize"].integer ?? 0) sampled from \(current["populationSize"].integer ?? 0)")
                        .font(.caption.monospacedDigit())
                }
                HSplitView {
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 5) {
                            ForEach(Array(review.items.enumerated()), id: \.offset) { _, item in
                                Button {
                                    if let id = item["id"].string { session.selectReviewItem(id) }
                                } label: {
                                    VStack(alignment: .leading, spacing: 3) {
                                        Text(item["code"].string ?? "Review item").font(.headline)
                                        Text(item["ownDecision"]["decision"].string?.capitalized ?? "Not reviewed by you")
                                            .font(.caption).foregroundStyle(.secondary)
                                        if item["stale"].bool == true { Text("Inputs changed").font(.caption).foregroundStyle(.orange) }
                                    }.frame(maxWidth: .infinity, alignment: .leading).padding(8)
                                        .background(review.selectedItemID == item["id"].string ? Color.accentColor.opacity(0.12) : .clear)
                                }.buttonStyle(.plain).disabled(session.busy)
                            }
                        }
                    }.frame(minWidth: 150, idealWidth: 180, maxWidth: 220)
                    reviewImage.frame(minWidth: embedded ? 320 : 400)
                    decisionControls.frame(minWidth: embedded ? 250 : 270, idealWidth: 290).padding(.leading, 10)
                }
            } else {
                ContentUnavailableView("No review sample selected", systemImage: "checklist",
                    description: Text("Create a reproducible sample from analyzed images."))
            }
        }
    }

    private var reviewImage: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(review.selectedItem?["code"].string ?? "Frozen review image").font(.headline)
                Spacer()
                Toggle("Masks", isOn: $showMasks).toggleStyle(.checkbox)
            }
            if !review.blinded, let imageName = review.selectedItem?["imageName"].string {
                Text(imageName).font(.caption).foregroundStyle(.secondary)
            }
            if let image = showMasks ? review.overlay : review.preview {
                GeometryReader { geometry in
                    ScrollView([.horizontal, .vertical]) {
                        Image(nsImage: image).resizable().scaledToFit()
                            .frame(width: max(geometry.size.width, min(image.size.width, 2048)),
                                   height: max(geometry.size.height, min(image.size.height, 2048)))
                    }
                }
            } else { ContentUnavailableView("Select an item", systemImage: "photo") }
            if review.previewInfo?["plane"].string != nil {
                HStack {
                    Picker("Plane", selection: $slicePlane) {
                        Text("XY").tag("xy"); Text("XZ").tag("xz"); Text("YZ").tag("yz")
                    }.frame(width: 125)
                    TextField("Slice (1-based)", value: $sliceIndex, format: .number).frame(width: 80)
                    if let count = review.previewInfo?["sliceCount"].integer, count > 0 {
                        Stepper("", value: $sliceIndex, in: 1...count).labelsHidden()
                        Text("of \(count)").font(.caption)
                    }
                    Button("Load slice") { session.loadReviewSlice(plane: slicePlane, index: max(0, sliceIndex - 1)) }
                    Button("Center") { session.loadReviewSlice(plane: slicePlane, index: nil) }
                }.disabled(session.busy || sliceIndex < 1)
            }
            if let info = review.previewInfo {
                Text("Frozen crop \(info["region"]["width"].integer ?? 0) × \(info["region"]["height"].integer ?? 0) source pixels · Preview \(info["previewWidth"].integer ?? 0) × \(info["previewHeight"].integer ?? 0)")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }.padding(.horizontal, 10)
    }

    private var decisionControls: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                Text("Your decision").font(.headline)
                if itemStale {
                    Text("The analysis changed after sampling. This snapshot remains inspectable; create a new sample to review current inputs.")
                        .font(.caption).foregroundStyle(.orange)
                }
                TextField("Reason for rejection, uncertainty or adjudication", text: $decisionReason, axis: .vertical)
                    .textFieldStyle(.roundedBorder).lineLimit(3...5)
                Picker("Error category", selection: $errorType) {
                    ForEach(["missed-object", "false-positive", "boundary", "merge", "split", "other"], id: \.self) {
                        Text($0.replacingOccurrences(of: "-", with: " ").capitalized).tag($0)
                    }
                }
                HStack {
                    Button("Accept") { session.recordReview(decision: "accept", reason: decisionReason, errorType: "none") }
                    Button("Reject") { session.recordReview(decision: "reject", reason: decisionReason, errorType: errorType) }
                        .disabled(!hasReason)
                    Button("Unsure") { session.recordReview(decision: "uncertain", reason: decisionReason, errorType: errorType) }
                        .disabled(!hasReason)
                }.disabled(itemStale || review.reviewerID.isEmpty || review.selectedItemID.isEmpty)
                if let item = review.selectedItem, !item["decisions"].array.isEmpty {
                    Divider()
                    Text("Recorded decisions").font(.headline)
                    ForEach(Array(item["decisions"].array.enumerated()), id: \.offset) { _, decision in
                        Text("\(decision["reviewerName"].string ?? decision["reviewerId"].string ?? "Reviewer"): \(decision["decision"].string ?? "")")
                            .font(.caption)
                        if let reason = decision["reason"].string { Text(reason).font(.caption).foregroundStyle(.secondary) }
                    }
                    if (item["reviewCount"].integer ?? 0) >= (item["requiredReviews"].integer ?? 1) {
                        Text("Adjudicate with a reason").font(.caption.weight(.medium))
                        HStack {
                            Button("Accept") { session.recordReview(decision: "accept", reason: decisionReason, errorType: "none", adjudicate: true) }
                            Button("Reject") { session.recordReview(decision: "reject", reason: decisionReason, errorType: errorType, adjudicate: true) }
                        }.disabled(!hasReason || itemStale)
                    }
                }
                Divider()
                if review.blinded {
                    DisclosureGroup("End presentation blinding") {
                        TextField("Reason for revealing identities", text: $revealReason, axis: .vertical)
                            .textFieldStyle(.roundedBorder)
                        Text("This records an event and reveals identities for the entire session.")
                            .font(.caption).foregroundStyle(.secondary)
                        Button("Record reason and reveal") { session.revealReview(reason: revealReason) }
                            .disabled(revealReason.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                }
            }.padding(2)
        }.disabled(session.busy)
    }

    private var summary: some View {
        VStack(alignment: .leading, spacing: 12) {
            sessionPicker
            Button("Calculate quality summary", action: session.summarizeReview).disabled(session.busy)
            if let result = review.summary {
                if result["sessions"].array.contains(where: { $0["outcomesHidden"].bool == true }) {
                    Text("Outcome counts and agreement estimates are withheld while presentation blinding is active. Reveal the session with a recorded reason to inspect those results.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                WorkbenchStructuredOutput(value: result)
            } else {
                Text("Summaries report review workload, disagreement, rejection fractions and approximate Wilson intervals. Only decisions on current inputs enter the estimates.")
                    .foregroundStyle(.secondary)
                Spacer()
            }
        }
    }
}
