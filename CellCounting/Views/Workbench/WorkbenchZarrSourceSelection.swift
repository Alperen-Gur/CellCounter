import SwiftUI

/// One acquisition selector shared by source extraction and dynamic layer binding.
struct WorkbenchZarrSourceSelection: View {
    @Bindable var session: WorkbenchSession
    @Bindable var storage: WorkbenchStorageState
    var onRelocate: (() -> Void)?
    private var writesBlocked: Bool { session.busy || session.hasActiveWorkers || !session.canRefreshWithoutDiscardingEdits }
    var body: some View {
        GroupBox("Source and acquisition selection") {
            VStack(alignment: .leading, spacing: 10) {
                Picker("Source", selection: Binding(get: { storage.sourceID }, set: storage.configureSource)) {
                    Text("Open a local source first").tag("")
                    ForEach(storage.sources, id: \.zarrSelectorID) { source in
                        Text("\(source["name"].string ?? "Source") · NGFF \(source["ngffVersion"].string ?? "") / Zarr \(source["zarrFormat"].integer ?? 0)").tag(source["id"].string ?? "")
                    }
                }
                if storage.source != .null {
                    HStack {
                        Text(storage.source["available"].bool == true ? "Source directory present" : "Source directory unavailable")
                            .font(.caption).foregroundStyle(storage.source["available"].bool == true ? Color.secondary : Color.orange)
                        Spacer()
                        if let onRelocate { Button("Relocate identical source…", action: onRelocate).disabled(writesBlocked) }
                    }
                    Text("Directory presence does not verify external content. Scientific reads retain exact chunk identities; relocating checks every retained identity.")
                        .font(.caption).foregroundStyle(.secondary)
                    DisclosureGroup("Source location and metadata") {
                        Text(storage.source["path"].string ?? "").font(.caption).textSelection(.enabled)
                        WorkbenchStructuredOutput(value: .object(["metadataHash": storage.source["metadataHash"], "readIdentityCount": storage.source["readIdentityCount"], "notes": storage.source["notes"]])).frame(height: 130)
                    }
                    Picker("Resolution level", selection: Binding(get: { storage.arrayPath }, set: storage.configureArray)) {
                        ForEach(storage.source["arrays"].array, id: \.zarrSelectorPath) { array in
                            Text("\(array["name"].string ?? "Image") · level \(array["level"].integer ?? 0) · \(array["path"].string ?? "") · \(array["shape"].array.compactMap(\.integer).map(String.init).joined(separator: " × "))").tag(array["path"].string ?? "")
                        }
                    }
                    if storage.array != .null {
                        Text("\(storage.array["axes"].array.compactMap { $0["name"].string }.joined(separator: " × ")) · \(storage.array["dtype"].string ?? "") · chunks \(storage.array["chunks"].array.compactMap(\.integer).map(String.init).joined(separator: " × "))")
                            .font(.caption).foregroundStyle(.secondary)
                        Text("Selected-level pixel size: X \(number(storage.array["voxelSizeUm"]["x"])) µm · Y \(number(storage.array["voxelSizeUm"]["y"])) µm. Unknown calibration remains unknown.")
                            .font(.caption).foregroundStyle(.secondary)
                        VStack(alignment: .leading, spacing: 6) {
                            selector("Time", value: $storage.timeIndex, count: storage.dimension("t"))
                            selector("Channel", value: $storage.channel, count: storage.dimension("c"))
                            selector("Z plane", value: $storage.zIndex, count: storage.dimension("z"))
                        }
                        Button("Read selected-level overview", action: session.previewZarrSource)
                            .disabled(!storage.validSelection || storage.source["available"].bool != true)
                    }
                }
            }.padding(6).disabled(session.busy)
        }
    }

    private func selector(_ label: String, value: Binding<Int>, count: Int) -> some View {
        Stepper("\(label) \(value.wrappedValue + 1) / \(count)", value: value, in: 0...max(0, count - 1))
    }
    private func number(_ value: WorkbenchJSON) -> String { value.number.map { $0.formatted(.number.precision(.fractionLength(0...4))) } ?? "Unknown" }
}
private extension WorkbenchJSON {
    var zarrSelectorID: String { self["id"].string ?? "" }
    var zarrSelectorPath: String { self["path"].string ?? "" }
}
