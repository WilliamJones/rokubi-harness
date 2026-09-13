import Foundation
import Testing
@testable import HarnessAgent
@testable import HarnessCore

/// Undo Task must reverse what `run_command` and folder renames change on disk.
@Suite struct CommandUndoToolTests {
    private func makeContext() throws -> (ToolContext, URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("cmdundo-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root.appendingPathComponent("src"), withIntermediateDirectories: true)
        try "A1".write(to: root.appendingPathComponent("src/a.txt"), atomically: true, encoding: .utf8)
        try "B1".write(to: root.appendingPathComponent("src/b.txt"), atomically: true, encoding: .utf8)
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("cmdundo-store-\(UUID().uuidString)")
        let checkpoints = CheckpointStore(projectRoot: root, baseDirectory: base)
        let context = ToolContext(files: FileService(root: root), ignore: IgnoreRules(patterns: IgnoreRules.searchDefaults),
                                  checkpoints: checkpoints, conversationID: "c", taskID: "t")
        return (context, root)
    }

    struct FakeExecutor: CommandExecutor {
        let effect: @Sendable () -> Void
        func run(_ command: String, timeout: TimeInterval) async -> CommandResult {
            effect()
            return CommandResult(exitCode: 0, output: "ok", timedOut: false, duration: 0.1)
        }
    }

    @Test func undoTaskReversesWhatACommandChanged() async throws {
        let (context, root) = try makeContext()
        let a = root.appendingPathComponent("src/a.txt"), b = root.appendingPathComponent("src/b.txt")
        let made = root.appendingPathComponent("generated/out.txt")
        let tool = RunCommandTool(executor: FakeExecutor {
            try? "A2 from the command".write(to: a, atomically: true, encoding: .utf8)
            try? FileManager.default.removeItem(at: b)
            try? FileManager.default.createDirectory(at: made.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? "generated".write(to: made, atomically: true, encoding: .utf8)
        })

        let output = try await tool.execute(.object(["command": .string("npm run codegen")]), context: context)
        #expect(output.modelText.contains("Files changed by this command (3): generated/out.txt, src/a.txt, src/b.txt"))
        #expect(Set(await context.checkpoints?.changedPaths(taskID: "t") ?? []) == ["generated/out.txt", "src/a.txt", "src/b.txt"])

        try await context.checkpoints?.restoreTaskStart(taskID: "t")
        #expect(try String(contentsOf: a, encoding: .utf8) == "A1")
        #expect(try String(contentsOf: b, encoding: .utf8) == "B1")
        #expect(!FileManager.default.fileExists(atPath: made.path))
        #expect(!FileManager.default.fileExists(atPath: made.deletingLastPathComponent().path))
    }

    @Test func aCommandThatChangesNothingRecordsNothing() async throws {
        let (context, _) = try makeContext()
        let output = try await RunCommandTool(executor: FakeExecutor {}).execute(.object(["command": .string("npm test")]), context: context)
        #expect(!output.modelText.contains("Files changed by this command"))
        #expect(await context.checkpoints?.changedPaths(taskID: "t") == [])
    }

    @Test func undoTaskReversesAFolderRename() async throws {
        let (context, root) = try makeContext()
        _ = try await RenamePathTool().execute(.object(["from": .string("src"), "to": .string("lib")]), context: context)
        #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent("lib/a.txt").path))

        try await context.checkpoints?.restoreTaskStart(taskID: "t")
        #expect(try String(contentsOf: root.appendingPathComponent("src/a.txt"), encoding: .utf8) == "A1")
        #expect(try String(contentsOf: root.appendingPathComponent("src/b.txt"), encoding: .utf8) == "B1")
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("lib").path))
    }
}

/// A mistake in `.rokubi/permissions.json` must skip only that rule, and say why.
@Suite struct PermissionFileReportTests {
    private func load(_ json: String?) throws -> ProjectRulesLoad {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("rules-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root.appendingPathComponent(".rokubi"), withIntermediateDirectories: true)
        if let json { try json.write(to: root.appendingPathComponent(".rokubi/permissions.json"), atomically: true, encoding: .utf8) }
        return PermissionPolicy.loadProjectRulesReport(root: root)
    }

    @Test func aTypoSkipsOnlyThatRuleAndSaysWhy() throws {
        let report = try load(#"[{"class":"run","match":"npm test*","decision":"allow"},{"class":"Run","match":"npm run lint*","decision":"allow"}]"#)
        #expect(report.rules.count == 1)
        #expect(report.warnings.count == 1)
        #expect(report.warnings.first?.contains(#"Rule 2 has unknown class "Run""#) == true)
        #expect(PermissionPolicy(preset: .standard, project: report.rules).evaluate(.run, subject: "npm test").0 == .allow)
    }

    @Test func aMisspelledMatchKeyIsSkippedRatherThanWidened() throws {
        let report = try load(#"[{"class":"run","matches":"npm test*","decision":"deny"}]"#)
        #expect(report.rules.isEmpty)
        #expect(report.warnings.first?.contains(#"unknown key "matches""#) == true)
    }

    @Test func badDecisionsWrongTypesAndNonObjectsAreReported() throws {
        let report = try load(#"[{"class":"run","match":"x*","decision":"always"},{"class":"edit","match":5,"decision":"deny"},"nope",{"decision":"deny"}]"#)
        #expect(report.rules.isEmpty)
        #expect(report.warnings.count == 4)
        #expect(report.warnings[0].contains(#"unknown decision "always""#))
        #expect(report.warnings[1].contains("isn't text"))
        #expect(report.warnings[2].contains("isn't an object"))
        #expect(report.warnings[3].contains(#"needs a "class""#))
    }

    @Test func invalidJSONAppliesNoRulesAndSaysSo() throws {
        let report = try load("[{")
        #expect(report.rules.isEmpty)
        #expect(report.warnings == ["The file isn't valid JSON, so no project rules apply."])
    }

    @Test func aBlanketAllowIsSkippedWithAWarning() throws {
        let report = try load(#"[{"class":"run","decision":"allow"},{"class":"read","decision":"allow"}]"#)
        #expect(report.rules.count == 1)
        #expect(report.warnings.first?.contains("skipped for safety") == true)
    }

    @Test func aValidFileOrNoFileHasNoWarnings() throws {
        let valid = try load(#"[{"class":"run","match":"npm test*","decision":"allow"},{"class":"delete","decision":"ask"}]"#)
        #expect(valid.rules.count == 2)
        #expect(valid.warnings.isEmpty)
        #expect(valid.summary.isEmpty)
        let missing = try load(nil)
        #expect(missing.rules.isEmpty && missing.warnings.isEmpty)
    }

    @Test func theSummaryNamesTheFileAndCapsTheList() throws {
        let report = try load(#"[{"class":"a","decision":"deny"},{"class":"b","decision":"deny"},{"class":"c","decision":"deny"},{"class":"d","decision":"deny"},{"class":"e","decision":"deny"}]"#)
        #expect(report.summary.hasPrefix(".rokubi/permissions.json: Rule 1"))
        #expect(report.summary.hasSuffix("(+2 more)"))
    }
}
