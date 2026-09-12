import Foundation
import Testing
@testable import HarnessCore

@Suite struct FileServiceTests {
    private func makeTempRoot() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("harness-core-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test func rejectsPathsOutsideRoot() throws {
        let root = try makeTempRoot()
        let fs = FileService(root: root)
        #expect(throws: FileServiceError.self) { try fs.resolve("../escape.txt") }
        #expect(throws: FileServiceError.self) { try fs.resolve("/etc/passwd") }
        #expect(try fs.resolve("src/a.swift").path == root.appendingPathComponent("src/a.swift").path)
    }

    @Test func protectedFilesAreBlockedForAgentOnly() throws {
        let root = try makeTempRoot()
        let fs = FileService(root: root)
        let env = root.appendingPathComponent(".env")
        try fs.writeText("SECRET=1", to: env)
        #expect(try fs.readText(env) == "SECRET=1")
        #expect(throws: FileServiceError.self) { try fs.readTextForAgent(env) }
        #expect(fs.isProtected(root.appendingPathComponent("server.key")))
        #expect(fs.isProtected(root.appendingPathComponent(".env.local")))
        #expect(!fs.isProtected(root.appendingPathComponent("env.ts")))
    }

    @Test func duplicatePicksNextFreeName() throws {
        let root = try makeTempRoot()
        let fs = FileService(root: root)
        let file = root.appendingPathComponent("notes.md")
        try fs.writeText("hi", to: file)
        let first = try fs.duplicate(file)
        let second = try fs.duplicate(file)
        #expect(first.lastPathComponent == "notes copy.md")
        #expect(second.lastPathComponent == "notes copy 2.md")
    }

    @Test func relativePathStripsRoot() throws {
        let root = try makeTempRoot()
        let fs = FileService(root: root)
        #expect(fs.relativePath(root.appendingPathComponent("a/b.txt")) == "a/b.txt")
    }
}
