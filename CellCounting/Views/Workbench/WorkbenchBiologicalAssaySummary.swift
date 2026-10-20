import Charts
import SwiftUI

struct WorkbenchBiologicalAssaySummary: View {
    @Bindable var session: WorkbenchSession
    @Bindable var assays: WorkbenchAssayState
    @State private var restrictImages = false
    @State private var imageIDs: Set<String> = []

    private struct SpecimenPoint: Identifiable {
        let id: String
        let name: String
        let condition: String
        let value: Double
    }
    private var specimenPoints: [SpecimenPoint] {
        (assays.biologicalSummary?["specimens"].array ?? []).compactMap { value in
            guard value["complete"].bool == true, let id = value["id"].string,
                  let mean = value["mean"].number, mean.isFinite else { return nil }
            return SpecimenPoint(id: id, name: value["name"].string ?? "",
                condition: "\(value["experiment"].string ?? "") · \(value["condition"].string ?? "")", value: mean)
        }
    }

    var body: some View {
        HSplitView {
            ScrollView {
                VStack(alignment: .leading, spacing: 11) {
                    Text("Reference assay recipe").font(.headline)
                    Picker("Saved assay", selection: Binding(get: { assays.summaryRunID }, set: session.loadAssayMetrics)) {
                        Text("Select a saved run").tag("")
                        ForEach(Array(assays.summaryRuns.reversed().enumerated()), id: \.offset) { _, run in
                            Text(runLabel(run)).tag(run["runId"].string ?? "")
                        }
                    }
                    Button("Load metric choices") { session.loadAssayMetrics(runID: assays.summaryRunID) }
                        .disabled(assays.summaryRunID.isEmpty)
                    if let descriptor = assays.metricDescriptor {
                        if descriptor["current"].bool == false {
                            Text("The reference run is out of date. Recompute it in Measurements and assays, then choose the updated result.")
                                .font(.caption).foregroundStyle(.orange)
                        }
                        Picker("Measured output", selection: $assays.metricPath) {
                            ForEach(Array(descriptor["metrics"].array.enumerated()), id: \.offset) { _, metric in
                                Text(metric["path"].string ?? "Metric").tag(metric["path"].string ?? "")
                            }
                        }.onChange(of: assays.metricPath) { _, _ in assays.biologicalSummary = nil }
                        ForEach(descriptor["notes"].array.compactMap(\.string), id: \.self) {
                            Text($0).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    Text("Results must match the same assay parameters, target, time point and channel. Each complete specimen contributes one mean.")
                        .font(.caption).foregroundStyle(.secondary)
                    Toggle("Limit to selected images", isOn: $restrictImages)
                        .onChange(of: restrictImages) { _, _ in assays.biologicalSummary = nil }
                    if restrictImages {
                        WorkbenchImageSelection(session: session, selection: $imageIDs)
                            .onChange(of: imageIDs) { _, _ in assays.biologicalSummary = nil }
                        Text("Selecting part of a specimen leaves it incomplete and excludes it from condition estimates.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Button("Calculate biological assay summary") {
                        session.summarizeBiologicalAssay(imageIDs: restrictImages ? imageIDs : nil)
                    }.buttonStyle(.borderedProminent)
                        .disabled(assays.metricDescriptor?["current"].bool != true ||
                            assays.metricPath.isEmpty || (restrictImages && imageIDs.isEmpty))
                }.padding(.trailing, 12)
            }.frame(minWidth: 290, idealWidth: 320, maxWidth: 360).disabled(session.busy)
            VStack(alignment: .leading, spacing: 10) {
                if let summary = assays.biologicalSummary {
                    Text(summary["metricPath"].string ?? "Assay metric").font(.headline)
                    let unit = summary["unit"].string ?? summary["units"].string
                    if let unit, !unit.isEmpty { Text("Units: \(unit)").font(.caption).foregroundStyle(.secondary) }
                    if !summary["comparison"]["units"].object.isEmpty {
                        Text(summary["comparison"]["units"].object.keys.sorted().compactMap { key in
                            summary["comparison"]["units"][key].string.map { "\(key): \($0)" }
                        }.joined(separator: " · ")).font(.caption).foregroundStyle(.secondary)
                    }
                    Text("Revision \(summary["sourceRevision"].integer ?? 0) · \(selectionLabel(summary["selection"]))")
                        .font(.caption).foregroundStyle(.secondary)
                    if !specimenPoints.isEmpty {
                        Chart(Array(specimenPoints.prefix(500))) { point in
                            PointMark(x: .value("Condition", point.condition), y: .value("Specimen mean", point.value))
                                .foregroundStyle(by: .value("Condition", point.condition))
                                .accessibilityLabel(point.name)
                                .accessibilityValue("\(point.value)")
                        }.chartLegend(.hidden).chartYAxisLabel(unit ?? "Specimen mean")
                            .frame(height: 155)
                        Text("One point per complete biological specimen\(specimenPoints.count > 500 ? " · First 500 shown" : "").")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    TabView {
                        conditionTable(summary).tabItem { Text("Conditions") }
                        WorkbenchStructuredOutput(value: .object(["specimens": summary["specimens"]]))
                            .tabItem { Text("Specimens") }
                        WorkbenchStructuredOutput(value: .object(["images": summary["images"]]))
                            .tabItem { Text("Image completeness") }
                        WorkbenchStructuredOutput(value: .object([
                            "parameters": summary["parameters"], "notes": summary["notes"],
                            "comparison": summary["comparison"]]))
                            .tabItem { Text("Recipe and notes") }
                    }.frame(minHeight: 180)
                } else {
                    ContentUnavailableView("Biological assay summary", systemImage: "chart.xyaxis.line",
                        description: Text("Choose a saved assay recipe and measured output. Incomplete specimens and unassigned images remain visible in the report."))
                }
            }.padding(.leading, 12).frame(minWidth: 520)
        }.padding(.top, 12)
        .onAppear { imageIDs = Set(session.selectedImageID.map { [$0] } ?? []) }
    }

    private func runLabel(_ run: WorkbenchJSON) -> String {
        let name = session.images.first { $0.id == run["imageId"].string }?.name ?? "Image"
        let assay = assays.catalog.first { $0.id == run["assay"].string }?.name ?? run["assay"].string ?? "Assay"
        return "\(assay) · \(name) · r\(run["revision"].integer ?? 0)"
    }
    private func selectionLabel(_ selection: WorkbenchJSON) -> String {
        guard selection["target"].string == "volume" else { return "2D plane" }
        return "3D · T\((selection["timeIndex"].integer ?? 0) + 1) · C\((selection["channel"].integer ?? 0) + 1)"
    }
    private func conditionTable(_ summary: WorkbenchJSON) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 15) {
                ForEach(Array(summary["conditions"].array.enumerated()), id: \.offset) { _, group in
                    VStack(alignment: .leading, spacing: 5) {
                        Text("\(group["experiment"].string ?? "") · \(group["condition"].string ?? "")").font(.headline)
                        Text("Biological n = \(group["biologicalN"].integer ?? 0) · \(group["excludedIncompleteSpecimens"].integer ?? 0) incomplete specimens excluded")
                            .font(.caption)
                        Text("Mean \(format(group["mean"])) · SD \(format(group["sd"]))").font(.callout.monospacedDigit())
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }
                ForEach(summary["notes"].array.compactMap(\.string), id: \.self) {
                    Text($0).font(.caption).foregroundStyle(.secondary)
                }
            }.padding(8)
        }
    }
    private func format(_ value: WorkbenchJSON) -> String {
        value.number.map { String(format: "%.6g", $0) } ?? "—"
    }
}
