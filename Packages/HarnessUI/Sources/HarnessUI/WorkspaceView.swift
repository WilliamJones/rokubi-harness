import HarnessAgent
import HarnessCore
import HarnessTerminal
import SwiftUI

/// The default layout — PRD §10: `Files | Editor | ChatGPT`. Terminal and Problems are
/// contextual (§11): they appear under the editor only while there is something to show.
public struct WorkspaceView: View {
    @Bindable var workspace: ProjectWorkspace
    @State private var editor: EditorCoordinator
    @State private var agent: AgentSession
    @State private var showError = false
    @State private var terminalCollapsed = false
    @State private var problemsExpanded = false
    @State private var composerPrefill: String?
    @State private var showReview = false
    @State private var showPalette = false
    @Environment(AuthSession.self) private var auth
    @Environment(ModelCatalog.self) private var models

    public init(workspace: ProjectWorkspace) {
        self.workspace = workspace
        _editor = State(initialValue: EditorCoordinator(workspace: workspace))
        _agent = State(initialValue: AgentSession(workspace: workspace))
    }

    public var body: some View {
        HSplitView {
            ExplorerView(workspace: workspace)
                .frame(minWidth: 180, idealWidth: 240, maxWidth: 360)
            centerColumn
                .frame(minWidth: 360, idealWidth: 760, maxWidth: .infinity)
                .layoutPriority(1)
            ChatPanelView(session: agent, editor: editor, prefill: $composerPrefill, showReview: $showReview)
                .frame(minWidth: 300, idealWidth: 380, maxWidth: 640)
        }
        .overlay(alignment: .top) {
            if showPalette {
                CommandPaletteOverlay(commands: paletteCommands, isPresented: $showPalette)
            }
        }
        .sheet(isPresented: $showReview) { DiffReviewView(session: agent) }
        .onReceive(NotificationCenter.default.publisher(for: .harnessTogglePalette)) { _ in
            showPalette.toggle()
            // Refresh the skill listing here (an event handler), so `paletteCommands` in body
            // only ever reads the cache.
            if showPalette { agent.skills.invalidate(); _ = agent.skills.all() }
        }
        .navigationTitle(workspace.ref.name)
        .navigationSubtitle(workspace.activeDocument.map { workspace.files.relativePath($0.url) } ?? "")
        .toolbar {
            ToolbarItem(placement: .principal) { ModelPicker() }
            ToolbarItem(placement: .primaryAction) { OverflowMenu(workspace: workspace, agent: agent) }
        }
        .focusedSceneValue(\.workspace, workspace)
        .onAppear {
            workspace.start()
            RecentProjects.shared.touch(workspace.ref)
            if let file = LaunchArguments.fileToOpen(in: workspace.root) { workspace.open(file) }
            agent.currentFile = { [weak workspace] in
                workspace?.activeDocument.map { workspace!.files.relativePath($0.url) }
            }
            agent.currentSelection = { [weak editor] in editor?.selection?.text }
        }
        .onDisappear {
            workspace.stop()
            agent.terminals.closeAll()
        }
        .onChange(of: workspace.lastError) { _, new in showError = new != nil }
        .onChange(of: workspace.terminalRequests) { _, _ in
            agent.terminals.openShell()
            terminalCollapsed = false
        }
        .onChange(of: agent.terminals.sessions.count) { old, new in if new > old { terminalCollapsed = false } }
        .onChange(of: agent.problems) { _, new in
            editor.problems = new
            if new.isEmpty { problemsExpanded = false }
        }
        .onChange(of: auth.isSignedIn, initial: true) { _, signedIn in
            if signedIn, let provider = auth.provider { Task { await models.refresh(using: provider) } }
        }
        .alert("Something went wrong", isPresented: $showError, presenting: workspace.lastError) { _ in
            Button("OK") { workspace.lastError = nil }
        } message: { message in
            Text(message)
        }
        .frame(minWidth: 960, minHeight: 600)
    }

    /// Editor plus the contextual surfaces beneath it. The editor takes all flexible space;
    /// each contextual panel is a fixed-height region (avoids competing flexible frames, which
    /// produced an AttributeGraph layout cycle when both panels were visible at once).
    private var centerColumn: some View {
        VStack(spacing: 0) {
            EditorAreaView(workspace: workspace, editor: editor)
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            if !agent.problems.isEmpty {
                Divider()
                HStack {
                    ProblemsChip(problems: agent.problems, expanded: $problemsExpanded)
                    Spacer()
                }
                .padding(.horizontal, 10).frame(height: 24).background(.bar)
                if problemsExpanded {
                    Divider()
                    ProblemsPanel(
                        problems: agent.problems,
                        onOpen: { p in editor.reveal(workspace.root.appendingPathComponent(p.path), line: p.line, column: p.column ?? 1) },
                        onFix: { problems in
                            let list = problems.prefix(8).map { "\($0.path):\($0.line): \($0.message)" }.joined(separator: "\n")
                            composerPrefill = "Fix these problems:\n\(list)\n\n@problems"
                        },
                        onClear: { agent.problems = [] }
                    )
                    .frame(height: 180)
                }
            }

            if !agent.terminals.sessions.isEmpty {
                Divider()
                TerminalDrawerView(terminals: agent.terminals,
                                   onOpenPath: { path, line in editor.reveal(workspace.root.appendingPathComponent(path), line: line) },
                                   collapsed: $terminalCollapsed)
                    .frame(height: terminalCollapsed ? 28 : 240)
            }
        }
    }
}

/// Title-bar model control (PRD §10 `GPT-5.6`). Opens a searchable picker — the OpenRouter
/// catalog has hundreds of models, so a plain menu won't do.
private struct ModelPicker: View {
    @Environment(ModelCatalog.self) private var models
    @Environment(AuthSession.self) private var auth
    @State private var showPicker = false

    var body: some View {
        Button { showPicker = true } label: {
            HStack(spacing: 4) {
                Text(models.selectedInfo?.name ?? models.selected).font(.callout).lineLimit(1)
                Image(systemName: "chevron.up.chevron.down").font(.system(size: 9)).foregroundStyle(.secondary)
            }
            .foregroundStyle(auth.isSignedIn ? .primary : .secondary)
        }
        .buttonStyle(.plain)
        .help("Model — click to search")
        .popover(isPresented: $showPicker, arrowEdge: .bottom) {
            ModelSearchView(isPresented: $showPicker)
                .frame(width: 380, height: 420)
        }
    }
}

private struct OverflowMenu: View {
    let workspace: ProjectWorkspace
    let agent: AgentSession
    @Environment(AuthSession.self) private var auth

    var body: some View {
        Menu {
            if let account = auth.account {
                Text(account.displayName + (account.planType.map { " · \($0)" } ?? ""))
                Button("Sign Out") { Task { await auth.signOut() } }
            } else {
                Button("Sign in with ChatGPT…") { Task { await auth.signInWithChatGPT() } }
            }
            Divider()
            Button("New Terminal") { workspace.requestTerminal() }
            Button("Reveal Project in Finder") { NSWorkspace.shared.activateFileViewerSelecting([workspace.root]) }
            Button("Reload File Tree") { workspace.tree.invalidateAll() }
        } label: {
            Image(systemName: "ellipsis")
        }
        .menuIndicator(.hidden)
    }
}


// MARK: - Command palette wiring

extension WorkspaceView {
    var paletteCommands: [HarnessCommand] {
        var c: [HarnessCommand] = [
            HarnessCommand(id: "open", title: "Open Folder…", systemImage: "folder") {
                if let url = ProjectPicker.chooseFolder() { RecentProjects.shared.touch(.init(url: url)) }
            },
            HarnessCommand(id: "review", title: "Review Changes", subtitle: "\(agent.changedFiles.count) changed", systemImage: "arrow.triangle.branch") { showReview = true },
            HarnessCommand(id: "terminal", title: "Open Terminal", systemImage: "terminal") { workspace.requestTerminal() },
            HarnessCommand(id: "format", title: "Format File", systemImage: "text.alignleft") { editor.runAction("editor.action.formatDocument") },
            HarnessCommand(id: "find", title: "Find in File", systemImage: "magnifyingglass") { editor.runAction("actions.find") },
            HarnessCommand(id: "reload", title: "Reload File Tree", systemImage: "arrow.clockwise") { workspace.tree.invalidateAll() },
            HarnessCommand(id: "newchat", title: "New Conversation", systemImage: "plus.bubble") { agent.newConversation() },
            HarnessCommand(id: "undo", title: "Undo Task", subtitle: "restore files to task start", systemImage: "arrow.uturn.backward") { Task { await agent.undoTask() } },
        ]
        // Cap the palette at a sensible number; the searchable picker handles the full catalog.
        for model in models.models.prefix(40) {
            c.append(HarnessCommand(id: "model:\(model.id)", title: "Change Model: \(model.name)",
                                    subtitle: model.subtitle, systemImage: "cpu") { models.selected = model.id })
        }
        for skill in agent.skills.all() {   // cached in SkillStore; refreshed on palette open
            c.append(HarnessCommand(id: "skill:\(skill.id)", title: "/\(skill.name)", subtitle: skill.description, systemImage: "wand.and.stars") {
                composerPrefill = "/\(skill.name) "
            })
        }
        if agent.isGitRepository {
            c.append(HarnessCommand(id: "commit", title: "Git Commit…", systemImage: "checkmark.seal") {
                agent.commitChanges(agent.completion?.summary ?? "Update")
            })
        }
        return c
    }
}

/// Hosts the palette centered near the top, dimming the rest.
private struct CommandPaletteOverlay: View {
    let commands: [HarnessCommand]
    @Binding var isPresented: Bool
    var body: some View {
        ZStack(alignment: .top) {
            Color.black.opacity(0.12).ignoresSafeArea().onTapGesture { isPresented = false }
            CommandPalette(commands: commands, isPresented: $isPresented).padding(.top, 80)
        }
    }
}

public extension Notification.Name {
    /// Posted by the ⌘K menu command; observed by the frontmost workspace window.
    static let harnessTogglePalette = Notification.Name("com.rokubi.harness.togglePalette")
}
