import Foundation
import HarnessCore

// PRD §6.3 primitives: READ / CREATE / EDIT / DELETE (SEARCH is in SearchTools, RUN in RunTools).

struct ReadFileTool: Tool {
    let name = "read_file"
    let description = "Read a UTF-8 text file from the project. Returns numbered lines. Use start_line/end_line for large files (max 400 lines per call)."
    let permission = PermissionClass.read
    var parameters: JSONValue {
        Schema.object([
            "path": Schema.string("Project-relative path"),
            "start_line": Schema.integer("First line to return (1-based, default 1)"),
            "end_line": Schema.integer("Last line to return (inclusive)"),
        ], required: ["path"])
    }

    func summary(for a: JSONValue) -> String { "Read \(a.string("path") ?? "?")" }
    func subject(for a: JSONValue) -> String? { a.string("path") }

    func execute(_ a: JSONValue, context: ToolContext) async throws -> ToolOutput {
        let path = try a.requiredString("path")
        let url = try context.files.resolve(path)
        let text = try context.files.readTextForAgent(url)
        let lines = FileService.lines(of: text)
        let start = max(1, a.int("start_line") ?? 1)
        let requestedEnd = a.int("end_line") ?? (start + 399)
        let end = min(lines.count, requestedEnd, start + 399)
        guard start <= lines.count else { throw ToolError("\(path) has only \(lines.count) lines") }
        var out = ""
        for i in (start - 1)..<end { out += "\(i + 1)\t\(lines[i])\n" }
        if end < lines.count { out += "… \(lines.count - end) more lines (total \(lines.count)). Use start_line=\(end + 1) to continue.\n" }
        let title = lines.count > 400 ? "Read \(path) (lines \(start)–\(end) of \(lines.count))" : "Read \(path)"
        return ToolOutput(out, activity: ActivityRecord(kind: .read, title: title))
    }
}

struct ListDirTool: Tool {
    let name = "list_dir"
    let description = "List the entries of a project directory (non-recursive). Directories end with '/'."
    let permission = PermissionClass.read
    var parameters: JSONValue {
        Schema.object(["path": Schema.string("Project-relative directory path ('' or '.' for the root)")], required: ["path"])
    }

    func summary(for a: JSONValue) -> String { "Listed \(displayPath(a.string("path")))" }
    func subject(for a: JSONValue) -> String? { a.string("path") }

    func execute(_ a: JSONValue, context: ToolContext) async throws -> ToolOutput {
        let path = a.string("path") ?? "."
        let url = try context.files.resolve(path == "." || path.isEmpty ? "." : path)
        guard context.files.isDirectory(url) else { throw ToolError("\(path) is not a directory") }
        let entries = context.search.list(url)
        let text = entries.map { $0.name + ($0.isDirectory ? "/" : "") }.joined(separator: "\n")
        return ToolOutput(text.isEmpty ? "(empty)" : text,
                          activity: ActivityRecord(kind: .read, title: "Listed \(displayPath(path)) (\(entries.count) entries)"))
    }

    private func displayPath(_ p: String?) -> String { (p == nil || p == "." || p == "") ? "project root" : p! }
}

struct WriteFileTool: Tool {
    let name = "write_file"
    let description = "Replace the entire contents of a file (creates it if missing). Prefer apply_patch for edits to existing files."
    let permission = PermissionClass.edit
    var parameters: JSONValue {
        Schema.object([
            "path": Schema.string("Project-relative path"),
            "content": Schema.string("Full new file contents"),
        ], required: ["path", "content"])
    }

    func summary(for a: JSONValue) -> String { "Wrote \(a.string("path") ?? "?")" }
    func subject(for a: JSONValue) -> String? { a.string("path") }

    func execute(_ a: JSONValue, context: ToolContext) async throws -> ToolOutput {
        let path = try a.requiredString("path")
        let content = a.string("content") ?? ""
        let url = try context.files.resolve(path)
        guard !context.files.isProtected(url) else { throw ToolError("\(path) is protected") }
        let existed = context.files.exists(url)
        try await context.willMutate(url, label: "write_file \(path)")
        try context.files.writeText(content, to: url)
        await context.didMutate(url)
        let lines = content.split(separator: "\n", omittingEmptySubsequences: false).count
        return ToolOutput("Wrote \(lines) lines to \(path)",
                          activity: ActivityRecord(kind: existed ? .edit : .create, title: "\(existed ? "Rewrote" : "Created") \(path)"))
    }
}

struct CreateFileTool: Tool {
    let name = "create_file"
    let description = "Create a new file. Fails if it already exists."
    let permission = PermissionClass.create
    var parameters: JSONValue {
        Schema.object([
            "path": Schema.string("Project-relative path"),
            "content": Schema.string("File contents (may be empty)"),
        ], required: ["path", "content"])
    }

    func summary(for a: JSONValue) -> String { "Create \(a.string("path") ?? "?")" }
    func subject(for a: JSONValue) -> String? { a.string("path") }

    func execute(_ a: JSONValue, context: ToolContext) async throws -> ToolOutput {
        let path = try a.requiredString("path")
        let url = try context.files.resolve(path)
        guard !context.files.isProtected(url) else { throw ToolError("\(path) is protected") }
        try await context.willMutate(url, label: "create_file \(path)")
        try context.files.createFile(at: url, contents: a.string("content") ?? "")
        await context.didMutate(url)
        return ToolOutput("Created \(path)", activity: ActivityRecord(kind: .create, title: "Created \(path)"))
    }
}

struct ApplyPatchTool: Tool {
    let name = "apply_patch"
    let description = """
    Edit a file with one or more search/replace blocks. Each `old` must appear exactly once in the file \
    (include enough surrounding lines to be unique) and is replaced by `new`. Read the file first.
    """
    let permission = PermissionClass.edit
    var parameters: JSONValue {
        Schema.object([
            "path": Schema.string("Project-relative path of an existing file"),
            "edits": Schema.array("Edits applied in order", items: Schema.object([
                "old": Schema.string("Exact text to find (verbatim, including indentation)"),
                "new": Schema.string("Replacement text"),
            ], required: ["old", "new"])),
        ], required: ["path", "edits"])
    }

    func summary(for a: JSONValue) -> String {
        let n = a["edits"]?.arrayValue?.count ?? 0
        return "Edit \(a.string("path") ?? "?")" + (n > 1 ? " (\(n) edits)" : "")
    }
    func subject(for a: JSONValue) -> String? { a.string("path") }

    func execute(_ a: JSONValue, context: ToolContext) async throws -> ToolOutput {
        let path = try a.requiredString("path")
        let url = try context.files.resolve(path)
        guard !context.files.isProtected(url) else { throw ToolError("\(path) is protected") }
        let edits: [PatchApplier.Edit] = (a["edits"]?.arrayValue ?? []).compactMap { e in
            guard let old = e.string("old"), let new = e.string("new") else { return nil }
            return .init(old: old, new: new)
        }
        guard !edits.isEmpty else { throw ToolError("`edits` must contain at least one {old,new} block") }
        let original = try context.files.readTextForAgent(url)
        let result = try PatchApplier.apply(edits, to: original)
        try await context.willMutate(url, label: "apply_patch \(path)")
        try context.files.writeText(result.text, to: url)
        await context.didMutate(url)
        let delta = result.text.split(separator: "\n").count - original.split(separator: "\n").count
        let note = result.fuzzyEdits > 0 ? " (\(result.fuzzyEdits) edit(s) matched with whitespace differences)" : ""
        return ToolOutput("Applied \(edits.count) edit(s) to \(path)\(note). Line delta: \(delta >= 0 ? "+" : "")\(delta).",
                          activity: ActivityRecord(kind: .edit, title: "Edited \(path)"))
    }
}

struct DeletePathTool: Tool {
    let name = "delete_path"
    let description = "Move a file or directory to the Trash."
    let permission = PermissionClass.delete
    var parameters: JSONValue {
        Schema.object(["path": Schema.string("Project-relative path")], required: ["path"])
    }

    func summary(for a: JSONValue) -> String { "Delete \(a.string("path") ?? "?")" }
    func subject(for a: JSONValue) -> String? { a.string("path") }

    func execute(_ a: JSONValue, context: ToolContext) async throws -> ToolOutput {
        let path = try a.requiredString("path")
        let url = try context.files.resolve(path)
        guard !context.files.isProtected(url) else { throw ToolError("\(path) is protected") }
        guard context.files.exists(url) else { throw ToolError("\(path) does not exist") }
        if context.files.isDirectory(url) {
            // A folder can hold many files: capture them all so Undo Task can bring the folder back.
            let before = await context.captureTree()
            try context.files.trash(url)
            await context.recordChanges(since: before, label: "delete_path \(path)")
            await context.didMutate(url)
        } else {
            try await context.willMutate(url, label: "delete_path \(path)")
            try context.files.trash(url)
            await context.didMutate(url)
        }
        return ToolOutput("Moved \(path) to the Trash", activity: ActivityRecord(kind: .delete, title: "Deleted \(path)"))
    }
}

struct RenamePathTool: Tool {
    let name = "rename_path"
    let description = "Move or rename a file or directory within the project."
    let permission = PermissionClass.edit
    var parameters: JSONValue {
        Schema.object([
            "from": Schema.string("Existing project-relative path"),
            "to": Schema.string("New project-relative path"),
        ], required: ["from", "to"])
    }

    func summary(for a: JSONValue) -> String { "Move \(a.string("from") ?? "?") → \(a.string("to") ?? "?")" }
    func subject(for a: JSONValue) -> String? { a.string("from") }

    func execute(_ a: JSONValue, context: ToolContext) async throws -> ToolOutput {
        let from = try a.requiredString("from"), to = try a.requiredString("to")
        let src = try context.files.resolve(from), dst = try context.files.resolve(to)
        // Renaming a secret to an innocuous name would let a later read_file bypass the exclusion list.
        guard !context.files.isProtected(src), !context.files.isProtected(dst) else { throw ToolError("\(from) is protected") }
        if context.files.isDirectory(src) {
            let before = await context.captureTree()
            try context.files.move(src, to: dst)
            await context.recordChanges(since: before, label: "rename_path \(from) → \(to)")
        } else {
            try await context.willMutate(src, label: "rename_path \(from)")
            try await context.willMutate(dst, label: "rename_path \(to)")
            try context.files.move(src, to: dst)
        }
        await context.didMutate(src)
        await context.didMutate(dst)
        return ToolOutput("Moved \(from) to \(to)", activity: ActivityRecord(kind: .edit, title: "Moved \(from) → \(to)"))
    }
}
