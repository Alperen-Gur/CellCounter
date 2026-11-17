import Foundation
import SwiftData

/// Workflow settings a new library can start with: calibration presets,
/// size-bin presets and conditions. Plain values, so they can be captured from
/// one store and written into another.
nonisolated struct LibraryStarterContent: Sendable, Equatable {
    nonisolated struct Calibration: Sendable, Equatable { var name: String; var pxPerUm: Double; var isDefault: Bool }
    nonisolated struct Bins: Sendable, Equatable { var name: String; var thresholds: [Double] }
    nonisolated struct Condition: Sendable, Equatable { var name: String; var color: String; var order: Int }

    var calibrations: [Calibration] = []
    var bins: [Bins] = []
    var conditions: [Condition] = []

    /// What a library gets when nothing is copied. Calibration and bin presets
    /// are seeded by `Repositories` on first open; the "Control" condition is
    /// seeded only once per Mac, so a new library gets it here.
    static let fresh = LibraryStarterContent(conditions: [Condition(name: "Control", color: "#4db3a8", order: 0)])

    /// Reads the settings to copy from an open library.
    @MainActor static func capture(from context: ModelContext) throws -> LibraryStarterContent {
        let calibrations = try context.fetch(FetchDescriptor<CalibrationPresetRecord>(sortBy: [SortDescriptor(\.name)]))
        let bins = try context.fetch(FetchDescriptor<BinPresetRecord>(sortBy: [SortDescriptor(\.name)]))
        let conditions = try context.fetch(FetchDescriptor<ConditionRecord>(sortBy: [SortDescriptor(\.order)]))
        return LibraryStarterContent(
            calibrations: calibrations.map { Calibration(name: $0.name, pxPerUm: $0.pxPerUm, isDefault: $0.isDefault) },
            bins: bins.map { Bins(name: $0.name, thresholds: $0.thresholds) },
            conditions: conditions.map { Condition(name: $0.name, color: $0.color, order: $0.order) })
    }
}

nonisolated enum LibraryCreationError: LocalizedError {
    case alreadyExists(URL)
    case insideLibrary(URL)

    var errorDescription: String? {
        switch self {
        case .alreadyExists(let url):
            return "Something named “\(url.lastPathComponent)” already exists in that folder. Choose another name."
        case .insideLibrary(let url):
            return "A library cannot be created inside another library (“\(url.lastPathComponent)”). Choose a different folder."
        }
    }
}

/// Creates new, empty project libraries in the shared `LibraryLayout` format.
enum LibraryCreator {
    /// Adds the `.cellcounterlibrary` extension when the user left it off.
    nonisolated static func normalizedURL(for chosen: URL) -> URL {
        if chosen.pathExtension.lowercased() == LibraryLayout.packageExtension { return chosen.standardizedFileURL }
        return chosen.appendingPathExtension(LibraryLayout.packageExtension).standardizedFileURL
    }

    /// The closest enclosing folder (excluding `url` itself) that is a library.
    nonisolated static func enclosingLibrary(of url: URL) -> URL? {
        var current = url.standardizedFileURL.deletingLastPathComponent()
        while current.path != "/" && !current.path.isEmpty {
            if LibraryLayout.isLibrary(at: current) { return current }
            current = current.deletingLastPathComponent()
        }
        return nil
    }

    /// Creates the folder layout, the manifest and the store, then writes the
    /// starter content. Never overwrites: fails if `root` already exists.
    /// Removes everything it created when any step fails.
    @MainActor @discardableResult
    static func create(at root: URL, name: String, starter: LibraryStarterContent,
                       now: Date = Date()) throws -> LibraryLayout {
        let fm = FileManager.default
        let layout = LibraryLayout(root: root)
        guard !fm.fileExists(atPath: layout.root.path) else { throw LibraryCreationError.alreadyExists(layout.root) }
        if let parent = enclosingLibrary(of: layout.root) { throw LibraryCreationError.insideLibrary(parent) }
        do {
            try layout.createDirectories()
            try layout.writeManifest(LibraryManifest(kind: .library, name: name, createdAt: now,
                                                     appVersion: LibraryManifest.currentAppVersion))
            try writeStore(at: layout.storeURL, starter: starter)
        } catch {
            try? fm.removeItem(at: layout.root)
            throw error
        }
        return layout
    }

    @MainActor private static func writeStore(at url: URL, starter: LibraryStarterContent) throws {
        let schema = Repositories.librarySchema()
        let configuration = ModelConfiguration("CellCounter", schema: schema, url: url)
        let container = try ModelContainer(for: schema, configurations: [configuration])
        let context = ModelContext(container)
        context.autosaveEnabled = false
        for preset in starter.calibrations {
            context.insert(CalibrationPresetRecord(name: preset.name, pxPerUm: preset.pxPerUm, isDefault: preset.isDefault))
        }
        for preset in starter.bins {
            context.insert(BinPresetRecord(name: preset.name, thresholds: preset.thresholds))
        }
        for condition in starter.conditions {
            context.insert(ConditionRecord(name: condition.name, color: condition.color, order: condition.order))
        }
        try context.save()
    }
}
