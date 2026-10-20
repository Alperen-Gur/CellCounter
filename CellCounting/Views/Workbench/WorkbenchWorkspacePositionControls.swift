import SwiftUI

/// Axis navigation edits the shared document. Bound planes are resolved only
/// after an explicit save/render, so paint never targets an old displayed slice.
struct WorkbenchWorkspacePositionControls: View {
    @Bindable var workspace: WorkbenchWorkspaceState
    let editable: Bool
    private var axes: [WorkbenchJSON] {
        workspace.document["axes"].array.filter { !["x", "y"].contains($0["kind"].string ?? "") }
    }
    var body: some View {
        if !axes.isEmpty {
            DisclosureGroup("Workspace acquisition position") {
                ForEach(Array(axes.enumerated()), id: \.offset) { _, axis in
                    let id = axis["id"].string ?? ""
                    let index = workspace.document["position"][id].integer ?? 0
                    Stepper("\(axis["name"].string ?? "Axis"): \(index + 1) / \(axis["length"].integer ?? 1)", value: Binding(
                        get: { workspace.document["position"][id].integer ?? 0 },
                        set: { var position = workspace.document["position"].object; position[id] = .number(Double($0)); workspace.editDocument("position", .object(position)) }),
                        in: 0...max(0, (axis["length"].integer ?? 1) - 1))
                    if axis["calibrated"].bool == true, let scale = axis["scale"].number {
                        Text("\(Double(index) * scale, specifier: "%.3g") \(axis["unit"].string ?? "") from axis origin")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                Text("Save the position, then render or load its source plane. Dynamic bindings fetch exact acquired samples; fixed snapshots never substitute another frame.")
                    .font(.caption).foregroundStyle(.secondary)
            }.disabled(!editable)
        }
    }
}
