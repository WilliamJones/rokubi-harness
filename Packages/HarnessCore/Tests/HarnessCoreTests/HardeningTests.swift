import Foundation
import Testing
@testable import HarnessCore

/// Regression tests for the sandbox/secrets boundary, CRLF handling and git status parsing.
@Suite struct HardeningTests {
    private func makeTempRoot() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("harness-hardening-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url.appendingPathComponent("src"), withIntermediateDirectories: true)
        return url
    }

    @Test func symlinkPointingOutsideTheProjectIsNotContained() throws {
        let root = try makeTempRoot()
        let outside = FileManager.default.temporaryDirectory.appendingPathComponent("outside-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        try "leak".write(to: outside.appendingPathComponent("secret.txt"), atomically: true, encoding: .utf8)
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("src/escape"), withDestinationURL: outside)

        let fs = FileService(root: root)
        #expect(!fs.contains(root.appendingPathComponent("src/escape/secret.txt")))
        #expect(throws: FileServiceError.self) { try fs.resolve("src/escape/secret.txt") }
        #expect(throws: FileServiceError.self) { try fs.readText(root.appendingPathComponent("src/escape/secret.txt")) }
        // Real files (existing and not-yet-existing) are still fine.
        #expect(fs.contains(root.appendingPathComponent("src/new/file.txt")))
        #expect(try fs.resolve("src/a.txt").lastPathComponent == "a.txt")
    }

    @Test func symlinkToASecretIsProtected() throws {
        let root = try makeTempRoot()
        let fs = FileService(root: root)
        try fs.writeText("TOKEN=1", to: root.appendingPathComponent(".env"))
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("notsecret.txt"),
                                                   withDestinationURL: root.appendingPathComponent(".env"))
        #expect(fs.isProtected(root.appendingPathComponent("notsecret.txt")))
        #expect(throws: FileServiceError.self) { try fs.readTextForAgent(root.appendingPathComponent("notsecret.txt")) }
        #expect(!fs.isProtected(root.appendingPathComponent("src/a.txt")))
    }

    @Test func rootUnderASymlinkStillContainsItsFiles() throws {
        // /tmp → /private/tmp on macOS; a project opened via the link must work.
        let root = try makeTempRoot()
        let link = FileManager.default.temporaryDirectory.appendingPathComponent("link-\(UUID().uuidString)")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: root)
        let fs = FileService(root: link)
        #expect(fs.contains(link.appendingPathComponent("src/a.txt")))
        #expect(fs.contains(root.appendingPathComponent("src/a.txt")))
    }

    @Test func patchApplierHandlesCRLFFiles() throws {
        let file = "line1\r\nline2\r\nline3\r\n"
        let r = try PatchApplier.apply([.init(old: "line2", new: "LINE2")], to: file)
        #expect(r.text == "line1\r\nLINE2\r\nline3\r\n")
        // Multi-line `old` written with LF by the model still matches a CRLF file.
        let r2 = try PatchApplier.apply([.init(old: "line1\nline2", new: "one\ntwo")], to: file)
        #expect(r2.text == "one\r\ntwo\r\nline3\r\n")
        // Fuzzy (trailing whitespace) path too.
        let r3 = try PatchApplier.apply([.init(old: "line2\nline3", new: "x")], to: "line1\r\nline2  \r\nline3\r\n")
        #expect(r3.text == "line1\r\nx\r\n" && r3.fuzzyEdits == 1)
    }

    @Test func lineSplittingToleratesCRLF() {
        #expect(FileService.lines(of: "a\r\nb\r\nc") == ["a", "b", "c"])
        #expect(FileService.lines(of: "a\nb\n") == ["a", "b", ""])
        #expect(FileService.lines(of: "") == [""])
    }

    @Test func grepReportsCorrectLineNumbersInCRLFFiles() throws {
        let root = try makeTempRoot()
        try "alpha\r\nbeta\r\ngamma\r\n".write(to: root.appendingPathComponent("src/w.txt"), atomically: true, encoding: .utf8)
        let search = SearchService(files: FileService(root: root), ignore: IgnoreRules(patterns: []))
        let hits = search.grep("gamma", isRegex: false).matches
        #expect(hits.count == 1 && hits.first?.line == 3 && hits.first?.text == "gamma")
    }

    @Test func gitStatusParsesRenames() throws {
        let root = try makeTempRoot()
        let git = GitService(root: root)
        try git.initRepository()
        _ = try git.run(["config", "user.email", "t@example.com"])
        _ = try git.run(["config", "user.name", "Test"])
        try "hello\n".write(to: root.appendingPathComponent("old.txt"), atomically: true, encoding: .utf8)
        try git.stageAll()
        try git.commit(message: "init")
        _ = try git.run(["mv", "old.txt", "new.txt"])
        try "extra\n".write(to: root.appendingPathComponent("src/m.txt"), atomically: true, encoding: .utf8)

        let status = try git.status()
        #expect(status.contains { $0.path == "new.txt" && $0.state == .renamed && $0.staged })
        #expect(!status.contains { $0.path == "old.txt" || $0.path == ".txt" })   // the -z "old" field must be skipped
        #expect(status.contains { $0.path.hasPrefix("src") && $0.state == .untracked })   // git reports the untracked dir
    }
}
