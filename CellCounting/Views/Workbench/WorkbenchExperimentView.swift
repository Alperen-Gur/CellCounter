import SwiftUI

struct WorkbenchExperimentView: View {
    @Bindable var session: WorkbenchSession
    @Environment(\.dismiss) private var dismiss
    @State private var specimenID = ""
    @State private var specimenName = ""
    @State private var experiment = ""
    @State private var condition = ""
    @State private var role = "other"
    @State private var plateEditID = ""
    @State private var plateName = ""
    @State private var plateRows = 8
    @State private var plateColumns = 12
    @State private var imageIDs: Set<String> = []
    @State private var assignmentSpecimenID = ""
    @State private var assignmentPlateID = ""
    @State private var wellRow = 1
    @State private var wellColumn = 1
    @State private var field = ""

    private var assignmentPlate: WorkbenchPlate? { session.plates.first { $0.id == assignmentPlateID } }
    private func trimmed(_ value: String) -> String { value.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Experiments and biological specimens").font(.title2)
                WorkbenchSavedRecordAccess(session: session, catalogues: ["specimens", "plates", "assignments", "experimentLayouts", "experimentApplications", "acquisitionSessions", "experimentExclusions"])
                Spacer()
                Button("Refresh", action: session.loadExperiment).disabled(session.busy)
                Button("Done") { dismiss() }
            }
            if let error = session.error {
                Text(error).font(.callout).foregroundStyle(.red).textSelection(.enabled)
            }
            TabView {
                design.tabItem { Text("Organization") }
                WorkbenchExperimentLayoutsView(session: session, state: session.experimentLayouts).tabItem { Text("Reusable layouts") }
                WorkbenchAcquisitionSessionsView(session: session, state: session.experimentLayouts).tabItem { Text("Acquisition sessions") }
                WorkbenchExperimentExclusionsView(session: session, state: session.experimentLayouts).tabItem { Text("Exclusions") }
                specimenSummary.tabItem { Text("Biological summary") }
                WorkbenchBiologicalAssaySummary(session: session, assays: session.assays)
                    .tabItem { Text("Assay summary") }
            }
            HStack {
                if session.busy { ProgressView().controlSize(.small) }
                Text(session.status).font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(22).frame(width: 1100, height: 760)
        .onChange(of: assignmentSpecimenID) { _, id in session.pinKnownCatalogue("specimens", id: id) }
        .task {
            if let id = session.selectedImageID { imageIDs = [id] }
            session.loadExperiment()
        }
    }

    private var design: some View {
        HSplitView {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    GroupBox("Biological specimen") {
                        VStack(alignment: .leading, spacing: 9) {
                            Picker("Edit", selection: $specimenID) {
                                Text("New specimen").tag("")
                                ForEach(session.specimens) { specimen in
                                    Text("\(specimen.name) · \(specimen.experiment)").tag(specimen.id)
                                }
                            }.onChange(of: specimenID) { _, id in session.pinKnownCatalogue("specimens", id: id); restoreSpecimen(id) }
                            TextField("Specimen name", text: $specimenName)
                            TextField("Experiment", text: $experiment)
                            TextField("Condition", text: $condition)
                            Picker("Role", selection: $role) {
                                Text("Control").tag("control")
                                Text("Treatment").tag("treatment")
                                Text("Other").tag("other")
                            }
                            Text("Use one specimen for images sampled from the same biological replicate.")
                                .font(.caption).foregroundStyle(.secondary)
                            Button(specimenID.isEmpty ? "Create specimen" : "Save specimen", action: saveSpecimen)
                                .disabled([specimenName, experiment, condition].contains { trimmed($0).isEmpty })
                        }.textFieldStyle(.roundedBorder).padding(5)
                    }
                    GroupBox("Plate layout") {
                        VStack(alignment: .leading, spacing: 9) {
                            Picker("Edit", selection: $plateEditID) {
                                Text("New plate").tag("")
                                ForEach(session.plates) { plate in Text(plate.name).tag(plate.id) }
                            }.onChange(of: plateEditID) { _, id in session.pinKnownCatalogue("plates", id: id); restorePlate(id) }
                            TextField("Plate name", text: $plateName).textFieldStyle(.roundedBorder)
                            Stepper("Rows: \(plateRows)", value: $plateRows, in: 1...100)
                            Stepper("Columns: \(plateColumns)", value: $plateColumns, in: 1...100)
                            Button(plateEditID.isEmpty ? "Create plate" : "Save plate", action: savePlate)
                                .disabled(trimmed(plateName).isEmpty)
                        }.padding(5)
                    }
                }.padding(.trailing, 12)
            }.frame(minWidth: 300, idealWidth: 340, maxWidth: 380)

            VStack(alignment: .leading, spacing: 10) {
                Text("Assign images").font(.headline)
                WorkbenchImageSelection(session: session, selection: $imageIDs, title: "Acquisitions to assign")
                Text("\(imageIDs.count) images selected").font(.caption).foregroundStyle(.secondary)
                Picker("Specimen", selection: $assignmentSpecimenID) {
                    Text("Select a specimen").tag("")
                    ForEach(session.specimens) { specimen in
                        Text("\(specimen.name) · \(specimen.condition)").tag(specimen.id)
                    }
                }
                Picker("Plate", selection: $assignmentPlateID) {
                    Text("No plate").tag("")
                    ForEach(session.plates) { plate in Text(plate.name).tag(plate.id) }
                }
                .onChange(of: assignmentPlateID) { _, id in session.pinKnownCatalogue("plates", id: id); wellRow = 1; wellColumn = 1 }
                if let plate = assignmentPlate {
                    HStack {
                        Stepper("Row: \(wellRow)", value: $wellRow, in: 1...plate.rows)
                        Stepper("Column: \(wellColumn)", value: $wellColumn, in: 1...plate.columns)
                    }
                }
                TextField("Field identifier (optional)", text: $field).textFieldStyle(.roundedBorder)
                HStack {
                    Button("Assign selected", action: assign).buttonStyle(.borderedProminent)
                        .disabled(imageIDs.isEmpty || assignmentSpecimenID.isEmpty)
                    Button("Remove assignment") {
                        session.updateExperiment("image.unassign", arguments: ["imageIds": imageArgument])
                    }.disabled(imageIDs.isEmpty)
                }
                Text("Removing an assignment preserves the image and its analysis.")
                    .font(.caption).foregroundStyle(.secondary)
            }.padding(.leading, 12).frame(minWidth: 450)
        }.padding(.top, 12).disabled(session.busy)
    }

    private var specimenSummary: some View {
        VStack(alignment: .leading, spacing: 12) {
            Button("Calculate specimen summary", action: session.summarizeExperiment).disabled(session.busy)
            Text("Complete biological specimens receive equal weight. Images and objects are observations within each specimen.")
                .font(.callout).foregroundStyle(.secondary)
            if let summary = session.experimentSummary {
                Text("\(summary["unassignedImageCount"].integer ?? 0) images are unassigned.")
                    .font(.caption)
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        ForEach(Array(summary["conditions"].array.enumerated()), id: \.offset) { _, group in
                            VStack(alignment: .leading, spacing: 5) {
                                Text("\(group["experiment"].string ?? "") · \(group["condition"].string ?? "")")
                                    .font(.headline)
                                Text("Biological n = \(group["biologicalN"].integer ?? 0) · \(group["excludedIncompleteSpecimens"].integer ?? 0) incomplete specimens excluded")
                                Text("Objects per image: \(formatted(group["meanObjectsPerImage"])) · SD: \(formatted(group["sdObjectsPerImage"]))")
                                Text("Mean object area: \(formatted(group["meanObjectAreaUm2"])) µm² · Calibrated biological n = \(group["physicalBiologicalN"].integer ?? 0)")
                            }
                        }
                        Divider()
                        Text("Specimens").font(.headline)
                        ForEach(Array(summary["specimens"].array.enumerated()), id: \.offset) { _, specimen in
                            VStack(alignment: .leading, spacing: 4) {
                                Text(specimen["name"].string ?? "Specimen").font(.callout.bold())
                                Text("\(specimen["analyzedImageCount"].integer ?? 0) of \(specimen["imageCount"].integer ?? 0) images analyzed · \(specimen["objectCount"].integer ?? 0) objects")
                                Text("Mean object area: \(formatted(specimen["meanObjectAreaUm2"])) µm²")
                            }
                        }
                    }.font(.callout).frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled)
                }
                Text("Physical metrics require all images within a specimen to be analyzed and calibrated. Counts per image are descriptive and are not normalized for sampling area.")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                ContentUnavailableView("No summary yet", systemImage: "chart.bar",
                    description: Text("Assign images to specimens, then calculate the summary."))
            }
        }.padding(.top, 12)
    }

    private var imageArgument: WorkbenchJSON { .array(imageIDs.sorted().map(WorkbenchJSON.string)) }

    private func saveSpecimen() {
        var arguments: [String: WorkbenchJSON] = [
            "name": .string(trimmed(specimenName)), "experiment": .string(trimmed(experiment)),
            "condition": .string(trimmed(condition)), "role": .string(role)
        ]
        if !specimenID.isEmpty { arguments["specimenId"] = .string(specimenID) }
        session.updateExperiment("specimen.set", arguments: arguments)
    }

    private func savePlate() {
        var arguments: [String: WorkbenchJSON] = [
            "name": .string(trimmed(plateName)), "rows": .number(Double(plateRows)),
            "columns": .number(Double(plateColumns))
        ]
        if !plateEditID.isEmpty { arguments["plateId"] = .string(plateEditID) }
        session.updateExperiment("plate.set", arguments: arguments)
    }

    private func assign() {
        var arguments: [String: WorkbenchJSON] = [
            "imageIds": imageArgument, "specimenId": .string(assignmentSpecimenID)
        ]
        if let plate = assignmentPlate {
            arguments["plateId"] = .string(plate.id)
            arguments["wellRow"] = .number(Double(wellRow))
            arguments["wellColumn"] = .number(Double(wellColumn))
        }
        if !trimmed(field).isEmpty { arguments["field"] = .string(trimmed(field)) }
        session.updateExperiment("image.assign", arguments: arguments)
    }

    private func restoreSpecimen(_ id: String) {
        let specimen = session.specimens.first { $0.id == id }
        specimenName = specimen?.name ?? ""
        experiment = specimen?.experiment ?? ""
        condition = specimen?.condition ?? ""
        role = specimen?.role ?? "other"
    }

    private func restorePlate(_ id: String) {
        let plate = session.plates.first { $0.id == id }
        plateName = plate?.name ?? ""
        plateRows = plate?.rows ?? 8
        plateColumns = plate?.columns ?? 12
    }

    private func assignmentName(_ imageID: String) -> String {
        guard let assignment = session.assignments.first(where: { $0.imageID == imageID }) else { return "—" }
        return session.specimens.first { $0.id == assignment.specimenID }?.name ?? "—"
    }

    private func assignmentWell(_ imageID: String) -> String {
        guard let assignment = session.assignments.first(where: { $0.imageID == imageID }),
              let row = assignment.wellRow, let column = assignment.wellColumn else { return "—" }
        let plate = session.plates.first { $0.id == assignment.plateID }?.name ?? "Plate"
        return "\(plate) · \(row), \(column)"
    }

    private func formatted(_ value: WorkbenchJSON) -> String {
        value.number.map { String(format: "%.3f", $0) } ?? "—"
    }
}
