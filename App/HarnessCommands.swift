import HarnessCore
import HarnessUI
import SwiftUI

/// App menu: the few commands that deserve a permanent home. Everything else goes through ⌘K.
struct HarnessCommands: Commands {
    @Environment(\.openWindow) private var openWindow
    @FocusedValue(\.workspace) private var workspace
    @FocusedValue(\.editor) private var editor
    @State private var recents = RecentProjects.shared

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("Open Folder…") {
                if let url = ProjectPicker.chooseFolder() { open(ProjectRef(url: url)) }
            }
            .keyboardShortcut("o")

            Menu("Open Recent") {
                ForEach(recents.projects) { ref in
                    Button(ref.name) { open(ref) }
                }
                if !recents.projects.isEmpty {
                    Divider()
                    Button("Clear Menu") { recents.clear() }
                }
            }
        }

        CommandGroup(replacing: .saveItem) {
            Button("Save") {
                if let ws = workspace, let id = ws.activeDocumentID { ws.save(id) }
            }
            .keyboardShortcut("s")
            .disabled(workspace?.activeDocument == nil)

            Button("Save All") { workspace?.saveAll() }
                .keyboardShortcut("s", modifiers: [.command, .option])
                .disabled(workspace?.hasUnsavedChanges != true)

            Button("Close Editor") {
                if let ws = workspace, let id = ws.activeDocumentID { ws.close(id) }
            }
            .keyboardShortcut("w")
            .disabled(workspace?.activeDocument == nil)
        }

        CommandMenu("View") {
            Button("Command Palette…") { NotificationCenter.default.post(name: .harnessTogglePalette, object: nil) }
                .keyboardShortcut("k")
            Button("New Terminal") { editor?.workspace.requestTerminal() }
                .keyboardShortcut("`", modifiers: .control)
        }

        CommandMenu("Editor") {
            Button("Find…") { editor?.runAction("actions.find") }.keyboardShortcut("f")
            Button("Find and Replace…") { editor?.runAction("editor.action.startFindReplaceAction") }
                .keyboardShortcut("f", modifiers: [.command, .option])
            Button("Go to Line…") { editor?.runAction("editor.action.gotoLine") }
                .keyboardShortcut("l", modifiers: [.command])
            Divider()
            Button("Format Document") { editor?.runAction("editor.action.formatDocument") }
                .keyboardShortcut("f", modifiers: [.command, .shift, .option])
            Button("Toggle Line Comment") { editor?.runAction("editor.action.commentLine") }
                .keyboardShortcut("/")
            Button("Command Palette (Editor)") { editor?.runAction("editor.action.quickCommand") }
                .keyboardShortcut("p", modifiers: [.command, .shift])
        }
    }

    private func open(_ ref: ProjectRef) {
        recents.touch(ref)
        openWindow(value: ref)
    }
}
