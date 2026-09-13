import Foundation
import HarnessCore

/// How the agent runs shell commands. Implemented by HarnessTerminal's `CommandRunner`.
public protocol CommandExecutor: Sendable {
    func run(_ command: String, timeout: TimeInterval) async -> CommandResult
}

public struct CommandResult: Sendable {
    public let exitCode: Int32
    public let output: String
    public let timedOut: Bool
    public let duration: TimeInterval
    public init(exitCode: Int32, output: String, timedOut: Bool, duration: TimeInterval) {
        self.exitCode = exitCode; self.output = output; self.timedOut = timedOut; self.duration = duration
    }
}

/// PRD §6.3 RUN primitive. Output is shown in the terminal drawer and parsed for diagnostics.
struct RunCommandTool: Tool {
    let name = "run_command"
    let description = """
    Run a shell command in the project root through the user's login shell (zsh/bash). Use it to build, lint, \
    test, install packages, or inspect the environment. Output is captured (last 400 lines). Long-running \
    servers/watchers will be killed at the timeout — prefer one-shot commands (e.g. `npm test -- --run`).
    """
    let permission = PermissionClass.run
    var parameters: JSONValue {
        Schema.object([
            "command": Schema.string("The command line to run, e.g. `npm test`"),
            "timeout_seconds": Schema.integer("Kill after this many seconds (default 120, max 900)"),
            "purpose": Schema.string("Short label shown to the user, e.g. 'Run tests'"),
        ], required: ["command"])
    }

    let executor: any CommandExecutor

    func summary(for a: JSONValue) -> String {
        if let p = a.string("purpose"), !p.isEmpty { return "\(p): \(a.string("command") ?? "")" }
        return "Run \(a.string("command") ?? "")"
    }

    func subject(for a: JSONValue) -> String? { a.string("command") }

    func execute(_ a: JSONValue, context: ToolContext) async throws -> ToolOutput {
        let command = try a.requiredString("command")
        let timeout = TimeInterval(min(900, max(1, a.int("timeout_seconds") ?? 120)))
        let before = await context.captureTree()
        let result = await executor.run(command, timeout: timeout)
        let changedByCommand = await context.recordChanges(since: before, label: "run_command \(command)")

        let problems = DiagnosticsParser.parse(result.output, projectRoot: context.files.root)
        await context.sink.diagnosticsReported(problems, source: command)

        var text = "exit code: \(result.exitCode)"
        if result.timedOut { text += " (timed out after \(Int(timeout))s and was killed)" }
        text += " · \(String(format: "%.1f", result.duration))s\n"
        text += result.output.isEmpty ? "(no output)" : result.output
        if !problems.isEmpty { text += "\n\n\(problems.count) diagnostic(s) parsed and shown in Problems." }
        if !changedByCommand.isEmpty {
            let listed = changedByCommand.prefix(20).joined(separator: ", ")
            text += "\n\nFiles changed by this command (\(changedByCommand.count)): \(listed)\(changedByCommand.count > 20 ? ", …" : "")"
        }

        let ok = result.exitCode == 0 && !result.timedOut
        let title = "\(summary(for: a))" + (ok ? "" : result.timedOut ? " — timed out" : " — exit \(result.exitCode)")
        let detailLines = result.output.split(separator: "\n").suffix(15).joined(separator: "\n")
        return ToolOutput(text, activity: ActivityRecord(kind: .run, title: title, detail: detailLines.isEmpty ? nil : detailLines, succeeded: ok))
    }
}
