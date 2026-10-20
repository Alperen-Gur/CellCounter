import AppKit
import Foundation
import Observation

/// One shared, revision-bound library browser. Selections belong to their
/// editors and persist independently of the currently visible page.
@MainActor @Observable
final class WorkbenchImagePageState {
    var query = ""
    var tags = ""
    var collectionID = ""
    var archiveScope = "active"
    var images: [WorkbenchImage] = []
    var total = 0
    var nextCursor: String?
    var cursors: [String?] = [nil]
    var pageIndex = 0
    var sourceRevision: Int?
    var loadedFilters: WorkbenchJSON?
    var constraints: [String: WorkbenchJSON] = [:]
    var arguments: [String: WorkbenchJSON] {
        var args: [String: WorkbenchJSON] = ["query": .string(query), "archiveScope": .string(archiveScope), "limit": .number(100),
            "tags": .array(Array(Set(tags.split(separator: ",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty })).sorted().map(WorkbenchJSON.string))]
        if !collectionID.isEmpty { args["collectionId"] = .string(collectionID) }
        return args.merging(constraints, uniquingKeysWith: { _, new in new })
    }
    var filtersChanged: Bool { loadedFilters != .object(arguments) }
    var firstRow: Int { images.isEmpty ? 0 : pageIndex * 100 + 1 }
    var lastRow: Int { images.isEmpty ? 0 : pageIndex * 100 + images.count }
    func resetPages() { images = []; total = 0; nextCursor = nil; cursors = [nil]; pageIndex = 0; sourceRevision = nil; loadedFilters = nil }
    func reset() { query = ""; tags = ""; collectionID = ""; archiveScope = "active"; resetPages() }
}

@MainActor @Observable
final class WorkbenchMeasurementPageState {
    var total = 0
    var nextCursor: String?
    var cursors: [String?] = [nil]
    var pageIndex = 0
    var sourceRevision: Int?
    var selectedCells: [WorkbenchCell] = []
    var selectedVolumeCells: [WorkbenchVolumeCell] = []
    var maskOverlay: NSImage?
    var volumeOverlay: NSImage?
    var lookupLabel = 1
    func reset() {
        total = 0; nextCursor = nil; cursors = [nil]; pageIndex = 0; sourceRevision = nil
        selectedCells = []; selectedVolumeCells = []; maskOverlay = nil; volumeOverlay = nil
    }
}

extension WorkbenchSession {
    /// The descriptor cache is bounded display metadata, never the library.
    func cacheImages(_ incoming: [WorkbenchImage]) {
        let replacing = Set(incoming.map(\.id))
        images.removeAll { replacing.contains($0.id) }
        images.append(contentsOf: incoming)
        if images.count > 1200 {
            let keep = Set(imagePage.images.map(\.id)).union(selectedImageID.map { [$0] } ?? [])
            let remove = images.count - 1200
            var removed = 0
            images.removeAll { image in
                if removed < remove && !keep.contains(image.id) { removed += 1; return true }
                return false
            }
        }
        let cached = Set(images.map(\.id))
        extensions.referenceCurrent = extensions.referenceCurrent.filter { cached.contains($0.key) }
        for image in incoming { extensions.referenceCurrent[image.id] = image.referenceCurrent }
    }

    func resolveImage(_ id: String) async throws -> WorkbenchImage {
        if let image = images.first(where: { $0.id == id }) { return image }
        guard let image = WorkbenchImage(try await call("image.get", arguments: ["imageId": .string(id)])["result"]["image"]) else {
            throw WorkbenchFailure(code: "image-not-found", message: "The selected acquisition is unavailable.")
        }
        cacheImages([image]); return image
    }

    func loadImageDescriptor(_ id: String) {
        guard !id.isEmpty, !images.contains(where: { $0.id == id }) else { return }
        perform("Reading selected acquisition metadata…", refreshOnConflict: false) { _ = try await self.resolveImage(id) }
    }

    func loadImagePage(direction: Int = 0, page: WorkbenchImagePageState? = nil) {
        let page = page ?? imagePage
        perform("Loading library page…", refreshOnConflict: false) {
            try await self.readImagePage(direction: direction, page: page)
            self.reportStatus("Showing \(page.firstRow)–\(page.lastRow) of \(page.total) matching images. Selections on other pages are retained.")
        }
    }

    func readImagePage(direction: Int = 0, page: WorkbenchImagePageState? = nil) async throws {
        let imagePage = page ?? self.imagePage
        let reset = direction == 0 || imagePage.filtersChanged || imagePage.sourceRevision != revision
        var target = reset ? 0 : imagePage.pageIndex + direction
        if direction > 0 && !reset {
            guard let next = imagePage.nextCursor else { return }
            if imagePage.cursors.count > target { imagePage.cursors[target] = next } else { imagePage.cursors.append(next) }
        }
        if reset { imagePage.resetPages() }
        target = max(0, min(target, imagePage.cursors.count - 1))
        var args = imagePage.arguments
        if let cursor = imagePage.cursors[target] { args["cursor"] = .string(cursor) }
        do {
            let result = try await call("image.list", arguments: args)["result"]
            imagePage.images = result["images"].array.compactMap(WorkbenchImage.init)
            imagePage.total = result["total"].integer ?? 0
            imagePage.nextCursor = result["nextCursor"].string
            imagePage.pageIndex = target; imagePage.sourceRevision = result["sourceRevision"].integer
            imagePage.loadedFilters = .object(imagePage.arguments)
            cacheImages(imagePage.images)
        } catch let failure as WorkbenchFailure where failure.code == "snapshot-changed" || failure.code == "revision-conflict" {
            imagePage.resetPages()
            throw WorkbenchFailure(code: "snapshot-changed", message: "The project changed while this page was loading. The page sequence was cleared; refresh the project after saving any draft, then search again. Existing selected image IDs are preserved.")
        }
    }

    /// Explicit bulk selection is bounded by the operation's 1,000-image input
    /// limit. It never silently substitutes the loaded page for all matches.
    func selectMatchingImages(page: WorkbenchImagePageState? = nil, eligible: @escaping (WorkbenchImage) -> Bool = { _ in true },
                              completion: @escaping @MainActor (Set<String>) -> Void) {
        let filters = (page ?? imagePage).arguments
        perform("Selecting matching acquisitions…", refreshOnConflict: false) {
            var args = filters; args["limit"] = .number(500)
            var selected: Set<String> = []
            repeat {
                let result = try await self.call("image.list", arguments: args)["result"]
                guard (result["total"].integer ?? 0) <= 1000 else {
                    throw WorkbenchFailure(code: "selection-limit", message: "More than 1,000 images match. Narrow the search or choose a collection before selecting the matching set.")
                }
                let page = result["images"].array.compactMap(WorkbenchImage.init)
                self.cacheImages(page)
                selected.formUnion(page.filter(eligible).map(\.id))
                if let cursor = result["nextCursor"].string { args["cursor"] = .string(cursor) }
                else { break }
            } while true
            completion(selected)
            self.reportStatus("Selected \(selected.count) matching acquisitions across all result pages.")
        }
    }

    var measurementArguments: [String: WorkbenchJSON] {
        var args: [String: WorkbenchJSON] = ["imageId": .string(selectedImageID ?? ""), "target": .string(viewingVolume ? "volume" : "plane")]
        if viewingVolume { args["timeIndex"] = .number(Double(volume.timeIndex)); args["channel"] = .number(Double(volume.channel)) }
        return args
    }

    func readMeasurementPage(direction: Int = 0) async throws {
        let state = measurementPage
        let reset = direction == 0 || state.sourceRevision != revision
        var target = reset ? 0 : state.pageIndex + direction
        if direction > 0 && !reset {
            guard let next = state.nextCursor else { return }
            if state.cursors.count > target { state.cursors[target] = next } else { state.cursors.append(next) }
        }
        if reset { state.cursors = [nil]; state.pageIndex = 0; state.nextCursor = nil }
        target = max(0, min(target, state.cursors.count - 1))
        var args = measurementArguments
        args["limit"] = .number(200); args["includeContours"] = .bool(false)
        if let cursor = state.cursors[target] { args["cursor"] = .string(cursor) }
        do {
            let result = try await call("measurements.page", arguments: args)["result"]
            state.total = result["total"].integer ?? 0; state.nextCursor = result["nextCursor"].string
            state.sourceRevision = result["sourceRevision"].integer; state.pageIndex = target
            if viewingVolume { volume.cells = result["cells"].array.compactMap(WorkbenchVolumeCell.init) }
            else { cells = result["cells"].array.compactMap(WorkbenchCell.init) }
        } catch let failure as WorkbenchFailure where failure.code == "snapshot-changed" || failure.code == "revision-conflict" {
            state.cursors = [nil]; state.nextCursor = nil; state.sourceRevision = nil
            throw WorkbenchFailure(code: "snapshot-changed", message: "Measurement pages changed. Selected label IDs and your draft remain preserved. Refresh the project before requesting a new page.")
        }
    }

    func pageMeasurements(_ direction: Int) {
        perform("Loading object measurements…", refreshOnConflict: false) {
            try await self.readMeasurementPage(direction: direction)
        }
    }

    func loadSavedMaskOverlay() async throws {
        var args = measurementArguments; args["maxSize"] = .number(1024)
        if viewingVolume { args["plane"] = .string(volume.plane); args["index"] = .number(Double(volume.index)) }
        let result = try await call("mask.overlay", arguments: args)["result"]
        var payload = result.object; payload["dataUrl"] = result["maskDataUrl"]
        let image = try decodePreview(.object(payload))
        if viewingVolume { measurementPage.volumeOverlay = image } else { measurementPage.maskOverlay = image }
    }

    func selectSavedLabels(_ ids: Set<Int>) {
        guard !busy, ids.count <= 1000 else { return }
        if viewingVolume { volume.selectedLabels = ids } else { selectedLabels = ids }
        if ids.isEmpty { measurementPage.selectedCells = []; measurementPage.selectedVolumeCells = []; volume.sliceContours = []; return }
        perform("Looking up exact selected objects…", refreshOnConflict: false) {
            try await self.lookupSelectedLabels()
        }
    }

    private func lookupSelectedLabels() async throws {
        let ids = viewingVolume ? volume.selectedLabels : selectedLabels
        guard !ids.isEmpty else { return }
        var args = measurementArguments
        args["labelIds"] = .array(ids.sorted().map { .number(Double($0)) }); args["includeContours"] = .bool(true)
        let result = try await call("measurements.lookup", arguments: args)["result"]
        if viewingVolume {
            measurementPage.selectedVolumeCells = result["cells"].array.compactMap(WorkbenchVolumeCell.init)
            var contourArgs = measurementArguments
            contourArgs.removeValue(forKey: "target")
            contourArgs["plane"] = .string(volume.plane); contourArgs["index"] = .number(Double(volume.index))
            contourArgs["includeContours"] = .bool(true); contourArgs["labelIds"] = args["labelIds"]
            contourArgs["maxSize"] = .number(64)
            let slice = try await call("volume.slice", arguments: contourArgs)["result"]
            volume.sliceContours = slice["contours"].array.compactMap(WorkbenchSliceContour.init)
        }
        else { measurementPage.selectedCells = result["cells"].array.compactMap(WorkbenchCell.init) }
        if !result["missingLabelIds"].array.isEmpty {
            reportStatus("Some selected label IDs no longer exist. Their IDs remain selected for review; refresh after preserving any draft.")
        }
    }

    func pickSavedLabel(x: Double, y: Double, z: Double? = nil, extending: Bool) {
        guard !busy else { return }
        var args = measurementArguments; args["x"] = .number(x); args["y"] = .number(y)
        if let z { args["z"] = .number(z) }
        perform("Selecting from exact saved labels…", refreshOnConflict: false) {
            let result = try await self.call("mask.pick", arguments: args)["result"]
            let id = result["labelId"].integer ?? 0
            var selection = extending ? (self.viewingVolume ? self.volume.selectedLabels : self.selectedLabels) : []
            if id > 0 {
                if extending && selection.contains(id) { selection.remove(id) } else { selection.insert(id) }
            }
            guard selection.count <= 1000 else { throw WorkbenchFailure(code: "selection-limit", message: "Select at most 1,000 exact objects at once.") }
            if self.viewingVolume { self.volume.selectedLabels = selection } else { self.selectedLabels = selection }
            if selection.isEmpty { self.measurementPage.selectedCells = []; self.measurementPage.selectedVolumeCells = []; self.volume.sliceContours = [] }
            else { try await self.lookupSelectedLabels() }
        }
    }
}
