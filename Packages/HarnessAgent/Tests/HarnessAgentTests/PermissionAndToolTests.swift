import Foundation
import Testing
@testable import HarnessAgent
@testable import HarnessCore

@Suite struct PermissionPolicyTests {
    @Test func presetMatrix() {
        typealias D = PermissionRule.Decision
        let expectations: [(AutonomyPreset, PermissionClass, D)] = [
            (.readOnly, .read, .allow), (.readOnly, .edit, .deny), (.readOnly, .run, .deny),
            (.standard, .edit, .allow), (.standard, .delete, .ask), (.standard, .run, .ask), (.standard, .gitWrite, .ask),
            (.askBeforeCommands, .delete, .allow), (.askBeforeCommands, .run, .ask),
            (.fullAutonomy, .run, .allow), (.fullAutonomy, .packageInstall, .allow),
        ]
        for (preset, cls, expected) in expectations {
            let (d, _) = PermissionPolicy(preset: preset).evaluate(cls, subject: "x")
            #expect(d == expected, "\(preset) \(cls)")
        }
    }

    @Test func hardDeniesBeatFullAutonomy() {
        let policy = PermissionPolicy(preset: .fullAutonomy)
        #expect(policy.evaluate(.run, subject: "git push --force origin main").0 == .deny)
        #expect(policy.evaluate(.run, subject: "sudo rm -rf /").0 == .deny)
        #expect(policy.evaluate(.run, subject: "npm test").0 == .allow)
    }

    @Test func layeredRulesWinOverPreset() {
        var policy = PermissionPolicy(preset: .standard)
        policy.project = [PermissionRule(.run, match: "npm test*", .allow)]
        policy.global = [PermissionRule(.run, match: "npm *", .deny)]
        #expect(policy.evaluate(.run, subject: "npm test -- --watch").0 == .allow)   // project beats global
        #expect(policy.evaluate(.run, subject: "npm install x").0 == .deny)          // global rule
        #expect(policy.evaluate(.run, subject: "swift build").0 == .ask)             // preset default
        policy.session = [PermissionRule(.run, match: "swift*", .allow)]
        #expect(policy.evaluate(.run, subject: "swift build").0 == .allow)
    }

    @Test func engineAsksAndRemembers() async {
        actor Counter { var n = 0; func bump() { n += 1 } }
        let counter = Counter()
        let engine = PermissionEngine(policy: PermissionPolicy(preset: .standard)) { _ in
            await counter.bump()
            return .allowForSession
        }
        let tool = FakeRunTool()
        let first = await engine.decide(tool: tool, arguments: .object(["command": .string("npm test")]), summary: "npm test")
        let second = await engine.decide(tool: tool, arguments: .object(["command": .string("npm run build")]), summary: "npm run build")
        #expect(first == .allow && second == .allow)
        #expect(await counter.n == 1)
    }

    struct FakeRunTool: Tool {
        let name = "run_command"; let description = ""; let permission = PermissionClass.run
        var parameters: JSONValue { .object([:]) }
        func summary(for a: JSONValue) -> String { a.string("command") ?? "" }
        func subject(for a: JSONValue) -> String? { a.string("command") }
        func execute(_ a: JSONValue, context: ToolContext) async throws -> ToolOutput { ToolOutput("", activity: .init(kind: .run, title: "")) }
    }
}

@Suite struct FileToolTests {
    private func makeContext() throws -> (ToolContext, URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("tools-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root.appendingPathComponent("src"), withIntermediateDirectories: true)
        try "line1\nline2\nline3\n".write(to: root.appendingPathComponent("src/a.txt"), atomically: true, encoding: .utf8)
        try "SECRET".write(to: root.appendingPathComponent(".env"), atomically: true, encoding: .utf8)
        let checkpoints = CheckpointStore(projectRoot: root, baseDirectory: root.appendingPathComponent(".cp"))
        let ctx = ToolContext(files: FileService(root: root), ignore: IgnoreRules(patterns: IgnoreRules.searchDefaults),
                              checkpoints: checkpoints, conversationID: "c", taskID: "t")
        return (ctx, root)
    }

    @Test func readFileNumbersLinesAndBlocksSecrets() async throws {
        let (ctx, _) = try makeContext()
        let out = try await ReadFileTool().execute(.object(["path": .string("src/a.txt")]), context: ctx)
        #expect(out.modelText == "1\tline1\n2\tline2\n3\tline3\n4\t\n")
        await #expect(throws: (any Error).self) {
            try await ReadFileTool().execute(.object(["path": .string(".env")]), context: ctx)
        }
        await #expect(throws: (any Error).self) {
            try await ReadFileTool().execute(.object(["path": .string("../outside")]), context: ctx)
        }
    }

    @Test func applyPatchCheckpointsBeforeWriting() async throws {
        let (ctx, root) = try makeContext()
        let args: JSONValue = .object([
            "path": .string("src/a.txt"),
            "edits": .array([.object(["old": .string("line2"), "new": .string("LINE2")])]),
        ])
        let out = try await ApplyPatchTool().execute(args, context: ctx)
        #expect(out.activity.kind == .edit)
        #expect(try String(contentsOf: root.appendingPathComponent("src/a.txt"), encoding: .utf8) == "line1\nLINE2\nline3\n")
        #expect(await ctx.checkpoints?.original(of: root.appendingPathComponent("src/a.txt"), taskID: "t") == "line1\nline2\nline3\n")
        try await ctx.checkpoints?.restoreTaskStart(taskID: "t")
        #expect(try String(contentsOf: root.appendingPathComponent("src/a.txt"), encoding: .utf8) == "line1\nline2\nline3\n")
    }

    @Test func toolDefinitionsAreValidSchemas() {
        let defs = ToolFactory.defaultTools().definitions
        #expect(defs.count == 11)
        for d in defs {
            #expect(d.parameters["type"]?.stringValue == "object", Comment(rawValue: d.name))
            #expect(d.parameters["properties"] != nil, Comment(rawValue: d.name))
        }
    }
}
