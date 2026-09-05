import SwiftUI
import AppKit

/// Real actions supplied by the currently visible screen. Absent actions disable
/// their menu items. Canvas editing has a separate focus key so it cannot hide
/// the parent screen's exports, image navigation or processing commands.
@MainActor struct ScreenShortcutActions {
    var find: (() -> Void)? = nil
    var selectAll: (() -> Void)? = nil
    var deleteSelection: (() -> Void)? = nil
    var openSelection: (() -> Void)? = nil
    var newItem: (() -> Void)? = nil
    var save: (() -> Void)? = nil
    var export: (() -> Void)? = nil
    var exportBundle: (() -> Void)? = nil
    var run: (() -> Void)? = nil
    var preview: (() -> Void)? = nil
    var pauseResume: (() -> Void)? = nil
    var cancel: (() -> Void)? = nil
    var previous: (() -> Void)? = nil
    var next: (() -> Void)? = nil
    var zoomIn: (() -> Void)? = nil
    var zoomOut: (() -> Void)? = nil
    var fit: (() -> Void)? = nil
    var overlayBoxes: (() -> Void)? = nil
    var overlayOutlines: (() -> Void)? = nil
    var toggleOverlay: (() -> Void)? = nil
    var toggleFullScreen: (() -> Void)? = nil
    var keep: (() -> Void)? = nil
    var edit: (() -> Void)? = nil
    var undo: (() -> Void)? = nil
    var redo: (() -> Void)? = nil
    var isModalContext = false

    func handler(for action: KeyboardAction) -> (() -> Void)? {
        switch action {
        case .find: return find
        case .selectAll: return selectAll
        case .deleteSelection: return deleteSelection
        case .openSelection: return openSelection
        case .newItem: return newItem
        case .save: return save
        case .export: return export
        case .exportBundle: return exportBundle
        case .run: return run
        case .preview: return preview
        case .pauseResume: return pauseResume
        case .cancel: return cancel
        case .previous: return previous
        case .next: return next
        case .zoomIn: return zoomIn
        case .zoomOut: return zoomOut
        case .fit: return fit
        case .overlayBoxes: return overlayBoxes
        case .overlayOutlines: return overlayOutlines
        case .toggleOverlay: return toggleOverlay
        case .toggleFullScreen: return toggleFullScreen
        case .keep: return keep
        case .edit: return edit
        case .undo: return undo
        case .redo: return redo
        }
    }
}

private struct ScreenShortcutKey: FocusedValueKey { typealias Value = ScreenShortcutActions }
private struct LocalShortcutKey: FocusedValueKey { typealias Value = ScreenShortcutActions }
private struct EditingShortcutKey: FocusedValueKey { typealias Value = ScreenShortcutActions }
extension FocusedValues {
    var cellCounterShortcuts: ScreenShortcutActions? {
        get { self[ScreenShortcutKey.self] }
        set { self[ScreenShortcutKey.self] = newValue }
    }
    var cellCounterLocalShortcuts: ScreenShortcutActions? {
        get { self[LocalShortcutKey.self] }
        set { self[LocalShortcutKey.self] = newValue }
    }
    var cellCounterEditingShortcuts: ScreenShortcutActions? {
        get { self[EditingShortcutKey.self] }
        set { self[EditingShortcutKey.self] = newValue }
    }
}

nonisolated enum KeyboardAction: String, CaseIterable, Identifiable {
    case find, selectAll, deleteSelection, openSelection, newItem, save, export, exportBundle
    case run, preview, pauseResume, cancel, previous, next, zoomIn, zoomOut, fit
    case overlayBoxes, overlayOutlines, toggleOverlay, toggleFullScreen, keep, edit, undo, redo
    var id: String { rawValue }
}

@MainActor struct ShortcutDefinition: Identifiable {
    var id: KeyboardAction
    var title: String
    var key: KeyEquivalent
    var modifiers: EventModifiers = .command
    var display: String
}
nonisolated struct ShortcutHelpGroup: Identifiable {
    var id: String { title }
    var title: String
    var rows: [(String, String)]
}

@MainActor enum KeyboardShortcutRegistry {
    static let definitions: [ShortcutDefinition] = [
        .init(id: .find, title: "Find…", key: "f", display: "⌘F"),
        .init(id: .selectAll, title: "Select All", key: "a", display: "⌘A"),
        .init(id: .deleteSelection, title: "Delete or Reject Selection…", key: .delete, display: "⌘⌫"),
        .init(id: .openSelection, title: "Open Selection", key: .return, display: "⌘Return"),
        .init(id: .newItem, title: "New Item…", key: "n", display: "⌘N"),
        .init(id: .save, title: "Save…", key: "s", display: "⌘S"),
        .init(id: .export, title: "Export…", key: "e", display: "⌘E"),
        .init(id: .exportBundle, title: "Export Image and Measurements…", key: "e", modifiers: [.command, .shift], display: "⌘⇧E"),
        .init(id: .run, title: "Run or Refresh", key: "r", display: "⌘R"),
        .init(id: .preview, title: "Preview", key: "r", modifiers: [.command, .shift], display: "⌘⇧R"),
        .init(id: .pauseResume, title: "Pause or Resume", key: "p", modifiers: [.command, .option], display: "⌘⌥P"),
        .init(id: .cancel, title: "Cancel Current Operation", key: ".", display: "⌘."),
        .init(id: .previous, title: "Previous Image, Step or Section", key: "[", display: "⌘["),
        .init(id: .next, title: "Next Image, Step or Section", key: "]", display: "⌘]"),
        .init(id: .zoomIn, title: "Zoom In", key: "=", display: "⌘= / ⌘+"),
        .init(id: .zoomOut, title: "Zoom Out", key: "-", display: "⌘−"),
        .init(id: .fit, title: "Fit to View", key: "0", display: "⌘0"),
        .init(id: .overlayBoxes, title: "Box Overlay", key: "1", display: "⌘1"),
        .init(id: .overlayOutlines, title: "Outline Overlay", key: "2", display: "⌘2"),
        .init(id: .toggleOverlay, title: "Toggle Cell Overlay", key: "h", modifiers: [.command, .shift], display: "⌘⇧H"),
        .init(id: .toggleFullScreen, title: "Expand or Collapse Cell Editor", key: "f", modifiers: [.command, .shift], display: "⌘⇧F"),
        .init(id: .keep, title: "Keep Cell", key: "k", display: "⌘K"),
        .init(id: .edit, title: "Edit Selection", key: "i", display: "⌘I"),
        .init(id: .undo, title: "Undo", key: "z", display: "⌘Z"),
        .init(id: .redo, title: "Redo", key: "z", modifiers: [.command, .shift], display: "⌘⇧Z / ⌘Y"),
    ]
    static let navigation: [(AppView, String, String)] = [
        (.home, "Home", "1"), (.batch, "Batches", "2"), (.imagesLibrary, "Images Library", "3"),
        (.models, "Models", "4"), (.queue, "Processing", "5"), (.reviewQueue, "Review Queue", "6"),
        (.compare, "Compare", "7"), (.fineTune, "Fine-tune", "8"), (.workspace, "Microscopy Workspace", "9"),
    ]
    static var groups: [ShortcutHelpGroup] {
        [
            .init(title: "Global", rows: [("⌘O", "Open images"), ("⌘⇧O", "Open folder"),
                ("⌘,", "Settings"), ("⌘⇧K", "Calibrate scale"), ("⌘⇧P", "Analysis protocols"),
                ("⌘⇧G", "Export GeoJSON"), ("⌘/", "Keyboard shortcuts")]),
            .init(title: "Navigate", rows: navigation.map { ("⌘⌥\($0.2)", $0.1) }),
            .init(title: "Current screen — enabled when available", rows: definitions.map { ($0.display, $0.title) }),
            .init(title: "Focused image canvas", rows: [("Space", "Toggle overlay"), ("X / Z", "Toggle mask fills / outlines"),
                ("V / A / R / M", "Select / add / remove / merge cells"), ("C / G / T", "Manual count / reference point / trace boundary"),
                ("P / B", "Point prompt / box prompt"), ("Delete", "Remove selected cells"),
                ("← / →", "Previous / next image"), ("Esc", "Clear selection and exit editing")]),
            .init(title: "Review queue", rows: [("K / R / E", "Keep / reject / edit diameter when the review canvas has focus"),
                ("→", "Skip current cell"), ("Return", "Save diameter edit"), ("Esc", "Cancel diameter edit or return Home")]),
            .init(title: "Dialogs", rows: [("Return", "Confirm the visible default action"), ("Esc", "Dismiss when the operation allows it")]),
        ]
    }
    static func handler(for action: KeyboardAction, screen: ScreenShortcutActions?,
                        local: ScreenShortcutActions? = nil, editing: ScreenShortcutActions? = nil) -> (() -> Void)? {
        editing?.handler(for: action) ?? local?.handler(for: action) ?? screen?.handler(for: action)
    }
    static func definition(_ action: KeyboardAction) -> ShortcutDefinition { definitions.first { $0.id == action }! }
}

@MainActor enum KeyboardShortcutContext {
    static var isEditingText: Bool {
        guard let responder = NSApp.keyWindow?.firstResponder else { return false }
        return responder is NSText || responder is NSTextField
    }
    static var hasNativeSheet: Bool {
        NSApp.keyWindow?.sheetParent != nil || NSApp.keyWindow?.attachedSheet != nil || NSApp.modalWindow != nil
    }
    static var hasBlockingNativePanel: Bool {
        NSApp.modalWindow != nil || NSApp.keyWindow is NSOpenPanel || NSApp.keyWindow is NSSavePanel
            || NSApp.keyWindow?.sheetParent?.sheetParent != nil
    }
    static func hasOverlay(_ state: AppState) -> Bool {
        state.showCalibration || state.showAnalysisProtocols || state.showOnboarding
            || state.showInstallCellpose || state.showInstallCellpose4 || state.showDuplicateImportSheet
    }
    static func canRun(_ action: KeyboardAction, hasOverlay: Bool, hasNativeSheet: Bool,
                       isEditingText: Bool, isModalContext: Bool, hasBlockingNativePanel: Bool = false) -> Bool {
        guard !hasOverlay, !hasBlockingNativePanel, !hasNativeSheet || isModalContext else { return false }
        if isEditingText { return [.find, .save, .export, .exportBundle, .cancel].contains(action) }
        return true
    }
}

struct AppKeyboardCommands: Commands {
    let state: AppState
    @Binding var showShortcuts: Bool
    @FocusedValue(\.cellCounterShortcuts) private var screen
    @FocusedValue(\.cellCounterEditingShortcuts) private var editing
    @FocusedValue(\.cellCounterLocalShortcuts) private var local

    var body: some Commands {
        CommandGroup(replacing: .appSettings) {
            Button("Settings…") { state.view = .settings }.keyboardShortcut(",", modifiers: .command).disabled(blockNavigation)
        }
        CommandGroup(replacing: .newItem) {
            Button("Open Images…", action: openImages).keyboardShortcut("o", modifiers: .command).disabled(blockNavigation || state.isPreparingImport)
            Button("Open Folder…", action: openFolder).keyboardShortcut("o", modifiers: [.command, .shift]).disabled(blockNavigation || state.isPreparingImport)
            Divider()
            command(.newItem); command(.openSelection); command(.save)
            Divider()
            command(.export); command(.exportBundle)
        }
        CommandGroup(replacing: .undoRedo) {
            Button("Undo") { undo(redo: false) }.keyboardShortcut("z", modifiers: .command).disabled(!canUndo(redo: false))
            Button("Redo") { undo(redo: true) }.keyboardShortcut("z", modifiers: [.command, .shift]).disabled(!canUndo(redo: true))
            Button("Redo (Alternate)") { undo(redo: true) }.keyboardShortcut("y", modifiers: .command).disabled(!canUndo(redo: true))
        }
        CommandGroup(after: .pasteboard) {
            Button("Select All") {
                if canEditText { NSApp.sendAction(#selector(NSText.selectAll(_:)), to: nil, from: nil) }
                else { perform(.selectAll) }
            }.keyboardShortcut("a", modifiers: .command)
                .disabled(!canEditText && !enabled(.selectAll))
            command(.deleteSelection); command(.find)
        }
        CommandMenu("Navigate") {
            ForEach(Array(KeyboardShortcutRegistry.navigation.enumerated()), id: \.offset) { _, entry in
                Button(entry.1) { state.view = entry.0 }
                    .keyboardShortcut(KeyEquivalent(Character(entry.2)), modifiers: [.command, .option])
                    .disabled(blockNavigation)
            }
            Divider(); command(.previous); command(.next)
        }
        CommandMenu("Analysis") {
            command(.run); command(.preview); command(.pauseResume); command(.cancel)
            Divider()
            Button("Calibrate Scale…") { state.showCalibration = true }
                .keyboardShortcut("k", modifiers: [.command, .shift]).disabled(blockNavigation)
            command(.keep); command(.edit)
        }
        CommandMenu("Image") {
            command(.zoomIn)
            Button("Zoom In (Alternate)") { perform(.zoomIn) }.keyboardShortcut("+", modifiers: .command).disabled(!enabled(.zoomIn))
            command(.zoomOut); command(.fit)
            Divider(); command(.overlayBoxes); command(.overlayOutlines); command(.toggleOverlay); command(.toggleFullScreen)
        }
        CommandGroup(after: .help) {
            Button("Keyboard Shortcuts") { showShortcuts.toggle() }.keyboardShortcut("/", modifiers: .command)
                .disabled(!showShortcuts && (KeyboardShortcutContext.hasOverlay(state) || KeyboardShortcutContext.hasNativeSheet))
        }
    }
    private var blockNavigation: Bool {
        showShortcuts || KeyboardShortcutContext.hasOverlay(state) || KeyboardShortcutContext.hasNativeSheet
    }
    @ViewBuilder private func command(_ action: KeyboardAction) -> some View {
        let definition = KeyboardShortcutRegistry.definition(action)
        Button(definition.title) { perform(action) }
            .keyboardShortcut(definition.key, modifiers: definition.modifiers).disabled(!enabled(action))
    }
    private func handler(_ action: KeyboardAction) -> (() -> Void)? {
        KeyboardShortcutRegistry.handler(for: action, screen: screen, local: local, editing: editing)
    }
    private func enabled(_ action: KeyboardAction) -> Bool {
        if action == .cancel && showShortcuts { return true }
        return handler(action) != nil && KeyboardShortcutContext.canRun(action,
            hasOverlay: showShortcuts || KeyboardShortcutContext.hasOverlay(state),
            hasNativeSheet: KeyboardShortcutContext.hasNativeSheet,
            isEditingText: KeyboardShortcutContext.isEditingText,
            isModalContext: screen?.isModalContext ?? false,
            hasBlockingNativePanel: KeyboardShortcutContext.hasBlockingNativePanel)
    }
    private func perform(_ action: KeyboardAction) {
        if action == .cancel && showShortcuts { showShortcuts = false; return }
        guard enabled(action) else { return }
        handler(action)?()
    }
    private var canEditText: Bool {
        KeyboardShortcutContext.isEditingText && !showShortcuts && !KeyboardShortcutContext.hasOverlay(state)
    }
    private func canUndo(redo: Bool) -> Bool {
        if canEditText {
            return redo ? NSApp.keyWindow?.firstResponder?.undoManager?.canRedo == true
                : NSApp.keyWindow?.firstResponder?.undoManager?.canUndo == true
        }
        return enabled(redo ? .redo : .undo)
    }
    private func undo(redo: Bool) {
        if canEditText {
            NSApp.sendAction(Selector(redo ? "redo:" : "undo:"), to: nil, from: nil)
        } else { perform(redo ? .redo : .undo) }
    }
    private func openImages() {
        presentOpenPanel(allowedExtensions: Array(ImageLoader.supported), allowFolders: false, allowMultiple: true) {
            state.importAndAnalyze(urls: $0)
        }
    }
    private func openFolder() {
        presentOpenPanel(allowedExtensions: Array(ImageLoader.supported), allowFolders: true, allowMultiple: false) { urls in
            guard let folder = urls.first else { return }
            Task { @MainActor in
                let extensions = ImageLoader.supported
                let images = await Task.detached(priority: .userInitiated) {
                    guard let enumerator = FileManager.default.enumerator(at: folder,
                        includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles]) else { return [URL]() }
                    return enumerator.compactMap { $0 as? URL }.filter {
                        extensions.contains($0.pathExtension.lowercased())
                            && (try? $0.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true
                    }.sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
                }.value
                if images.isEmpty {
                    let alert = NSAlert()
                    alert.messageText = "No supported images in this folder"
                    alert.informativeText = "Choose a folder containing microscopy images, such as TIFF, PNG or JPEG files."
                    alert.runModal()
                } else { state.importAndAnalyze(urls: images) }
            }
        }
    }
}
