import AppKit
import Foundation
import UniformTypeIdentifiers

/// Stable task identifiers shared with navigation.catalog and session selections.
/// These routes change presentation only; every analysis continues to use the
/// same WorkbenchSession and canonical operation dispatcher.
enum WorkbenchTask: String, CaseIterable, Identifiable {
    case preparation, segmentation, measurements, review, workflows, export

    var id: String { rawValue }
    var title: String {
        switch self {
        case .preparation: "Images"
        case .segmentation: "Segmentation"
        case .measurements: "Measurements"
        case .review: "Review"
        case .workflows: "Workflows"
        case .export: "Results & export"
        }
    }
    var detail: String {
        switch self {
        case .preparation: "Import images, organize acquisitions and prepare source data."
        case .segmentation: "Segment objects, inspect masks and save corrections."
        case .measurements: "Inspect object measurements, assays and biological replicates."
        case .review: "Review saved analyses and record quality-control decisions."
        case .workflows: "Build repeatable analyses and manage background jobs."
        case .export: "Summarize results and export images, measurements or complete projects."
        }
    }
}

extension WorkbenchSession {
    /// A task-only request must never reload an image or replace an edit draft.
    func isTaskOnlyNavigation(_ selection: WorkbenchJSON) -> Bool {
        guard selection["task"].string.flatMap(WorkbenchTask.init(rawValue:)) != nil else { return false }
        return Set(selection.object.keys) == ["task"]
    }

    func presentCreateProject(name: String = "Microscopy project") {
        guard canRefreshWithoutDiscardingEdits, !hasActiveWorkers else {
            reportStatus("Finish the current draft and background work before changing projects."); return
        }
        let panel = NSSavePanel()
        panel.title = "Create microscopy project"
        panel.prompt = "Create"
        panel.nameFieldStringValue = "\(name).ccproject"
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false
        panel.begin { result in
            guard result == .OK, let url = panel.url else { return }
            self.task = .preparation
            self.create(path: url.path, name: url.deletingPathExtension().lastPathComponent)
        }
    }

    func presentOpenProject() {
        guard canRefreshWithoutDiscardingEdits, !hasActiveWorkers else {
            reportStatus("Finish the current draft and background work before changing projects."); return
        }
        let panel = NSOpenPanel()
        panel.title = "Open microscopy project folder"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.begin { result in
            guard result == .OK, let url = panel.url else { return }
            self.task = .preparation
            self.open(path: url.path)
        }
    }

    func presentImportImages() {
        guard hasProject else { task = .preparation; reportStatus("Create or open a microscopy project, then import images into it."); return }
        guard !busy, !hasActiveWorkers, canRefreshWithoutDiscardingEdits else { return }
        presentOpenPanel(allowedExtensions: ["png", "jpg", "jpeg", "bmp", "tif", "tiff"],
                         allowFolders: false, allowMultiple: true) { urls in
            self.task = .preparation
            self.importImages(urls)
        }
    }

    func presentImportFolder() {
        guard hasProject else { task = .preparation; reportStatus("Create or open a microscopy project, then import an image folder into it."); return }
        guard !busy, !hasActiveWorkers, canRefreshWithoutDiscardingEdits else { return }
        let panel = NSOpenPanel()
        panel.title = "Import image folder"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.begin { result in
            guard result == .OK, let folder = panel.url else { return }
            self.perform("Finding images to import…", refreshOnConflict: false) {
                let images = await Task.detached(priority: .userInitiated) {
                    let extensions: Set<String> = ["png", "jpg", "jpeg", "bmp", "tif", "tiff"]
                    guard let enumerator = FileManager.default.enumerator(at: folder,
                        includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles]) else { return [URL]() }
                    return enumerator.compactMap { $0 as? URL }.filter {
                        extensions.contains($0.pathExtension.lowercased()) &&
                        (try? $0.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true
                    }.sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
                }.value
                guard !images.isEmpty else {
                    self.reportStatus("No supported TIFF, PNG, JPEG or BMP images were found in this folder."); return
                }
                try await self.importImageFiles(images)
                self.task = .preparation
                self.reportStatus("Images imported into the current project.")
            }
        }
    }

    func presentExportProject() {
        guard hasProject, !busy, !hasActiveWorkers else { return }
        let panel = NSSavePanel()
        panel.title = "Export analysis package"
        panel.allowedContentTypes = [.zip]
        panel.nameFieldStringValue = "\(projectName).zip"
        panel.begin { result in
            if result == .OK, let url = panel.url { self.export(to: url) }
        }
    }
}
