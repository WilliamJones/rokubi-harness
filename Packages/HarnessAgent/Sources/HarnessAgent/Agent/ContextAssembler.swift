import Foundation
import HarnessCore

/// Builds the always-loaded context (PRD FR-005): small, stable, retrieved-on-demand for the rest.
public struct ContextAssembler: Sendable {
    public var files: FileService
    public var ignore: IgnoreRules
    public var autonomySummary: String
    public var currentFile: String?
    public var selection: String?
    /// What the model is told it is — the selected model id/name and the provider serving it.
    public var modelName: String
    public var providerName: String

    public init(files: FileService, ignore: IgnoreRules, autonomySummary: String, currentFile: String? = nil,
                selection: String? = nil, modelName: String = "the assistant", providerName: String = "the configured provider") {
        self.files = files
        self.ignore = ignore
        self.autonomySummary = autonomySummary
        self.currentFile = currentFile
        self.selection = selection
        self.modelName = modelName
        self.providerName = providerName
    }

    public func instructions() -> String {
        var parts = [SystemPrompt.instructions(modelName: modelName, providerName: providerName)]
        parts.append("Project root: \(files.root.path)\nAutonomy: \(autonomySummary)")
        if let agents = agentsMD() { parts.append("# AGENTS.md\n\(agents)") }
        parts.append("# Project map\n\(projectMap())")
        if let currentFile { parts.append("Current file in editor: \(currentFile)") }
        if let selection, !selection.isEmpty { parts.append("Selected code:\n```\n\(selection.prefix(4000))\n```") }
        return parts.joined(separator: "\n\n")
    }

    func agentsMD() -> String? {
        let url = files.root.appendingPathComponent("AGENTS.md")
        guard let text = try? files.readText(url) else { return nil }
        return String(text.prefix(12_000))
    }

    /// Top two levels of the tree, capped, so the model knows the shape without a big dump.
    func projectMap(maxEntries: Int = 200) -> String {
        var lines: [String] = []
        let fm = FileManager.default
        func list(_ dir: URL, depth: Int) {
            guard lines.count < maxEntries, depth < 2 else { return }
            guard let urls = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.isDirectoryKey]) else { return }
            let sorted = urls.sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
            for url in sorted where lines.count < maxEntries {
                let isDir = (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
                let rel = files.relativePath(url)
                if ignore.isIgnored(relativePath: rel, isDirectory: isDir) { continue }
                lines.append(String(repeating: "  ", count: depth) + (isDir ? rel.split(separator: "/").last.map { $0 + "/" } ?? "" : url.lastPathComponent))
                if isDir { list(url, depth: depth + 1) }
            }
        }
        list(files.root, depth: 0)
        if lines.count >= maxEntries { lines.append("… (truncated; use list_dir/glob for more)") }
        return lines.joined(separator: "\n")
    }
}
