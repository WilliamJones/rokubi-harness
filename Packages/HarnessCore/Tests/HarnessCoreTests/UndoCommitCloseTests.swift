import Foundation
import Testing
@testable import HarnessCore

private func tempDirectory(_ prefix: String) throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(prefix)-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

private func write(_ text: String, _ url: URL) throws {
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try text.write(to: url, atomically: true, encoding: .utf8)
}

/// Undo Task must also reverse what a command (or a folder move) changed on disk.
@Suite struct TreeCaptureTests {
    private let ignore = IgnoreRules(patterns: IgnoreRules.searchDefaults)

    @Test func restoresEditedDeletedAndCreatedFiles() async throws {
        let root = try tempDirectory("tree"), base = try tempDirectory("tree-store")
        let a = root.appendingPathComponent("src/a.txt"), b = root.appendingPathComponent("src/b.txt")
        let made = root.appendingPathComponent("generated/out/c.txt")
        try write("A1", a); try write("B1", b)
        let store = CheckpointStore(projectRoot: root, baseDirectory: base)

        let before = await store.captureTree(ignore: ignore)
        try write("A2 changed by a command", a)
        try FileManager.default.removeItem(at: b)
        try write("C1", made)
        let changed = await store.recordChanges(since: before, ignore: ignore, taskID: "t", label: "run_command gen")
        #expect(changed == ["generated/out/c.txt", "src/a.txt", "src/b.txt"])

        try await store.restoreTaskStart(taskID: "t")
        #expect(try String(contentsOf: a, encoding: .utf8) == "A1")
        #expect(try String(contentsOf: b, encoding: .utf8) == "B1")
        #expect(!FileManager.default.fileExists(atPath: made.path))
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("generated").path))
    }

    @Test func ignoredFoldersAndUnchangedFilesAreNotRecorded() async throws {
        let root = try tempDirectory("tree"), base = try tempDirectory("tree-store")
        try write("A1", root.appendingPathComponent("src/a.txt"))
        try write("N1", root.appendingPathComponent("node_modules/pkg/index.js"))
        let store = CheckpointStore(projectRoot: root, baseDirectory: base)

        let before = await store.captureTree(ignore: ignore)
        try write("N2 from npm install", root.appendingPathComponent("node_modules/pkg/index.js"))
        let changed = await store.recordChanges(since: before, ignore: ignore, taskID: "t", label: "npm install")
        #expect(changed.isEmpty)
    }

    @Test func aFileTheTaskAlreadyTouchedKeepsItsOriginal() async throws {
        let root = try tempDirectory("tree"), base = try tempDirectory("tree-store")
        let a = root.appendingPathComponent("a.txt")
        try write("A1", a)
        let store = CheckpointStore(projectRoot: root, baseDirectory: base)
        try await store.snapshot(a, taskID: "t", label: "apply_patch a.txt")
        try write("A2 from the agent's edit", a)

        let before = await store.captureTree(ignore: ignore)
        try write("A3 from a formatter run afterwards", a)
        #expect(await store.recordChanges(since: before, ignore: ignore, taskID: "t", label: "run_command fmt") == ["a.txt"])

        try await store.restoreTaskStart(taskID: "t")
        #expect(try String(contentsOf: a, encoding: .utf8) == "A1")
    }

    @Test func oversizedFilesAreSkippedAndNeverReportedAsNew() async throws {
        let root = try tempDirectory("tree"), base = try tempDirectory("tree-store")
        try Data(count: CheckpointStore.maxCapturedFileBytes + 1).write(to: root.appendingPathComponent("big.bin"))
        let store = CheckpointStore(projectRoot: root, baseDirectory: base)
        let before = await store.captureTree(ignore: ignore)
        #expect(before.uncaptured.contains("big.bin"))
        #expect(await store.recordChanges(since: before, ignore: ignore, taskID: "t", label: nil).isEmpty)
    }
}

/// Commit must include only the task's files and leave the user's other changes alone.
@Suite struct GitCommitPathsTests {
    @Test func commitsOnlyTheGivenPathsAndLeavesOtherChangesAlone() throws {
        let root = try tempDirectory("gitpaths")
        let git = GitService(root: root)
        try git.initRepository()
        _ = try git.run(["config", "user.email", "t@example.com"])
        _ = try git.run(["config", "user.name", "Test"])
        try write("K1", root.appendingPathComponent("keep.txt"))
        try write("M1", root.appendingPathComponent("mod.txt"))
        try write("D1", root.appendingPathComponent("del.txt"))
        try git.stageAll()
        try git.commit(message: "init")

        // The user's own change, already staged before the task.
        try write("K2", root.appendingPathComponent("keep.txt"))
        try git.stage(["keep.txt"])
        // The agent's task.
        try write("M2", root.appendingPathComponent("mod.txt"))
        try FileManager.default.removeItem(at: root.appendingPathComponent("del.txt"))
        try write("N1", root.appendingPathComponent("new/dir/new.txt"))

        #expect(try git.status(allUntrackedFiles: true).contains { $0.path == "new/dir/new.txt" })
        try git.commit(message: "Agent task", paths: ["mod.txt", "del.txt", "new/dir/new.txt"])

        let committed = try git.run(["show", "--name-status", "--format=", "HEAD"]).output
        #expect(committed.contains("M\tmod.txt"))
        #expect(committed.contains("D\tdel.txt"))
        #expect(committed.contains("A\tnew/dir/new.txt"))
        #expect(!committed.contains("keep.txt"))
        #expect(try git.run(["diff", "--cached", "--name-only"]).output.contains("keep.txt"))
    }
}

/// Closing a tab with unsaved edits must ask, and each answer must do what it says.
@MainActor
@Suite struct WorkspaceCloseTests {
    private func makeWorkspace() throws -> (ProjectWorkspace, URL) {
        let root = try tempDirectory("close")
        let file = root.appendingPathComponent("notes.txt")
        try write("saved", file)
        return (ProjectWorkspace(ref: ProjectRef(url: root)), file)
    }

    @Test func aTabWithoutEditsClosesRightAway() throws {
        let (workspace, file) = try makeWorkspace()
        let doc = try #require(workspace.open(file))
        workspace.requestClose(doc.id)
        #expect(workspace.documents.isEmpty)
        #expect(workspace.closeRequest == nil)
    }

    @Test func unsavedEditsAskFirstAndCancelKeepsTheTab() throws {
        let (workspace, file) = try makeWorkspace()
        let doc = try #require(workspace.open(file))
        doc.text = "edited"
        workspace.requestClose(doc.id)
        #expect(workspace.closeRequest == doc.id)
        #expect(workspace.documents.count == 1)
        workspace.resolveClose(.cancel)
        #expect(workspace.closeRequest == nil)
        #expect(workspace.documents.first?.text == "edited")
    }

    @Test func saveWritesTheFileThenCloses() throws {
        let (workspace, file) = try makeWorkspace()
        let doc = try #require(workspace.open(file))
        doc.text = "edited"
        workspace.requestClose(doc.id)
        workspace.resolveClose(.save)
        #expect(try String(contentsOf: file, encoding: .utf8) == "edited")
        #expect(workspace.documents.isEmpty)
    }

    @Test func dontSaveClosesWithoutWriting() throws {
        let (workspace, file) = try makeWorkspace()
        let doc = try #require(workspace.open(file))
        doc.text = "edited"
        workspace.requestClose(doc.id)
        workspace.resolveClose(.discard)
        #expect(try String(contentsOf: file, encoding: .utf8) == "saved")
        #expect(workspace.documents.isEmpty)
    }
}
