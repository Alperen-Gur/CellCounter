import SwiftUI

/// One typed factor editor serves statistical designs and reusable layouts.
struct WorkbenchFactorEditor: View {
    @Binding var factors: [WorkbenchStatFactor]
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach($factors) { $factor in
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        TextField("Factor name", text: $factor.name)
                        Picker("Kind", selection: $factor.kind) { Text("Categorical").tag("categorical"); Text("Numeric").tag("numeric") }.frame(width: 190)
                        Button("Remove factor") { factors.removeAll { $0.id == factor.id } }.disabled(factors.count <= 1)
                    }
                    if factor.kind == "categorical" {
                        TextField("Declared levels, comma-separated", text: $factor.levels)
                        Picker("Reference level", selection: $factor.reference) { Text("Choose reference").tag(""); ForEach(factor.levelList, id: \.self) { Text($0).tag($0) } }
                    } else { TextField("Unit (optional)", text: $factor.unit) }
                    DisclosureGroup("Factor identity") { Text(factor.id).font(.caption.monospaced()).textSelection(.enabled) }
                    Divider()
                }
            }
            Button("Add factor") {
                var index = factors.count + 1
                while factors.contains(where: { $0.id == "factor\(index)" }) { index += 1 }
                factors.append(WorkbenchStatFactor(id: "factor\(index)", name: "Factor \(index)"))
            }.disabled(factors.count >= 16)
        }.textFieldStyle(.roundedBorder)
    }
}
