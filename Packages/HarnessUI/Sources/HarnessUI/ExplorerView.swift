import AppKit
import HarnessCore
import SwiftUI
import UniformTypeIdentifiers

/// The Files pane: a lazy outline of the project with the usual file operations.
public struct ExplorerView: View {
    @Bindable var workspace: ProjectWorkspace
    @State private var prompt: Prompt?
    @State private var promptText = ""
    @State private var pendingTrash: URL?

    enum Prompt: Identifiable {
        case newFile(URL), newFolder(URL), rename(URL)
        var id: String {
            switch self {
            case .newFile(let u): "newFile:\(u.path)"
            case .newFolder(let u): "newFolder:\(u.path)"
            case .rename(let u): "rename:\(u.path)"
            }
        }
        var title: String {
            switch self {
            case .newFile: "New File"
            case .newFolder: "New Folder"
            case .rename: "Rename"
            }
        }
    }

    public init(workspace: ProjectWorkspace) {
        self.workspace = workspace
    }

    public var body: some View {
        List {
            ForEach(workspace.tree.children(of: workspace.root)) { node in
                FileNodeRow(node: node, workspace: workspace, depth: 0, onPrompt: beginPrompt, onTrash: { pendingTrash = $0 })
            }
        }
        .listStyle(.sidebar)
        .contextMenu {
            Button("New File…") { beginPrompt(.newFile(workspace.root)) }
            Button("New Folder…") { beginPrompt(.newFolder(workspace.root)) }
            Divider()
            Button("Reveal in Finder") { NSWorkspace.shared.activateFileViewerSelecting([workspace.root]) }
        }
        .dropDestination(for: URL.self) { urls, _ in
            for url in urls where workspace.files.contains(url) { workspace.move(url, into: workspace.root) }
            return true
        }
        .alert(prompt?.title ?? "", isPresented: Binding(get: { prompt != nil }, set: { if !$0 { prompt = nil } })) {
            TextField("Name", text: $promptText)
            Button("OK") { commitPrompt() }
            Button("Cancel", role: .cancel) { prompt = nil }
        }
        .confirmationDialog(
            "Move \"\(pendingTrash?.lastPathComponent ?? "")\" to the Trash?",
            isPresented: Binding(get: { pendingTrash != nil }, set: { if !$0 { pendingTrash = nil } }),
            titleVisibility: .visible
        ) {
            Button("Move to Trash", role: .destructive) {
                if let url = pendingTrash { workspace.trash(url) }
                pendingTrash = nil
            }
        }
    }

    private func beginPrompt(_ p: Prompt) {
        if case .rename(let url) = p { promptText = url.lastPathComponent } else { promptText = "" }
        prompt = p
    }

    private func commitPrompt() {
        let name = promptText.trimmingCharacters(in: .whitespaces)
        defer { prompt = nil }
        guard !name.isEmpty, !name.contains("/") else { return }
        switch prompt {
        case .newFile(let dir):
            workspace.createFile(in: dir, name: name)
            workspace.open(dir.appendingPathComponent(name))
        case .newFolder(let dir): workspace.createDirectory(in: dir, name: name)
        case .rename(let url): workspace.rename(url, to: name)
        case nil: break
        }
    }
}

private struct FileNodeRow: View {
    let node: FileNode
    @Bindable var workspace: ProjectWorkspace
    let depth: Int
    let onPrompt: (ExplorerView.Prompt) -> Void
    let onTrash: (URL) -> Void

    var body: some View {
        // Reading `version` makes this row re-render after invalidation.
        let _ = workspace.tree.version
        if node.isDirectory {
            DisclosureGroup(isExpanded: Binding(
                get: { workspace.tree.isExpanded(node.url) },
                set: { workspace.tree.setExpanded(node.url, $0) }
            )) {
                ForEach(workspace.tree.children(of: node.url)) { child in
                    FileNodeRow(node: child, workspace: workspace, depth: depth + 1, onPrompt: onPrompt, onTrash: onTrash)
                }
            } label: {
                label
                    .dropDestination(for: URL.self) { urls, _ in
                        for url in urls where workspace.files.contains(url) { workspace.move(url, into: node.url) }
                        return true
                    }
            }
        } else {
            label
                .onTapGesture { workspace.open(node.url) }
        }
    }

    private var label: some View {
        Label {
            Text(node.name).lineLimit(1)
        } icon: {
            Image(systemName: node.isDirectory ? "folder" : FileIcon.symbol(for: node.name))
                .foregroundStyle(node.isDirectory ? .secondary : .tertiary)
        }
        .contentShape(Rectangle())
        .fontWeight(isActive ? .semibold : .regular)
        .draggable(node.url)
        .contextMenu {
            if node.isDirectory {
                Button("New File…") { onPrompt(.newFile(node.url)) }
                Button("New Folder…") { onPrompt(.newFolder(node.url)) }
                Divider()
            } else {
                Button("Open") { workspace.open(node.url) }
                Divider()
            }
            Button("Rename…") { onPrompt(.rename(node.url)) }
            Button("Duplicate") { workspace.duplicate(node.url) }
            Button("Reveal in Finder") { NSWorkspace.shared.activateFileViewerSelecting([node.url]) }
            Button("Copy Path") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(workspace.files.relativePath(node.url), forType: .string)
            }
            Divider()
            Button("Move to Trash", role: .destructive) { onTrash(node.url) }
        }
    }

    private var isActive: Bool { workspace.activeDocument?.url == node.url }
}

enum FileIcon {
    static func symbol(for name: String) -> String {
        switch (name as NSString).pathExtension.lowercased() {
        case "swift": "swift"
        case "ts", "tsx", "js", "jsx", "mjs", "cjs": "curlybraces"
        case "json", "yaml", "yml", "toml", "plist": "list.bullet.indent"
        case "md", "markdown", "txt": "doc.text"
        case "png", "jpg", "jpeg", "gif", "svg", "webp": "photo"
        case "sh", "zsh", "bash": "terminal"
        case "html", "css", "scss": "chevron.left.forwardslash.chevron.right"
        case "py", "rb", "go", "rs", "java", "kt", "c", "h", "cpp", "m": "chevron.left.forwardslash.chevron.right"
        default: "doc"
        }
    }
}
