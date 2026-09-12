import Foundation
import Testing
@testable import HarnessAgent
@testable import HarnessCore
@testable import HarnessUI

@Suite @MainActor struct EditorCoordinatorTests {
    private func makeWorkspace() throws -> ProjectWorkspace {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("harness-ui-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try "let a = 1\n".write(to: root.appendingPathComponent("a.swift"), atomically: true, encoding: .utf8)
        return ProjectWorkspace(ref: ProjectRef(url: root))
    }

    @Test func syncKeyChangesWhenDocumentsChange() throws {
        let ws = try makeWorkspace()
        let editor = EditorCoordinator(workspace: ws)
        let before = editor.syncKey
        ws.open(ws.root.appendingPathComponent("a.swift"))
        #expect(editor.syncKey != before)
        ws.activeDocument?.reload(text: "let a = 2\n")
        let afterReload = editor.syncKey
        #expect(afterReload != before)
    }

    @Test func autonomyPresetsHaveTitles() {
        #expect(AutonomyPreset.allCases.count == 4)
        #expect(AutonomyPreset.standard.title == "Standard")
    }
}
