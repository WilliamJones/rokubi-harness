import Foundation
import Testing
@testable import HarnessCore

@Suite struct PatchApplierTests {
    @Test func exactReplace() throws {
        let r = try PatchApplier.apply([.init(old: "let a = 1", new: "let a = 2")], to: "let a = 1\nlet b = 2\n")
        #expect(r.text == "let a = 2\nlet b = 2\n")
        #expect(r.fuzzyEdits == 0)
    }

    @Test func ambiguousIsRejected() {
        #expect(throws: PatchApplier.Failure.ambiguous(index: 0, count: 2)) {
            try PatchApplier.apply([.init(old: "x", new: "y")], to: "x\nx\n")
        }
    }

    @Test func fuzzyTrailingWhitespace() throws {
        let file = "func a() {  \n    return 1\n}\n"
        let r = try PatchApplier.apply([.init(old: "func a() {\n    return 1\n}", new: "func a() {\n    return 2\n}")], to: file)
        #expect(r.text == "func a() {\n    return 2\n}\n")
        #expect(r.fuzzyEdits == 1)
    }

    @Test func fuzzyIndentationIsReapplied() throws {
        let file = "class C {\n        func a() {\n            return 1\n        }\n}\n"
        let edit = PatchApplier.Edit(old: "func a() {\n    return 1\n}", new: "func a() {\n    return 2\n}")
        let r = try PatchApplier.apply([edit], to: file)
        #expect(r.text == "class C {\n        func a() {\n            return 2\n        }\n}\n")
    }

    @Test func notFoundReportsSnippet() {
        #expect(throws: PatchApplier.Failure.self) {
            try PatchApplier.apply([.init(old: "missing", new: "x")], to: "abc")
        }
    }
}

@Suite struct CheckpointStoreTests {
    private func makeRoot() throws -> (URL, URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("cp-\(UUID().uuidString)")
        let store = FileManager.default.temporaryDirectory.appendingPathComponent("cpstore-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return (root, store)
    }

    @Test func restoreTaskStartRevertsEditsCreationsAndDeletions() async throws {
        let (root, base) = try makeRoot()
        let a = root.appendingPathComponent("a.txt"), b = root.appendingPathComponent("b.txt"), c = root.appendingPathComponent("c.txt")
        try "A1".write(to: a, atomically: true, encoding: .utf8)
        try "B1".write(to: b, atomically: true, encoding: .utf8)
        let store = CheckpointStore(projectRoot: root, baseDirectory: base)

        try await store.snapshot(a, taskID: "t1"); try "A2".write(to: a, atomically: true, encoding: .utf8)
        try await store.snapshot(a, taskID: "t1"); try "A3".write(to: a, atomically: true, encoding: .utf8)
        try await store.snapshot(b, taskID: "t1"); try FileManager.default.removeItem(at: b)
        try await store.snapshot(c, taskID: "t1"); try "C1".write(to: c, atomically: true, encoding: .utf8)

        #expect(await store.changedPaths(taskID: "t1") == ["a.txt", "b.txt", "c.txt"])
        #expect(await store.original(of: a, taskID: "t1") == "A1")
        #expect(await store.original(of: c, taskID: "t1") == nil)

        let undone = try await store.undoLastAction(taskID: "t1")
        #expect(undone == "c.txt")
        #expect(!FileManager.default.fileExists(atPath: c.path))

        try await store.restoreTaskStart(taskID: "t1")
        #expect(try String(contentsOf: a, encoding: .utf8) == "A1")
        #expect(try String(contentsOf: b, encoding: .utf8) == "B1")
    }

    @Test func manifestsSurviveReload() async throws {
        let (root, base) = try makeRoot()
        let a = root.appendingPathComponent("a.txt")
        try "A1".write(to: a, atomically: true, encoding: .utf8)
        do {
            let store = CheckpointStore(projectRoot: root, baseDirectory: base)
            try await store.snapshot(a, taskID: "t2")
        }
        let reloaded = CheckpointStore(projectRoot: root, baseDirectory: base)
        #expect(await reloaded.original(of: a, taskID: "t2") == "A1")
    }
}

@Suite struct SearchServiceTests {
    @Test func globAndGrepHonorIgnoreRules() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("search-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root.appendingPathComponent("src/nested"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("node_modules/x"), withIntermediateDirectories: true)
        try "export const token = 1\n".write(to: root.appendingPathComponent("src/a.ts"), atomically: true, encoding: .utf8)
        try "const TOKEN = 2\n".write(to: root.appendingPathComponent("src/nested/b.ts"), atomically: true, encoding: .utf8)
        try "token".write(to: root.appendingPathComponent("node_modules/x/c.ts"), atomically: true, encoding: .utf8)
        try "SECRET=token".write(to: root.appendingPathComponent(".env"), atomically: true, encoding: .utf8)

        let fs = FileService(root: root)
        let search = SearchService(files: fs, ignore: IgnoreRules(patterns: IgnoreRules.searchDefaults))
        #expect(Set(search.glob("*.ts")) == ["src/a.ts", "src/nested/b.ts"])
        #expect(search.glob("src/**/*.ts").count == 2)
        #expect(search.glob("src/*.ts") == ["src/a.ts"])

        let r = search.grep("token")
        #expect(r.matches.map(\.path).sorted() == ["src/a.ts", "src/nested/b.ts"])
        #expect(search.grep("token", caseSensitive: true).matches.count == 1)
        #expect(search.grep("token", pathGlob: "**/nested/*").matches.map(\.path) == ["src/nested/b.ts"])
        #expect(search.grep("token", pathGlob: "nested/*").matches.isEmpty)   // slash patterns anchor to the root
    }
}
