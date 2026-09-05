import SwiftUI
import Testing
@testable import CellCounting

@MainActor struct KeyboardShortcutTests {
    @Test func everyContextCommandHasOneUniqueMenuBindingAndHelpEntry() {
        let definitions = KeyboardShortcutRegistry.definitions
        #expect(Set(definitions.map(\.id)) == Set(KeyboardAction.allCases))
        #expect(definitions.count == KeyboardAction.allCases.count)
        let keys = definitions.map { "\($0.key.character)|\($0.modifiers.rawValue)" }
        #expect(Set(keys).count == keys.count)
        let help = KeyboardShortcutRegistry.groups.flatMap(\.rows)
        for definition in definitions {
            #expect(help.contains { $0.0 == definition.display && $0.1 == definition.title })
        }
    }

    @Test func navigationDoesNotReplaceCanvasOverlayNumbers() {
        let entries = KeyboardShortcutRegistry.navigation
        #expect(Set(entries.map { $0.0 }) == Set([AppView.home, .batch, .imagesLibrary,
            .models, .queue, .reviewQueue, .compare, .fineTune, .workspace]))
        #expect(Set(entries.map { $0.2 }).count == entries.count)
        #expect(KeyboardShortcutRegistry.definition(.overlayBoxes).modifiers == .command)
        #expect(KeyboardShortcutRegistry.definition(.overlayOutlines).modifiers == .command)
        #expect(KeyboardShortcutRegistry.definition(.preview).modifiers == [.command, .shift])
    }

    @Test func focusedEditorPreservesParentExportAndLocalSaveActions() {
        var invoked: [String] = []
        let screen = ScreenShortcutActions(selectAll: { invoked.append("screen selection") },
            export: { invoked.append("image export") }, next: { invoked.append("next step") },
            undo: { invoked.append("screen undo") })
        let local = ScreenShortcutActions(save: { invoked.append("save reviewed masks") },
            next: { invoked.append("next training image") })
        let editor = ScreenShortcutActions(selectAll: { invoked.append("canvas selection") },
            undo: { invoked.append("canvas undo") })
        for action: KeyboardAction in [.selectAll, .undo, .export, .save, .next] {
            KeyboardShortcutRegistry.handler(for: action, screen: screen, local: local, editing: editor)?()
        }
        #expect(invoked == ["canvas selection", "canvas undo", "image export", "save reviewed masks", "next training image"])
        #expect(KeyboardShortcutRegistry.handler(for: .run, screen: screen, local: local, editing: editor) == nil)
        #expect(KeyboardShortcutRegistry.handler(for: .save, screen: nil) == nil)
    }

    @Test func textEditingDoesNotTriggerCanvasOrDestructiveActions() {
        for action: KeyboardAction in [.selectAll, .deleteSelection, .undo, .redo, .previous,
                                        .next, .zoomIn, .toggleOverlay, .run, .keep, .edit] {
            #expect(!KeyboardShortcutContext.canRun(action, hasOverlay: false, hasNativeSheet: false,
                isEditingText: true, isModalContext: false))
        }
        // Select all and undo/redo use the native text responder in Commands;
        // only these nondestructive document actions may reach the screen.
        for action: KeyboardAction in [.find, .save, .export, .cancel] {
            #expect(KeyboardShortcutContext.canRun(action, hasOverlay: false, hasNativeSheet: false,
                isEditingText: true, isModalContext: false))
        }
    }

    @Test func sheetsOnlyRunTheirOwnActionsAndNestedPanelsBlockDispatch() {
        #expect(!KeyboardShortcutContext.canRun(.run, hasOverlay: false, hasNativeSheet: true,
            isEditingText: false, isModalContext: false))
        #expect(KeyboardShortcutContext.canRun(.preview, hasOverlay: false, hasNativeSheet: true,
            isEditingText: false, isModalContext: true))
        #expect(!KeyboardShortcutContext.canRun(.run, hasOverlay: true, hasNativeSheet: true,
            isEditingText: false, isModalContext: true))
        #expect(!KeyboardShortcutContext.canRun(.save, hasOverlay: false, hasNativeSheet: true,
            isEditingText: false, isModalContext: true, hasBlockingNativePanel: true))
        for action in KeyboardAction.allCases {
            #expect(!KeyboardShortcutContext.canRun(action, hasOverlay: true, hasNativeSheet: false,
                isEditingText: false, isModalContext: false))
        }
    }
}
