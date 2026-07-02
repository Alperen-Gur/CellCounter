import AppKit
import UniformTypeIdentifiers

/// Wrapper around NSOpenPanel so views can present file pickers without owning AppKit details.
@MainActor
func presentOpenPanel(allowedExtensions: [String],
                      allowFolders: Bool,
                      allowMultiple: Bool,
                      completion: @escaping ([URL]) -> Void) {
    let panel = NSOpenPanel()
    panel.canChooseFiles = !allowFolders
    panel.canChooseDirectories = allowFolders
    panel.allowsMultipleSelection = allowMultiple
    if !allowFolders {
        panel.allowedContentTypes = allowedExtensions.compactMap { UTType(filenameExtension: $0) }
    }
    panel.begin { resp in
        if resp == .OK {
            completion(panel.urls)
        }
    }
}

