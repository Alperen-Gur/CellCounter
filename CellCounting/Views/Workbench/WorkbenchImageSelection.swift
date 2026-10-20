import SwiftUI

/// Shared search controls used by the canvas library and all acquisition lists.
struct WorkbenchImageBrowserControls: View {
    @Bindable var session: WorkbenchSession
    @Bindable var page: WorkbenchImagePageState
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                TextField("Search images, notes or tags", text: $page.query).textFieldStyle(.roundedBorder)
                    .onSubmit { session.loadImagePage(page: page) }
                Button("Search") { session.loadImagePage(page: page) }
            }
            DisclosureGroup("Filters") {
                VStack(alignment: .leading, spacing: 6) {
                    TextField("Required tags (comma separated)", text: $page.tags).textFieldStyle(.roundedBorder)
                    Picker("Visibility", selection: $page.archiveScope) {
                        Text("Active").tag("active"); Text("Archived").tag("archived"); Text("All retained").tag("all")
                    }
                    Picker("Collection", selection: $page.collectionID) {
                        Text("All collections").tag("")
                        ForEach(Array(session.library.collections.enumerated()), id: \.offset) { _, item in
                            Text(item["name"].string ?? "Collection").tag(item["id"].string ?? "")
                        }
                    }
                }
            }.font(.caption)
            HStack {
                Button("Previous") { session.loadImagePage(direction: -1, page: page) }.disabled(page.pageIndex == 0 || page.filtersChanged)
                Text("\(page.firstRow)–\(page.lastRow) of \(page.total)").font(.caption.monospacedDigit())
                Button("Next") { session.loadImagePage(direction: 1, page: page) }.disabled(page.nextCursor == nil || page.filtersChanged)
            }
            if page.filtersChanged { Text("Search to apply these filters. Existing selections are preserved.").font(.caption).foregroundStyle(.secondary) }
            else if page.sourceRevision != session.revision { Text("This page belongs to an earlier revision. Search again to refresh its rows; selected IDs remain retained.").font(.caption).foregroundStyle(.orange) }
        }.disabled(session.busy)
    }
}

/// Selection is a set of exact IDs across pages; page changes never prune it.
struct WorkbenchImageSelection: View {
    @Bindable var session: WorkbenchSession
    @Binding var selection: Set<String>
    var eligible: (WorkbenchImage) -> Bool = { _ in true }
    var title = "Images"
    var filters: [String: WorkbenchJSON] = [:]
    @State private var page = WorkbenchImagePageState()
    private var visible: [WorkbenchImage] { page.images.filter(eligible) }
    private var pageSelection: Binding<Set<String>> {
        Binding(get: { selection.intersection(Set(visible.map(\.id))) }, set: { next in
            selection.subtract(Set(visible.map(\.id))); selection.formUnion(next)
        })
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.headline)
            WorkbenchImageBrowserControls(session: session, page: page)
            HStack {
                Button("Select this page") { selection.formUnion(visible.map(\.id)) }
                Button("Select matching images") { session.selectMatchingImages(page: page, eligible: eligible) { selection = $0 } }
                Button("Clear selection") { selection = [] }
            }.controlSize(.small).disabled(session.busy || page.filtersChanged)
            Table(visible, selection: pageSelection) {
                TableColumn("Image", value: \.name)
                TableColumn("Status", value: \.status)
            }.frame(minHeight: 130)
            Text("\(selection.count) selected across pages · \(visible.count) eligible on this page · \(session.imageCount) retained in project")
                .font(.caption).foregroundStyle(.secondary)
        }.onAppear {
            page.constraints = filters
            if page.loadedFilters == nil { session.loadImagePage(page: page) }
        }.onChange(of: WorkbenchJSON.object(filters)) { _, _ in
            page.constraints = filters
            page.resetPages()
            session.loadImagePage(page: page)
        }
    }
}

/// A single-image picker shares the same paged search and resolves an explicit
/// choice into the bounded descriptor cache for the owning editor.
struct WorkbenchImageChoice: View {
    @Bindable var session: WorkbenchSession
    @Binding var selection: String
    var title: String
    var eligible: (WorkbenchImage) -> Bool = { _ in true }
    var filters: [String: WorkbenchJSON] = [:]
    @State private var showingBrowser = false
    @State private var page = WorkbenchImagePageState()
    var body: some View {
        HStack {
            Text(title)
            Text(session.images.first { $0.id == selection }?.name ?? (selection.isEmpty ? "Choose an image" : "Selected acquisition"))
                .lineLimit(1).foregroundStyle(.secondary)
            Button("Choose…") { page.constraints = filters; showingBrowser = true; session.loadImagePage(page: page) }
        }
        .onAppear { if !selection.isEmpty { session.loadImageDescriptor(selection) } }
        .popover(isPresented: $showingBrowser) {
            VStack(alignment: .leading, spacing: 10) {
                Text(title).font(.headline)
                WorkbenchImageBrowserControls(session: session, page: page)
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 6) {
                        ForEach(page.images.filter(eligible)) { image in
                            Button(image.name) { selection = image.id; showingBrowser = false }
                                .buttonStyle(.plain).frame(maxWidth: .infinity, alignment: .leading).padding(5)
                        }
                    }
                }.frame(height: 240)
                Button("Close") { showingBrowser = false }
            }.padding(16).frame(width: 430)
        }
    }
}

struct WorkbenchMeasurementPageControls: View {
    @Bindable var session: WorkbenchSession
    @Bindable var page: WorkbenchMeasurementPageState
    var volume = false
    private var count: Int { volume ? session.volume.cells.count : session.cells.count }
    private var selected: Set<Int> { volume ? session.volume.selectedLabels : session.selectedLabels }
    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
        HStack(spacing: 8) {
            Button("Previous") { session.pageMeasurements(-1) }.disabled(page.pageIndex == 0)
            Text("\(count == 0 ? 0 : page.pageIndex * 200 + 1)–\(page.pageIndex * 200 + count) of \(page.total) objects")
            Button("Next") { session.pageMeasurements(1) }.disabled(page.nextCursor == nil)
            Spacer()
            TextField("Exact label ID", value: $page.lookupLabel, format: .number).frame(width: 90).textFieldStyle(.roundedBorder)
                .accessibilityLabel("Exact saved label ID")
            Button("Select ID") { session.selectSavedLabels([page.lookupLabel]) }.disabled(page.lookupLabel < 1)
            Text("\(selected.count) selected across pages")
        }.font(.caption).disabled(session.busy || (volume ? session.volume.isPreview : session.isPreview))
        if !selected.isEmpty {
            DisclosureGroup("Selected objects, including other pages") {
                if volume {
                    ForEach(page.selectedVolumeCells.prefix(20)) { cell in
                        Text("#\(cell.id) · \(cell.voxelCount) voxels · mean intensity \(cell.meanIntensity.map { String(format: "%.3f", $0) } ?? "unknown")").font(.caption.monospacedDigit())
                    }
                } else {
                    ForEach(page.selectedCells.prefix(20)) { cell in
                        Text("#\(cell.id) · \(cell.areaPx, specifier: "%.0f") px² · mean intensity \(cell.meanIntensity.map { String(format: "%.3f", $0) } ?? "unknown")").font(.caption.monospacedDigit())
                    }
                }
                if selected.count > 20 { Text("First 20 selected objects shown; all \(selected.count) exact IDs remain selected.").font(.caption) }
                Button("Clear object selection") { session.selectSavedLabels([]) }.disabled(session.busy)
            }
        }
        }
    }
}
