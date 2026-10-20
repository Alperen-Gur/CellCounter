import AppKit
import Observation

nonisolated struct WorkbenchLargeSource: Identifiable, Sendable {
    let id: String
    let name: String
    let width: Int
    let height: Int
    let pageCount: Int
    let channels: Int
    let dtype: String
    let axes: String
    let access: String
    let limitations: [String]
    let descriptor: WorkbenchJSON
    init?(_ value: WorkbenchJSON) {
        guard let id = value["id"].string else { return nil }
        self.id = id
        name = value["name"].string ?? "TIFF source"
        width = max(1, value["width"].integer ?? 1)
        height = max(1, value["height"].integer ?? 1)
        pageCount = max(1, value["pageCount"].integer ?? 1)
        channels = max(1, value["channels"].integer ?? 1)
        dtype = value["dtype"].string ?? ""
        axes = value["axes"].string ?? ""
        access = value["access"].string ?? "unsupported"
        limitations = value["limitations"].array.compactMap(\.string)
        descriptor = value
    }
}

@MainActor @Observable
final class WorkbenchSourceState {
    var sources: [WorkbenchLargeSource] = []
    var selectedID = ""
    var pageIndex = 0
    var channel = 0
    var overview: NSImage?
    var overviewInfo: WorkbenchJSON?
    var x = 0
    var y = 0
    var width = 512
    var height = 512
    var lastExtractedImageID: String?
    var selected: WorkbenchLargeSource? { sources.first { $0.id == selectedID } }
    var overviewCurrent: Bool {
        overview != nil && overviewInfo?["sourceId"].string == selectedID &&
            overviewInfo?["pageIndex"].integer == pageIndex && overviewInfo?["channel"].integer == channel
    }
    var validRegion: Bool {
        guard let source = selected else { return false }
        return x >= 0 && y >= 0 && width > 0 && height > 0 &&
            x <= source.width && y <= source.height &&
            width <= source.width - x && height <= source.height - y &&
            Double(width) * Double(height) <= 16_000_000
    }
    func clearOverview() { overview = nil; overviewInfo = nil }
    func configure(_ id: String) {
        selectedID = id; pageIndex = 0; channel = 0; x = 0; y = 0
        width = min(512, selected?.width ?? 512)
        height = min(512, selected?.height ?? 512)
        clearOverview()
    }
    func applyInspection(_ value: WorkbenchJSON) {
        sources = value["largeSources"].array.compactMap(WorkbenchLargeSource.init)
        if selectedID.isEmpty { configure(sources.first?.id ?? "") }
    }
    func reset() {
        sources = []; selectedID = ""; lastExtractedImageID = nil
        clearOverview()
    }
}

extension WorkbenchSession {
    func loadLargeSources() {
        perform("Loading retained TIFF sources…") {
            try await self.inspect()
            if self.sources.selected?.access != "unsupported", self.sources.selected != nil {
                try await self.readSourceOverview()
            }
            self.reportStatus("TIFF source catalog loaded.")
        }
    }

    func importLargeSources(_ urls: [URL], seriesIndex: Int) {
        perform("Retaining TIFF sources…") {
            let result = try await self.call("source.import", arguments: [
                "paths": .array(urls.map { .string($0.path) }), "seriesIndex": .number(Double(seriesIndex))
            ], mutation: true)["result"]
            try await self.inspect()
            if let id = result["importedSourceIds"].array.first?.string ?? result["duplicateSourceIds"].array.first?.string {
                self.sources.configure(id)
            }
            if self.sources.selected?.access != "unsupported", self.sources.selected != nil {
                try await self.readSourceOverview()
            }
            self.reportStatus("TIFF source retained. Select a region to create an analysis image.")
        }
    }

    func selectLargeSource(_ id: String) {
        guard !busy else { return }
        sources.configure(id)
        guard sources.selected?.access != "unsupported", sources.selected != nil else { return }
        refreshSourceOverview()
    }

    func refreshSourceOverview() {
        perform("Loading bounded source overview…") { try await self.readSourceOverview() }
    }

    func extractSourceRegion(name: String) {
        guard sources.validRegion, sources.overviewCurrent else { return }
        var args: [String: WorkbenchJSON] = [
            "sourceId": .string(sources.selectedID), "pageIndex": .number(Double(sources.pageIndex)),
            "channel": .number(Double(sources.channel)),
            "x": .number(Double(sources.x)), "y": .number(Double(sources.y)),
            "width": .number(Double(sources.width)), "height": .number(Double(sources.height))
        ]
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { args["name"] = .string(trimmed) }
        perform("Extracting original-resolution region…") {
            let result = try await self.call("source.extract", arguments: args, mutation: true)["result"]
            try await self.inspect()
            self.selectedImageID = result["imageId"].string
            self.invalidateSummaries()
            try await self.loadImage()
            self.sources.lastExtractedImageID = result["imageId"].string
            self.reportStatus("Region extracted at source resolution with calibration and origin retained.")
        }
    }

    private func readSourceOverview() async throws {
        sources.clearOverview()
        guard !sources.selectedID.isEmpty else { return }
        let result = try await call("source.overview", arguments: [
            "sourceId": .string(sources.selectedID), "pageIndex": .number(Double(sources.pageIndex)),
            "channel": .number(Double(sources.channel)), "maxSize": .number(1024)
        ])["result"]
        sources.overview = try decodePreview(result)
        sources.overviewInfo = result
    }
}
