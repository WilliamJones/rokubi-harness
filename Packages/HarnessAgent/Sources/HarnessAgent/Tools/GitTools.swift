import Foundation
import HarnessCore

/// Read-only git status/diff/log for the agent (PRD §14 FR-007). Staging/commit stay a
/// human action in the MVP, surfaced through the completion card.
struct GitStatusTool: Tool {
    let name = "git_status"
    let description = "Show `git status` and the current branch for the project repository."
    let permission = PermissionClass.gitRead
    var parameters: JSONValue { Schema.object([:], required: []) }
    func summary(for a: JSONValue) -> String { "git status" }

    func execute(_ a: JSONValue, context: ToolContext) async throws -> ToolOutput {
        let git = GitService(root: context.files.root)
        guard git.isRepository else { return ToolOutput("Not a git repository.", activity: .init(kind: .git, title: "git status — not a repo")) }
        let branch = git.currentBranch() ?? "(detached)"
        let status = try git.status()
        let text = status.isEmpty ? "On \(branch). Working tree clean." :
            "On \(branch).\n" + status.map { "\($0.staged ? "staged  " : "unstaged") \($0.state.rawValue)\t\($0.path)" }.joined(separator: "\n")
        return ToolOutput(text, activity: .init(kind: .git, title: "git status — \(status.count) change\(status.count == 1 ? "" : "s") on \(branch)"))
    }
}

struct GitDiffTool: Tool {
    let name = "git_diff"
    let description = "Show the git diff of unstaged (or staged) changes, optionally for one path."
    let permission = PermissionClass.gitRead
    var parameters: JSONValue {
        Schema.object([
            "path": Schema.string("Restrict to this path (optional)"),
            "staged": Schema.boolean("Show staged changes instead of unstaged (default false)"),
        ], required: [])
    }
    func summary(for a: JSONValue) -> String { "git diff" + (a.string("path").map { " \($0)" } ?? "") }

    func execute(_ a: JSONValue, context: ToolContext) async throws -> ToolOutput {
        let git = GitService(root: context.files.root)
        guard git.isRepository else { return ToolOutput("Not a git repository.", activity: .init(kind: .git, title: "git diff — not a repo")) }
        let diff = try git.diff(path: a.string("path"), staged: a.bool("staged") ?? false)
        let text = diff.isEmpty ? "No changes." : String(diff.prefix(40_000))
        return ToolOutput(text, activity: .init(kind: .git, title: summary(for: a)))
    }
}

struct GitLogTool: Tool {
    let name = "git_log"
    let description = "Show recent commits (hash, subject, author, date)."
    let permission = PermissionClass.gitRead
    var parameters: JSONValue {
        Schema.object(["limit": Schema.integer("How many commits (default 20, max 100)")], required: [])
    }
    func summary(for a: JSONValue) -> String { "git log" }

    func execute(_ a: JSONValue, context: ToolContext) async throws -> ToolOutput {
        let git = GitService(root: context.files.root)
        guard git.isRepository else { return ToolOutput("Not a git repository.", activity: .init(kind: .git, title: "git log — not a repo")) }
        let commits = try git.log(limit: min(100, max(1, a.int("limit") ?? 20)))
        let text = commits.map { "\($0.shortHash) \($0.date) \($0.author): \($0.subject)" }.joined(separator: "\n")
        return ToolOutput(text.isEmpty ? "No commits yet." : text, activity: .init(kind: .git, title: "git log — \(commits.count) commits"))
    }
}

public enum GitTools {
    public static func all() -> [any Tool] { [GitStatusTool(), GitDiffTool(), GitLogTool()] }
}
