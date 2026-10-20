import AppKit
import SwiftUI

struct WorkbenchMaskComparisonView: View {
    @Bindable var session: WorkbenchSession
    @Bindable var comparison: WorkbenchMaskComparisonState
    @Environment(\.dismiss) private var dismiss
    @State private var imageMode = "overlay"

    private var left: WorkbenchImage? { session.images.first { $0.id == comparison.leftID } }
    private var sliceCount: Int {
        guard let left else { return 1 }
        switch comparison.plane {
        case "xz": return left.height
        case "yz": return left.width
        default: return left.zCount
        }
    }
    private var canCompare: Bool {
        guard let left, !comparison.rightID.isEmpty else { return false }
        return comparison.target == "volume" ? left.volumeFrameCount > 0 : left.cellCount != nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Compare saved masks").font(.title2)
                Spacer()
                Button("Done") { dismiss() }.disabled(session.busy)
            }
            Text("Compare two saved analyses of the same source grid. Agreement is descriptive; it does not establish accuracy without a reviewed reference.")
                .font(.callout).foregroundStyle(.secondary)
            if let error = session.error { Text(error).foregroundStyle(.red).textSelection(.enabled) }
            HSplitView {
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Left: \(left?.name ?? "Select an image")").font(.headline)
                        WorkbenchImageChoice(session: session, selection: $comparison.rightID, title: "Right analysis",
                            eligible: { $0.id != comparison.leftID },
                            filters: ["sourceHash": .string(left?.sourceHash ?? ""), "analysisTarget": .string(comparison.target)])
                        if comparison.target == "volume", let left {
                            Stepper("Time \(comparison.timeIndex + 1)", value: $comparison.timeIndex,
                                    in: 0...(left.timeCount - 1))
                            Picker("Channel", selection: $comparison.channel) {
                                ForEach(0..<left.channels, id: \.self) { Text("Channel \($0 + 1)").tag($0) }
                            }
                            Picker("Overlay plane", selection: $comparison.plane) {
                                Text("XY").tag("xy"); Text("XZ").tag("xz"); Text("YZ").tag("yz")
                            }
                            Stepper("Slice \(comparison.index + 1) of \(sliceCount)",
                                    value: $comparison.index, in: 0...(sliceCount - 1))
                            Text("Measurements compare the entire saved volume. Plane and slice affect only the displayed overlay.")
                                .font(.caption).foregroundStyle(.secondary)
                        } else {
                            Text("Saved 2D masks must use the same Z projection. Their segmentation channels may differ.")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Button("Compare saved masks", action: session.compareSavedMasks)
                            .buttonStyle(.borderedProminent).disabled(!canCompare)
                        if comparison.rightID.isEmpty {
                            Text("Choose a saved mask variant through Search. If none exists, create an independent variant and analyze it.")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        if session.comparisonCurrent, let result = comparison.result {
                            Divider()
                            metrics(result["metrics"])
                            ForEach(result["notes"].array.compactMap(\.string), id: \.self) {
                                Text($0).font(.caption).foregroundStyle(.secondary)
                            }
                            DisclosureGroup("Matched object pairs") {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text("Left ID · Right ID · Intersection over union").fontWeight(.medium)
                                    ForEach(Array(result["pairs"].array.prefix(500).enumerated()), id: \.offset) { _, pair in
                                        Text("\(pair["leftLabelId"].integer ?? 0) · \(pair["rightLabelId"].integer ?? 0) · \(pair["iou"].number ?? 0, specifier: "%.3f")")
                                    }
                                    if result["truncated"].bool == true || result["pairs"].array.count > 500 {
                                        Text("Pair listing is limited. Agreement metrics use the complete analysis.")
                                            .foregroundStyle(.secondary)
                                    }
                                }.font(.caption.monospacedDigit()).textSelection(.enabled)
                            }
                            DisclosureGroup("Unmatched object IDs") {
                                VStack(alignment: .leading, spacing: 8) {
                                    Text("Left: \(labelList(result["unmatchedLeftLabelIds"]))")
                                    Text("Right: \(labelList(result["unmatchedRightLabelIds"]))")
                                    if result["truncated"].bool == true {
                                        Text("The returned ID listing is limited. Metrics include all objects.")
                                            .foregroundStyle(.secondary)
                                    }
                                }.font(.caption.monospacedDigit()).textSelection(.enabled)
                            }
                            DisclosureGroup("Analysis revisions and source selection") {
                                WorkbenchStructuredOutput(value: .object([
                                    "left": result["left"], "right": result["right"], "selection": result["selection"]
                                ])).frame(height: 170)
                            }
                        }
                    }.padding(.trailing, 12)
                }.frame(minWidth: 350, idealWidth: 400).disabled(session.busy)
                VStack(alignment: .leading, spacing: 9) {
                    Picker("Image", selection: $imageMode) {
                        Text("Agreement overlay").tag("overlay"); Text("Source").tag("source")
                    }.pickerStyle(.segmented)
                    if session.comparisonCurrent, let image = imageMode == "overlay" ? comparison.overlay : comparison.source {
                        Image(nsImage: image).resizable().scaledToFit()
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                        if imageMode == "overlay" {
                            HStack {
                                legend("Left only", color: .cyan)
                                legend("Right only", color: Color(red: 1, green: 0, blue: 1))
                                legend("Both", color: .green)
                            }.font(.caption)
                        }
                    } else {
                        ContentUnavailableView("Compare saved analyses", systemImage: "square.on.square",
                            description: Text(comparison.result == nil
                                ? "Choose another mask variant and compare its saved labels."
                                : "The selection or project changed. Compare again for current results."))
                    }
                    Text("Unsaved previews and canvas edits are preserved and excluded from this comparison.")
                        .font(.caption).foregroundStyle(.secondary)
                }.frame(minWidth: 470).padding(.leading, 12)
            }
            HStack {
                if session.busy { ProgressView().controlSize(.small) }
                Text(session.status).font(.caption).foregroundStyle(.secondary)
                Spacer()
            }
        }.padding(24).frame(width: 1100, height: 750)
        .task { session.prepareMaskComparison() }
        .onChange(of: comparison.plane) { _, _ in comparison.index = min(comparison.index, sliceCount - 1) }
    }

    private func legend(_ text: String, color: Color) -> some View {
        HStack(spacing: 4) { Circle().fill(color).frame(width: 8, height: 8); Text(text) }
    }

    private func labelList(_ value: WorkbenchJSON) -> String {
        let ids = value.array.compactMap(\.integer)
        return ids.isEmpty ? "None" : ids.prefix(500).map(String.init).joined(separator: ", ") +
            (ids.count > 500 ? " …" : "")
    }

    private func metrics(_ value: WorkbenchJSON) -> some View {
        Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 6) {
            metric("Left objects", value["leftObjects"], decimal: false)
            metric("Right objects", value["rightObjects"], decimal: false)
            metric("Matched objects", value["matchedObjects"], decimal: false)
            metric("Unmatched left", value["unmatchedLeft"], decimal: false)
            metric("Unmatched right", value["unmatchedRight"], decimal: false)
            metric("Instance F1", value["instanceF1"])
            metric("Instance Jaccard", value["instanceJaccard"])
            metric("Foreground Dice", value["foregroundDice"])
            metric("Foreground Jaccard", value["foregroundJaccard"])
        }.font(.caption).textSelection(.enabled)
    }

    private func metric(_ name: String, _ value: WorkbenchJSON, decimal: Bool = true) -> some View {
        GridRow {
            Text(name)
            Text(value.number.map { decimal ? String(format: "%.3f", $0) : String(format: "%.0f", $0) } ?? "—")
                .monospacedDigit()
        }
    }
}
