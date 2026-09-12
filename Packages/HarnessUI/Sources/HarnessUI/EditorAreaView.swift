import HarnessCore
import HarnessEditor
import SwiftUI

/// Tab strip + Monaco. The web view stays mounted even with no documents so
/// opening the first file is instant.
public struct EditorAreaView: View {
    @Bindable var workspace: ProjectWorkspace
    let editor: EditorCoordinator

    public init(workspace: ProjectWorkspace, editor: EditorCoordinator) {
        self.workspace = workspace
        self.editor = editor
    }

    public var body: some View {
        VStack(spacing: 0) {
            if !workspace.documents.isEmpty {
                TabStrip(workspace: workspace)
                Divider()
            }
            ZStack {
                MonacoEditorView(controller: editor.monaco)
                    .opacity(workspace.documents.isEmpty ? 0 : 1)
                if workspace.documents.isEmpty {
                    EmptyEditorView(projectName: workspace.ref.name)
                }
            }
            if let doc = workspace.activeDocument, doc.hasExternalChange {
                ExternalChangeBar(doc: doc, workspace: workspace)
            }
        }
        .onChange(of: editor.syncKey, initial: true) { _, _ in editor.sync() }
        .focusedSceneValue(\.editor, editor)
    }
}

private struct TabStrip: View {
    @Bindable var workspace: ProjectWorkspace

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 0) {
                ForEach(workspace.documents) { doc in
                    TabItem(doc: doc, isActive: doc.id == workspace.activeDocumentID,
                            activate: { workspace.activeDocumentID = doc.id },
                            close: { workspace.close(doc.id) })
                }
            }
        }
        .frame(height: 32)
        .background(.bar)
    }
}

private struct TabItem: View {
    let doc: TextDocument
    let isActive: Bool
    let activate: () -> Void
    let close: () -> Void
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: FileIcon.symbol(for: doc.name)).font(.caption).foregroundStyle(.secondary)
            Text(doc.name).font(.callout).lineLimit(1)
            Button(action: close) {
                Image(systemName: doc.isDirty && !hovering ? "circle.fill" : "xmark")
                    .font(.system(size: doc.isDirty && !hovering ? 7 : 9, weight: .semibold))
                    .frame(width: 14, height: 14)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .opacity(hovering || doc.isDirty || isActive ? 1 : 0)
        }
        .padding(.horizontal, 12)
        .frame(height: 32)
        .background(isActive ? Color(nsColor: .textBackgroundColor) : .clear)
        .overlay(alignment: .trailing) { Divider() }
        .contentShape(Rectangle())
        .onTapGesture(perform: activate)
        .onHover { hovering = $0 }
        .help(doc.url.path)
    }
}

private struct EmptyEditorView: View {
    let projectName: String
    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: "doc.text").font(.system(size: 36)).foregroundStyle(.quaternary)
            Text(projectName).font(.title3).foregroundStyle(.secondary)
            Text("Open a file, or tell the agent what to build.").font(.callout).foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .textBackgroundColor))
    }
}

/// Shown when a dirty buffer's file changed on disk (human or agent edit outside the editor).
private struct ExternalChangeBar: View {
    let doc: TextDocument
    let workspace: ProjectWorkspace

    var body: some View {
        HStack {
            Image(systemName: "exclamationmark.triangle").foregroundStyle(.orange)
            Text("\(doc.name) changed on disk while you had unsaved edits.").font(.callout)
            Spacer()
            Button("Reload") { workspace.refreshFromDisk(doc.url); reloadIgnoringDirty() }
            Button("Keep Mine") { doc.hasExternalChange = false }
        }
        .padding(.horizontal, 12).padding(.vertical, 6)
        .background(.bar)
    }

    private func reloadIgnoringDirty() {
        if let text = try? workspace.files.readText(doc.url) { doc.reload(text: text) }
    }
}
