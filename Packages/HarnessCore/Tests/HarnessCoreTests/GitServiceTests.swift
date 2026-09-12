import Foundation
import Testing
@testable import HarnessCore

@Suite struct GitServiceTests {
    private func makeRepo() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("git-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let git = GitService(root: root)
        _ = try git.run(["init", "-q"])
        _ = try git.run(["config", "user.email", "t@example.com"])
        _ = try git.run(["config", "user.name", "Test"])
        return root
    }

    @Test func statusReflectsUntrackedStagedAndCommitted() throws {
        let root = try makeRepo()
        let git = GitService(root: root)
        #expect(git.isRepository)
        try "one\n".write(to: root.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
        let untracked = try git.status()
        #expect(untracked.contains { $0.path == "a.txt" && $0.state == .untracked })

        try git.stageAll()
        #expect(try git.status().contains { $0.path == "a.txt" && $0.staged && $0.state == .added })

        _ = try git.commit(message: "first")
        #expect(try git.status().isEmpty)
        #expect(try git.log().first?.subject == "first")

        try "two\n".write(to: root.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
        #expect(try git.status().contains { $0.path == "a.txt" && !$0.staged && $0.state == .modified })
        #expect(try git.diff(path: "a.txt").contains("+two"))
    }

    @Test func nonRepositoryReportsFalse() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("nogit-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        #expect(!GitService(root: root).isRepository)
    }
}
