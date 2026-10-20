import SwiftUI

struct WorkbenchPreprocessingRecipeEditor: View {
    @Binding var steps: [WorkbenchPreprocessingStep]
    let filters: [WorkbenchPreprocessingFilter]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach($steps) { $step in
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("Filter \((steps.firstIndex { $0.id == step.id } ?? 0) + 1)").font(.headline)
                        Spacer()
                        Button { move(step.id, offset: -1) } label: { Image(systemName: "arrow.up") }
                            .help("Move earlier").disabled(steps.first?.id == step.id)
                        Button { move(step.id, offset: 1) } label: { Image(systemName: "arrow.down") }
                            .help("Move later").disabled(steps.last?.id == step.id)
                        Button { steps.removeAll { $0.id == step.id } } label: { Image(systemName: "minus.circle") }
                            .help("Remove filter")
                    }
                    Picker("Filter", selection: Binding(get: { step.method }, set: { method in
                        step.method = method
                        step.values = filters.first { $0.id == method }?.defaults ?? [:]
                    })) {
                        ForEach(filters) { Text($0.name).tag($0.id) }
                        if !filters.contains(where: { $0.id == step.method }) {
                            Text("\(step.method) · Unavailable").tag(step.method)
                        }
                    }
                    if let filter = filters.first(where: { $0.id == step.method }) {
                        WorkbenchPluginParameters(definitions: filter.parameters, values: $step.values)
                        Text(filter.effect.capitalized).font(.caption).foregroundStyle(.secondary)
                        ForEach(filter.notes, id: \.self) { Text($0).font(.caption).foregroundStyle(.secondary) }
                    } else {
                        Text("This saved filter is unavailable. Its parameters remain intact; choose an available filter explicitly before saving.")
                            .font(.caption).foregroundStyle(.orange)
                    }
                }.padding(10).background(.quaternary.opacity(0.4)).clipShape(RoundedRectangle(cornerRadius: 8))
            }
            Button("Add filter", systemImage: "plus") {
                if let filter = filters.first {
                    steps.append(WorkbenchPreprocessingStep(method: filter.id, values: filter.defaults))
                }
            }.disabled(steps.count >= 8 || filters.isEmpty)
        }
    }

    private func move(_ id: UUID, offset: Int) {
        guard let index = steps.firstIndex(where: { $0.id == id }), steps.indices.contains(index + offset) else { return }
        steps.swapAt(index, index + offset)
    }
}
