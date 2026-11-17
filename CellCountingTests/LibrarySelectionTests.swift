import Darwin
import Foundation
import SwiftData
import Testing
@testable import CellCounting

/// Library selection, preferences and layout. Every test works in its own
/// temporary folder and its own UserDefaults suite; nothing here reads or
/// writes `UserDefaults.standard` or the real Application Support folder.
@Suite(.serialized)
struct LibrarySelectionTests {

    // MARK: - Fixtures

    private final class Sandbox {
        let root: URL
        /// One fixed suite, emptied before and after each test (the suite is
        /// serialized), so runs never accumulate preference files.
        let suiteName = "CellCounterLibrarySelectionTests"
        let defaults: UserDefaults

        init() throws {
            root = FileManager.default.temporaryDirectory
                .appendingPathComponent("LibrarySelectionTests-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            defaults = UserDefaults(suiteName: suiteName)!
            defaults.removePersistentDomain(forName: suiteName)
        }

        deinit {
            defaults.removePersistentDomain(forName: suiteName)
            try? FileManager.default.removeItem(at: root)
        }

        var appRoot: URL { root.appendingPathComponent("AppSupport/CellCounter", isDirectory: true) }

        /// A folder `LibraryLayout.isLibrary(at:)` accepts.
        func makeLibrary(_ name: String, manifest: LibraryManifest? = nil) throws -> URL {
            let url = root.appendingPathComponent("\(name).cellcounterlibrary", isDirectory: true)
            let layout = LibraryLayout(root: url)
            try layout.createDirectories()
            FileManager.default.createFile(atPath: layout.storeURL.path, contents: Data())
            if let manifest { try layout.writeManifest(manifest) }
            return url
        }

        func resolve(_ environment: [String: String] = [:]) -> LibraryResolution {
            LibrarySelection.resolve(environment: environment, defaults: defaults,
                                     standardAppRoot: appRoot,
                                     temporaryDirectory: root.appendingPathComponent("tmp", isDirectory: true),
                                     processIdentifier: 4242)
        }

        func snapshotLibraryKeys() -> [String: String] {
            var result: [String: String] = [:]
            for key in [LibraryPreferences.currentLibraryKey, LibraryPreferences.recentLibrariesKey] {
                result[key] = defaults.object(forKey: key).map { "\($0)" } ?? "<nil>"
            }
            return result
        }
    }

    private func samePath(_ lhs: URL, _ rhs: URL) -> Bool { LibrarySelection.samePath(lhs, rhs) }

    // MARK: - Resolution order

    @Test func dataRootOverrideWinsAndNeverTouchesPreferences() throws {
        let sandbox = try Sandbox()
        let remembered = try sandbox.makeLibrary("Remembered")
        sandbox.defaults.set(remembered.path, forKey: LibraryPreferences.currentLibraryKey)
        sandbox.defaults.set([remembered.path], forKey: LibraryPreferences.recentLibrariesKey)
        let before = sandbox.snapshotLibraryKeys()
        let dataRoot = sandbox.root.appendingPathComponent("data", isDirectory: true)

        for variable in [LibrarySelection.dataRootVariable, LibrarySelection.testRunnerDataRootVariable] {
            let resolution = sandbox.resolve([variable: dataRoot.path, "XCTestBundlePath": "/x"])
            #expect(resolution.source == .environment)
            #expect(samePath(resolution.appRoot, dataRoot))
            #expect(samePath(resolution.library.root, dataRoot))
            #expect(resolution.isDefaultLibrary)
            #expect(!resolution.usesPreferences)
            #expect(resolution.notice == nil)

            let preferences = LibraryPreferences(defaults: sandbox.defaults, isEnabled: resolution.usesPreferences)
            #expect(preferences.currentLibraryURL == nil)
            #expect(preferences.recentLibraryURLs.isEmpty)
            preferences.setCurrentLibrary(try sandbox.makeLibrary("Other-\(variable)"), isDefaultLibrary: false)
            preferences.addRecentLibrary(dataRoot)
            preferences.restoreCurrentLibraryPath(nil)
            preferences.clearRecentLibraries()
            #expect(sandbox.snapshotLibraryKeys() == before)
        }
    }

    @Test func relativeDataRootStillIgnoresPreferences() throws {
        let sandbox = try Sandbox()
        sandbox.defaults.set(try sandbox.makeLibrary("Remembered").path, forKey: LibraryPreferences.currentLibraryKey)
        let resolution = sandbox.resolve([LibrarySelection.dataRootVariable: "relative/path"])
        #expect(resolution.source == .environment)
        #expect(samePath(resolution.library.root, sandbox.appRoot))
        #expect(!resolution.usesPreferences)
    }

    @Test func testProcessUsesPerProcessFolderAndIgnoresPreferences() throws {
        let sandbox = try Sandbox()
        sandbox.defaults.set(try sandbox.makeLibrary("Remembered").path, forKey: LibraryPreferences.currentLibraryKey)
        let resolution = sandbox.resolve(["XCTestConfigurationFilePath": "/tmp/config"])
        #expect(resolution.source == .testProcess)
        #expect(resolution.appRoot.lastPathComponent == "CellCounter-tests-4242")
        #expect(samePath(resolution.library.root, resolution.appRoot))
        #expect(!resolution.usesPreferences)
    }

    @Test func rememberedLibraryIsOpenedWithAppWideRootUnchanged() throws {
        let sandbox = try Sandbox()
        let remembered = try sandbox.makeLibrary("Keratinocytes 2026")
        sandbox.defaults.set(remembered.path, forKey: LibraryPreferences.currentLibraryKey)
        let resolution = sandbox.resolve()
        #expect(resolution.source == .remembered)
        #expect(samePath(resolution.library.root, remembered))
        #expect(samePath(resolution.appRoot, sandbox.appRoot))
        #expect(!resolution.isDefaultLibrary)
        #expect(resolution.usesPreferences)
        #expect(resolution.notice == nil)
    }

    @Test func noPreferenceOpensDefaultLibrary() throws {
        let sandbox = try Sandbox()
        let resolution = sandbox.resolve()
        #expect(resolution.source == .defaultLibrary)
        #expect(resolution.isDefaultLibrary)
        #expect(samePath(resolution.library.root, sandbox.appRoot))
        #expect(resolution.notice == nil)
    }

    @Test func missingRememberedLibraryFallsBackWithNoticeAndCreatesNothing() throws {
        let sandbox = try Sandbox()
        let missing = sandbox.root.appendingPathComponent("Unplugged/Old.cellcounterlibrary", isDirectory: true)
        sandbox.defaults.set(missing.path, forKey: LibraryPreferences.currentLibraryKey)
        let resolution = sandbox.resolve()
        #expect(resolution.source == .defaultLibrary)
        #expect(resolution.isDefaultLibrary)
        #expect(resolution.notice?.contains("could not find the library “Old”") == true)
        #expect(!FileManager.default.fileExists(atPath: missing.path))
        // The preference survives, so reconnecting the drive reopens it.
        #expect(sandbox.defaults.string(forKey: LibraryPreferences.currentLibraryKey) == missing.path)
    }

    @Test func folderWithoutStoreIsRefusedAsLibrary() throws {
        let sandbox = try Sandbox()
        let plain = sandbox.root.appendingPathComponent("Just images", isDirectory: true)
        try FileManager.default.createDirectory(at: plain, withIntermediateDirectories: true)
        sandbox.defaults.set(plain.path, forKey: LibraryPreferences.currentLibraryKey)
        let resolution = sandbox.resolve()
        #expect(resolution.isDefaultLibrary)
        #expect(resolution.notice?.contains("is not a CellCounter library") == true)
        #expect(!LibraryLayout.isLibrary(at: plain))
        #expect(LibraryController.notALibraryMessage(for: plain).contains("use Choose folder… in the Library overview"))
        let inside = try sandbox.makeLibrary("Parent").appendingPathComponent("Images", isDirectory: true)
        #expect(LibraryController.notALibraryMessage(for: inside).contains("inside the library “Parent”"))
    }

    @Test func libraryRootVariableSelectsLibraryUnderDataRootOverride() throws {
        let sandbox = try Sandbox()
        let dataRoot = sandbox.root.appendingPathComponent("data", isDirectory: true)
        let library = try sandbox.makeLibrary("Bench")
        let chosen = sandbox.resolve([LibrarySelection.dataRootVariable: dataRoot.path,
                                      LibrarySelection.libraryRootVariable: library.path])
        #expect(samePath(chosen.appRoot, dataRoot))
        #expect(samePath(chosen.library.root, library))
        #expect(!chosen.usesPreferences)

        let missing = sandbox.resolve([LibrarySelection.dataRootVariable: dataRoot.path,
                                       LibrarySelection.libraryRootVariable: sandbox.root.appendingPathComponent("nope").path])
        #expect(samePath(missing.library.root, dataRoot))
        #expect(missing.notice != nil)

        // Without a data-root override the variable is ignored entirely.
        let ignored = sandbox.resolve([LibrarySelection.libraryRootVariable: library.path])
        #expect(ignored.source == .defaultLibrary)
        #expect(ignored.isDefaultLibrary)
    }

    // MARK: - Recent libraries

    @Test func recentListIsCappedDedupedAndMostRecentFirst() throws {
        let sandbox = try Sandbox()
        let preferences = LibraryPreferences(defaults: sandbox.defaults, isEnabled: true)
        let libraries = try (0..<10).map { try sandbox.makeLibrary("L\($0)") }
        for library in libraries { preferences.setCurrentLibrary(library, isDefaultLibrary: false) }
        var recents = preferences.recentLibraryURLs
        #expect(recents.count == LibraryPreferences.maximumRecentLibraries)
        #expect(samePath(recents[0], libraries[9]))
        #expect(samePath(recents[7], libraries[2]))
        #expect(samePath(try #require(preferences.currentLibraryURL), libraries[9]))

        preferences.addRecentLibrary(libraries[5])
        recents = preferences.recentLibraryURLs
        #expect(recents.count == 8)
        #expect(samePath(recents[0], libraries[5]))
        #expect(Set(recents.map { LibrarySelection.comparablePath($0) }).count == 8)

        // Choosing the Default Library forgets the choice (legacy behaviour)
        // but leaves the recent list alone.
        preferences.setCurrentLibrary(sandbox.appRoot, isDefaultLibrary: true)
        #expect(sandbox.defaults.object(forKey: LibraryPreferences.currentLibraryKey) == nil)
        #expect(preferences.recentLibraryURLs.count == 8)

        preferences.setCurrentLibrary(libraries[0], isDefaultLibrary: false)
        preferences.clearRecentLibraries()
        #expect(preferences.recentLibraryURLs.isEmpty)
        #expect(samePath(try #require(preferences.currentLibraryURL), libraries[0]))
    }

    @Test @MainActor func controllerListsRecentsAndLabelsArchives() throws {
        let sandbox = try Sandbox()
        let current = try sandbox.makeLibrary("Current", manifest: LibraryManifest(
            kind: .library, name: "Keratinocytes 2026", createdAt: Date(), appVersion: "test"))
        let archive = try sandbox.makeLibrary("Batch 7", manifest: LibraryManifest(
            kind: .batchArchive, name: "Batch 7 archive", createdAt: Date(), appVersion: "test"))
        let gone = sandbox.root.appendingPathComponent("Gone.cellcounterlibrary", isDirectory: true)
        sandbox.defaults.set([current.path, archive.path, gone.path, sandbox.appRoot.path],
                             forKey: LibraryPreferences.recentLibrariesKey)
        let resolution = LibraryResolution(appRoot: sandbox.appRoot, library: LibraryLayout(root: current),
                                           source: .remembered, notice: nil)
        let controller = LibraryController(resolution: resolution, defaults: sandbox.defaults)
        #expect(controller.displayName == "Keratinocytes 2026")
        #expect(!controller.isArchive)
        #expect(controller.summary(imageCount: 212) == "Keratinocytes 2026 · 212 images")
        #expect(controller.summary(imageCount: 1) == "Keratinocytes 2026 · 1 image")
        // The open library and the Default Library are not repeated as recents.
        #expect(controller.recentLibraries.map(\.name) == ["Batch 7 archive", "Gone"])
        #expect(controller.recentLibraries[0].isArchive)
        #expect(controller.recentLibraries[0].menuTitle.contains("(Archive)"))
        #expect(!controller.recentLibraries[1].isAvailable)

        controller.clearRecentLibraries()
        #expect(controller.recentLibraries.isEmpty)

        let archiveController = LibraryController(
            resolution: LibraryResolution(appRoot: sandbox.appRoot, library: LibraryLayout(root: archive),
                                          source: .remembered, notice: nil),
            defaults: sandbox.defaults)
        #expect(archiveController.isArchive)
        #expect(archiveController.kindLabel == "Archive")
    }

    // MARK: - FileStore split

    @Test @MainActor func fileStoreKeepsLibraryDataAndAppResourcesApart() throws {
        let sandbox = try Sandbox()
        let library = try sandbox.makeLibrary("Project")
        let store = FileStore(resolution: LibraryResolution(
            appRoot: sandbox.appRoot, library: LibraryLayout(root: library), source: .environment, notice: nil))
        let id = UUID()
        let libraryPaths = [store.storeURL, store.analysisJobsURL, store.imagesDir, store.displayImagesDir,
                            store.thumbsDir, store.embeddingsDir, store.exportsDir,
                            store.imageURL(for: id, extension: "png"), store.thumbURL(for: id),
                            store.displayImageURL(for: id)]
        for url in libraryPaths {
            #expect(url.path.hasPrefix(library.standardizedFileURL.path + "/"), "\(url.path) must be inside the library")
        }
        let appPaths = [store.pythonDir, store.pythonVenvDir, store.pythonVenv4Dir, store.pythonInterpreterURL,
                        store.installIncompleteSentinel, store.modelsDir, store.protocolsDir]
        for url in appPaths {
            #expect(url.path.hasPrefix(sandbox.appRoot.standardizedFileURL.path + "/"), "\(url.path) must be app-wide")
        }
        #expect(store.storeURL.lastPathComponent == "store.sqlite")
        #expect(store.analysisJobsURL.lastPathComponent == "analysis-jobs.json")
        #expect(samePath(store.libraryRoot, library))
        let fm = FileManager.default
        #expect(fm.fileExists(atPath: store.modelsDir.path))
        #expect(fm.fileExists(atPath: store.imagesDir.path))
        #expect(!fm.fileExists(atPath: sandbox.appRoot.appendingPathComponent("Images").path),
                "A separate library must not create image folders in the app-wide root")
    }

    @Test @MainActor func defaultLibraryKeepsTheLegacySingleFolderLayout() throws {
        let sandbox = try Sandbox()
        let store = FileStore(resolution: LibraryResolution(
            appRoot: sandbox.appRoot, library: LibraryLayout(root: sandbox.appRoot), source: .environment, notice: nil))
        let root = sandbox.appRoot.standardizedFileURL.path
        #expect(store.storeURL.path == root + "/store.sqlite")
        #expect(store.analysisJobsURL.path == root + "/analysis-jobs.json")
        #expect(store.imagesDir.path == root + "/Images")
        #expect(store.thumbsDir.path == root + "/Thumbnails")
        #expect(store.pythonDir.path == root + "/python")
        #expect(store.modelsDir.path == root + "/Models")
        #expect(store.protocolsDir.path == root + "/Protocols")
        #expect(FileManager.default.fileExists(atPath: store.imagesDir.path))
    }

    @Test @MainActor func fileStoreNeverRecreatesAMissingLibraryRoot() throws {
        let sandbox = try Sandbox()
        let missing = sandbox.root.appendingPathComponent("Volumes/Drive/Gone.cellcounterlibrary", isDirectory: true)
        _ = FileStore(resolution: LibraryResolution(
            appRoot: sandbox.appRoot, library: LibraryLayout(root: missing), source: .environment, notice: nil))
        #expect(!FileManager.default.fileExists(atPath: missing.path))
        #expect(!FileManager.default.fileExists(atPath: missing.deletingLastPathComponent().path))
    }

    // MARK: - New Library

    @MainActor private func sourceContainer() throws -> ModelContainer {
        let schema = Repositories.librarySchema()
        let container = try ModelContainer(for: schema, configurations: [ModelConfiguration(isStoredInMemoryOnly: true)])
        let context = container.mainContext
        context.insert(CalibrationPresetRecord(name: "Lab scope 20x", pxPerUm: 1.55, isDefault: true))
        context.insert(CalibrationPresetRecord(name: "Lab scope 40x", pxPerUm: 3.1))
        context.insert(BinPresetRecord(name: "HaCaT", thresholds: [12, 19.5]))
        context.insert(ConditionRecord(name: "Control", color: "#4db3a8", order: 0))
        context.insert(ConditionRecord(name: "Y-27632", color: "#e05a47", order: 1))
        let batch = BatchRecord(name: "Should not be copied", displayName: "Should not be copied",
                                modelId: "test", pxPerUm: 1, thresholds: [10, 20])
        context.insert(batch)
        try context.save()
        return container
    }

    @MainActor private func openStore(_ layout: LibraryLayout) throws -> ModelContext {
        let schema = Repositories.librarySchema()
        let container = try ModelContainer(for: schema, configurations: [
            ModelConfiguration("CellCounter", schema: schema, url: layout.storeURL)])
        return ModelContext(container)
    }

    @Test @MainActor func newLibraryWritesLayoutManifestStoreAndCopiedPresets() throws {
        let sandbox = try Sandbox()
        let source = try sourceContainer()
        let starter = try LibraryStarterContent.capture(from: source.mainContext)
        let url = LibraryCreator.normalizedURL(for: sandbox.root.appendingPathComponent("Keratinocytes 2026"))
        #expect(url.lastPathComponent == "Keratinocytes 2026.cellcounterlibrary")

        let layout = try LibraryCreator.create(at: url, name: "Keratinocytes 2026", starter: starter)
        let fm = FileManager.default
        for dir in [layout.imagesDir, layout.displayImagesDir, layout.thumbsDir, layout.embeddingsDir, layout.exportsDir] {
            var isDirectory: ObjCBool = false
            #expect(fm.fileExists(atPath: dir.path, isDirectory: &isDirectory) && isDirectory.boolValue)
        }
        #expect(LibraryLayout.isLibrary(at: url))
        let manifest = try #require(layout.readManifest())
        #expect(manifest.kind == .library)
        #expect(manifest.name == "Keratinocytes 2026")
        #expect(manifest.archivedBatch == nil)
        #expect(layout.displayName == "Keratinocytes 2026")

        let context = try openStore(layout)
        let calibrations = try context.fetch(FetchDescriptor<CalibrationPresetRecord>(sortBy: [SortDescriptor(\.name)]))
        #expect(calibrations.map(\.name) == ["Lab scope 20x", "Lab scope 40x"])
        #expect(calibrations.map(\.pxPerUm) == [1.55, 3.1])
        #expect(calibrations.map(\.isDefault) == [true, false])
        let bins = try context.fetch(FetchDescriptor<BinPresetRecord>())
        #expect(bins.map(\.name) == ["HaCaT"])
        #expect(bins.first?.thresholds == [12, 19.5])
        let conditions = try context.fetch(FetchDescriptor<ConditionRecord>(sortBy: [SortDescriptor(\.order)]))
        #expect(conditions.map(\.name) == ["Control", "Y-27632"])
        #expect(conditions.map(\.color) == ["#4db3a8", "#e05a47"])
        #expect(try context.fetchCount(FetchDescriptor<BatchRecord>()) == 0)
        #expect(try context.fetchCount(FetchDescriptor<ImageRecord>()) == 0)
    }

    @Test @MainActor func newLibraryWithoutCopyingStartsWithControlOnly() throws {
        let sandbox = try Sandbox()
        let layout = try LibraryCreator.create(at: sandbox.root.appendingPathComponent("Empty.cellcounterlibrary"),
                                               name: "Empty", starter: .fresh)
        let context = try openStore(layout)
        #expect(try context.fetchCount(FetchDescriptor<CalibrationPresetRecord>()) == 0)
        #expect(try context.fetchCount(FetchDescriptor<BinPresetRecord>()) == 0)
        #expect(try context.fetch(FetchDescriptor<ConditionRecord>()).map(\.name) == ["Control"])
    }

    @Test @MainActor func newLibraryNeverOverwritesOrNests() throws {
        let sandbox = try Sandbox()
        let existing = try sandbox.makeLibrary("Existing")
        let marker = existing.appendingPathComponent("keep.txt")
        try Data("keep".utf8).write(to: marker)
        #expect(throws: LibraryCreationError.self) {
            try LibraryCreator.create(at: existing, name: "Existing", starter: .fresh)
        }
        #expect(FileManager.default.fileExists(atPath: marker.path))
        let nested = existing.appendingPathComponent("Inner.cellcounterlibrary", isDirectory: true)
        #expect(throws: LibraryCreationError.self) {
            try LibraryCreator.create(at: nested, name: "Inner", starter: .fresh)
        }
        #expect(!FileManager.default.fileExists(atPath: nested.path))
    }

    // MARK: - Relaunch handshake

    @Test func relaunchArgumentsRoundTripAndGuardTheEnvironment() throws {
        let arguments = LibraryRelaunch.arguments(previousProcess: 123, expectedDataRoot: "/private/tmp/data")
        let request = LibraryRelaunch.parse(["/Applications/CellCounting.app/Contents/MacOS/CellCounting"] + arguments)
        #expect(request == LibraryRelaunch.Request(previousProcess: 123, expectedDataRoot: "/private/tmp/data"))
        #expect(!LibraryRelaunch.environmentSatisfies(request, environment: [:]))
        #expect(!LibraryRelaunch.environmentSatisfies(request, environment: [LibrarySelection.dataRootVariable: "/other"]))
        #expect(LibraryRelaunch.environmentSatisfies(request, environment: [LibrarySelection.dataRootVariable: "/private/tmp/data"]))

        let normal = LibraryRelaunch.parse(LibraryRelaunch.arguments(previousProcess: 77, expectedDataRoot: nil))
        #expect(normal == LibraryRelaunch.Request(previousProcess: 77, expectedDataRoot: nil))
        #expect(LibraryRelaunch.environmentSatisfies(normal, environment: [:]))
        #expect(LibraryRelaunch.parse(["app", "-NSDocumentRevisionsDebugMode", "YES"]) == LibraryRelaunch.Request())

        let sandbox = try Sandbox()
        let target = try sandbox.makeLibrary("Target")
        let remembered = LibraryResolution(appRoot: sandbox.appRoot, library: LibraryLayout(root: sandbox.appRoot),
                                           source: .defaultLibrary, notice: nil)
        #expect(LibraryRelaunch.environment(for: remembered, target: target, targetIsDefault: false).isEmpty)
        let overridden = LibraryResolution(appRoot: sandbox.appRoot, library: LibraryLayout(root: sandbox.appRoot),
                                           source: .environment, notice: nil)
        let environment = LibraryRelaunch.environment(for: overridden, target: target, targetIsDefault: false)
        #expect(environment[LibrarySelection.dataRootVariable] == sandbox.appRoot.path)
        #expect(environment[LibrarySelection.libraryRootVariable] == target.standardizedFileURL.path)
        let defaultEnvironment = LibraryRelaunch.environment(for: overridden, target: sandbox.appRoot, targetIsDefault: true)
        #expect(defaultEnvironment[LibrarySelection.libraryRootVariable] == nil)
        #expect(defaultEnvironment[LibrarySelection.dataRootVariable] == sandbox.appRoot.path)
    }

    @Test func switchingIsRefusedInTestProcessesAndWithUnusableOverrides() {
        #expect(LibraryController.switchingUnavailableReason(for: .testProcess, environment: [:]) != nil)
        #expect(LibraryController.switchingUnavailableReason(
            for: .environment, environment: [LibrarySelection.dataRootVariable: "relative"]) != nil)
        #expect(LibraryController.switchingUnavailableReason(
            for: .environment, environment: [LibrarySelection.dataRootVariable: "/private/tmp/data"]) == nil)
        #expect(LibraryController.switchingUnavailableReason(for: .remembered, environment: [:]) == nil)
        #expect(LibraryController.switchingUnavailableReason(for: .defaultLibrary, environment: [:]) == nil)
    }

    @Test func waitForExitTracksTheProcess() throws {
        #expect(LibraryRelaunch.waitForExit(of: getpid(), timeout: 0))
        let sleeper = Process()
        sleeper.executableURL = URL(fileURLWithPath: "/bin/sleep")
        sleeper.arguments = ["5"]
        try sleeper.run()
        #expect(!LibraryRelaunch.waitForExit(of: sleeper.processIdentifier, timeout: 0.2))
        sleeper.terminate()
        sleeper.waitUntilExit()
        #expect(LibraryRelaunch.waitForExit(of: sleeper.processIdentifier, timeout: 2))
    }
}
