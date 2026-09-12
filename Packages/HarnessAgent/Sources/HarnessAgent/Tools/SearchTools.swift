import Foundation
import HarnessCore

struct GlobTool: Tool {
    let name = "glob"
    let description = "Find files by name pattern, e.g. '*.ts', 'src/**/*.test.js', '**/package.json'. Ignores build output and dependencies."
    let permission = PermissionClass.search
    var parameters: JSONValue {
        Schema.object(["pattern": Schema.string("Glob pattern; without '/' it matches file names at any depth")], required: ["pattern"])
    }

    func summary(for a: JSONValue) -> String { "Find files \(a.string("pattern") ?? "")" }

    func execute(_ a: JSONValue, context: ToolContext) async throws -> ToolOutput {
        let pattern = try a.requiredString("pattern")
        let paths = context.search.glob(pattern)
        let text = paths.isEmpty ? "No files match \(pattern)" : paths.joined(separator: "\n")
        return ToolOutput(text, activity: ActivityRecord(kind: .search, title: "Found \(paths.count) file\(paths.count == 1 ? "" : "s") matching \(pattern)"))
    }
}

struct GrepTool: Tool {
    let name = "grep"
    let description = "Search file contents with a regular expression (or literal text). Returns path:line: text. Case-insensitive by default."
    let permission = PermissionClass.search
    var parameters: JSONValue {
        Schema.object([
            "pattern": Schema.string("Regular expression (ICU syntax) or literal text"),
            "literal": Schema.boolean("Treat pattern as literal text (default false)"),
            "case_sensitive": Schema.boolean("Default false"),
            "path_glob": Schema.string("Restrict to files matching this glob, e.g. 'src/**/*.ts'"),
            "max_results": Schema.integer("Maximum matches to return (default 100, max 300)"),
        ], required: ["pattern"])
    }

    func summary(for a: JSONValue) -> String {
        var s = "Searched for \"\(a.string("pattern") ?? "")\""
        if let g = a.string("path_glob") { s += " in \(g)" }
        return s
    }

    func execute(_ a: JSONValue, context: ToolContext) async throws -> ToolOutput {
        let pattern = try a.requiredString("pattern")
        let limit = min(300, max(1, a.int("max_results") ?? 100))
        let result = context.search.grep(pattern, isRegex: !(a.bool("literal") ?? false),
                                         caseSensitive: a.bool("case_sensitive") ?? false,
                                         pathGlob: a.string("path_glob"), limit: limit)
        var text = result.matches.map { "\($0.path):\($0.line): \($0.text)" }.joined(separator: "\n")
        if result.matches.isEmpty { text = "No matches for \(pattern) (\(result.filesScanned) files scanned)" }
        if result.truncated { text += "\n… truncated at \(limit) matches; narrow the pattern or path_glob." }
        let fileCount = Set(result.matches.map(\.path)).count
        let title = "\(summary(for: a)) — \(result.matches.count) match\(result.matches.count == 1 ? "" : "es") in \(fileCount) file\(fileCount == 1 ? "" : "s")"
        let detail = result.matches.prefix(12).map { "\($0.path):\($0.line)" }.joined(separator: "\n")
        return ToolOutput(text, activity: ActivityRecord(kind: .search, title: title, detail: detail.isEmpty ? nil : detail))
    }
}
