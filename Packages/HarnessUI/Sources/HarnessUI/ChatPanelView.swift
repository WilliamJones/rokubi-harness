import HarnessAgent
import HarnessCore
import SwiftUI

/// The ChatGPT pane: transcript, live activity, composer, and — until signed in — the sign-in card.
public struct ChatPanelView: View {
    @Bindable var session: AgentSession
    let editor: EditorCoordinator
    @Environment(AuthSession.self) private var auth
    @Environment(ModelCatalog.self) private var models
    @State private var draft = ""
    @State private var apiKeyDraft = ""
    @State private var showAPIKeyField = false
    @State private var openRouterDraft = ""
    @State private var openRouterVisible = false
    @Binding var prefill: String?
    @Binding var showReview: Bool
    @Binding var showCommit: Bool
    @State private var suggestions: [ComposerSuggestion] = []
    /// Project files + folders for `@` mentions, built off the main actor (see `rebuildFileIndex`).
    @State private var fileIndex: [String] = []

    public init(session: AgentSession, editor: EditorCoordinator, prefill: Binding<String?> = .constant(nil), showReview: Binding<Bool> = .constant(false),
                showCommit: Binding<Bool> = .constant(false)) {
        self.session = session
        self.editor = editor
        _prefill = prefill
        _showReview = showReview
        _showCommit = showCommit
    }

    private var assistantName: String { AssistantIdentity.name(mode: auth.account?.mode, model: models.selectedInfo) }

    public var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if !session.plan.isEmpty {
                PlanPanel(steps: session.plan)
                Divider()
            }
            transcript
            if !session.changedFiles.isEmpty && session.completion == nil {
                Divider()
                ChangesChip(count: session.changedFiles.count, onReview: { showReview = true }, canReview: true)
            }
            Divider()
            if auth.isSignedIn { composer } else { signInCard }
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .onChange(of: auth.lastError) { _, e in if let e { session.lastError = e } }
        .onChange(of: prefill) { _, text in
            if let text { draft = text; prefill = nil }
        }
        .task {
            // `--prompt "..."` (Debug) sends a message once signed in — used by the mock-server smoke test.
            if let prompt = LaunchArguments.promptToSend() {
                for _ in 0..<40 where !auth.isSignedIn { try? await Task.sleep(for: .milliseconds(250)) }
                guard auth.isSignedIn else { return }
                draft = prompt
                send()
            }
        }
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 8) {
            Menu {
                Button("New Conversation") { session.newConversation() }
                if !session.store.summaries.isEmpty {
                    Divider()
                    ForEach(session.store.summaries.prefix(15)) { s in
                        Button(s.title) { session.open(conversationID: s.id) }
                    }
                }
            } label: {
                HStack(spacing: 4) {
                    Text(assistantName).font(.headline).lineLimit(1).truncationMode(.tail)
                    Image(systemName: "chevron.down").font(.caption2).foregroundStyle(.secondary)
                }
            }
            .menuStyle(.borderlessButton).menuIndicator(.hidden)
            .layoutPriority(0)
            .disabled(session.isRunning)

            Spacer()

            Menu {
                ForEach(AutonomyPreset.allCases) { preset in
                    Button {
                        session.autonomy = preset
                    } label: {
                        if preset == session.autonomy { Label(preset.title, systemImage: "checkmark") } else { Text(preset.title) }
                    }
                }
            } label: {
                Text("Autonomy: \(session.autonomy.title)").lineLimit(1)
            }
            .menuStyle(.borderlessButton).fixedSize()
            .layoutPriority(1)
            .help(session.autonomy.summary)
        }
        .padding(.horizontal, 12)
        .frame(height: 38)
    }

    // MARK: Transcript

    private var transcript: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    if session.conversation.isEmpty && session.streamingOrder.isEmpty {
                        emptyState
                    }
                    ForEach(session.conversation.entries) { entry in
                        entryView(entry).id(entry.id)
                    }
                    ForEach(session.liveActivityOrder, id: \.self) { callID in
                        if let a = session.liveActivity[callID], !alreadyRecorded(callID) {
                            ActivityRow(activity: a, isLive: session.isRunning && a.succeeded && a.detail == nil)
                        }
                    }
                    if let request = session.pendingPermission {
                        PermissionCard(request: request, assistantName: assistantName) { session.respond($0) }
                    }
                    if !session.reasoningPreview.isEmpty { ReasoningPreview(text: session.reasoningPreview) }
                    ForEach(session.streamingOrder, id: \.self) { id in
                        AssistantMessageView(text: session.streamingText[id] ?? "", isStreaming: true)
                    }
                    if let report = session.completion, !session.isRunning {
                        CompletionCard(report: report, changedCount: session.changedFiles.count,
                                       onReview: { showReview = true }, onCommit: { showCommit = true },
                                       onUndo: { Task { await session.undoTask() } },
                                       canReview: true, canCommit: session.isGitRepository && session.currentTaskID != nil)
                    }
                    if session.isRunning && session.streamingOrder.isEmpty && session.reasoningPreview.isEmpty && session.pendingPermission == nil {
                        HStack(spacing: 6) { ProgressView().controlSize(.small); Text("Thinking…").font(.callout).foregroundStyle(.tertiary) }
                    }
                    Color.clear.frame(height: 1).id("bottom")
                }
                .padding(14)
            }
            // One cheap integer key; reading an observable dict's values in an onChange key
            // formed an AttributeGraph cycle with the ScrollViewReader geometry.
            .onChange(of: session.contentRevision) { _, _ in scrollToBottom(proxy) }
        }
    }

    private func alreadyRecorded(_ callID: String) -> Bool {
        session.conversation.entries.contains {
            if case .functionCallOutput(_, let c, _, _) = $0 { return c == callID }
            return false
        }
    }

    @State private var scrollPending = false

    /// Scroll *after* the current layout transaction settles, and coalesce bursts. Scrolling
    /// synchronously while the completion card is being inserted ran through an AppKit animation
    /// group and fed back into layout — an AttributeGraph cycle that aborted the app.
    private func scrollToBottom(_ proxy: ScrollViewProxy) {
        guard !scrollPending else { return }
        scrollPending = true
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(40))
            scrollPending = false
            var t = Transaction(); t.disablesAnimations = true
            withTransaction(t) { proxy.scrollTo("bottom", anchor: .bottom) }
        }
    }

    @ViewBuilder
    private func entryView(_ entry: ConversationEntry) -> some View {
        switch entry {
        case let .user(_, text, context):
            UserMessageView(text: text, attachments: context)
        case let .assistant(_, text):
            AssistantMessageView(text: text, isStreaming: false)
        case .reasoning:
            EmptyView()
        case .functionCall:
            EmptyView()
        case let .functionCallOutput(_, _, _, activity):
            if let activity { ActivityRow(activity: activity, isLive: false) }
        case let .note(_, text):
            NoteRow(text: text)
        }
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Text(models.selected == nil ? "Choose a model to start." : "Give \(assistantName) a goal.")
                .font(.headline)
            Text(models.selected == nil
                 ? "Click Choose Model in the toolbar and pick one. Your choice is remembered next time."
                 : "It will search, read, edit, run and verify — and show you the evidence. Reference files with @.")
                .font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 60).padding(.horizontal, 20)
    }

    // MARK: Composer

    private var composer: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let error = session.lastError {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle").foregroundStyle(.orange)
                    Text(error).font(.caption).lineLimit(3)
                    Spacer()
                    Button { session.lastError = nil } label: { Image(systemName: "xmark").font(.caption2) }.buttonStyle(.plain)
                }
                .padding(.bottom, 2)
            }
            if !suggestions.isEmpty {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(suggestions.enumerated()), id: \.element.id) { index, item in
                        Button { accept(item) } label: {
                            HStack(spacing: 8) {
                                Image(systemName: item.icon).frame(width: 14).foregroundStyle(.secondary)
                                Text(item.title).fontWeight(.medium).lineLimit(1)
                                Text(item.subtitle).foregroundStyle(.secondary).lineLimit(1)
                                Spacer()
                                if index == 0 { Text("⇥").foregroundStyle(.tertiary) }
                            }
                            .font(.caption).padding(.horizontal, 6).padding(.vertical, 3)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.bottom, 4)
            }
            TextField(models.selected == nil
                      ? "Choose a model in the toolbar to start…"
                      : "Ask \(assistantName) to build, fix, explain…  (/ for skills, @ for context)",
                      text: $draft, axis: .vertical)
                .textFieldStyle(.plain)
                .lineLimit(1...10)
                .font(.body)
                .onSubmit(send)
                .onChange(of: draft) { _, text in updateSuggestions(text) }
                .onKeyPress(.tab) {
                    guard let first = suggestions.first else { return .ignored }
                    accept(first)
                    return .handled
                }
            HStack {
                Text(auth.account?.displayName ?? "").font(.caption).foregroundStyle(.tertiary)
                if session.conversation.totalInputTokens > 0 {
                    Text("· \(session.conversation.totalInputTokens + session.conversation.totalOutputTokens) tokens")
                        .font(.caption).foregroundStyle(.quaternary)
                }
                Spacer()
                if session.isRunning {
                    Button { session.cancel() } label: { Image(systemName: "stop.circle.fill").font(.title2) }
                        .buttonStyle(.plain).help("Stop")
                        .keyboardShortcut(".", modifiers: .command)
                } else {
                    Button(action: send) { Image(systemName: "arrow.up.circle.fill").font(.title2) }
                        .buttonStyle(.plain)
                        .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || models.selected == nil)
                        .keyboardShortcut(.return, modifiers: .command)
                }
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color(nsColor: .textBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(.quaternary))
        .padding(10)
        .task(id: session.workspace.tree.version) { await rebuildFileIndex() }
    }

    /// Lists project files once per tree version, off the main actor — the glob walks up to
    /// 4000 entries, far too slow for a keystroke. `@` suggestions only filter the cached list.
    private func rebuildFileIndex() async {
        if !fileIndex.isEmpty {
            // Agent edits bump the tree version per file; coalesce the burst.
            do { try await Task.sleep(for: .milliseconds(250)) } catch { return }
        }
        let files = session.workspace.files
        let root = session.workspace.root
        let index = await Task.detached(priority: .utility) { () -> [String] in
            let search = SearchService(files: files, ignore: IgnoreRules.load(root: root, defaults: IgnoreRules.searchDefaults))
            let paths = search.glob("**/*", limit: 4000)
            var dirs = Set<String>()
            for f in paths { var p = f; while let r = p.range(of: "/", options: .backwards) { p = String(p[..<r.lowerBound]); dirs.insert(p + "/") } }
            return paths + dirs.sorted()
        }.value
        guard !Task.isCancelled else { return }
        fileIndex = index
        // If the user is mid-`@`, refresh the list so the fresh index shows without another keystroke.
        if currentToken(in: draft).token.hasPrefix("@") { updateSuggestions(draft) }
    }

    // MARK: Composer suggestions (`/` skills, `@` context)

    /// The whitespace-delimited token the user is currently typing (assumes the caret is at the end).
    private func currentToken(in text: String) -> (start: String.Index, token: String) {
        let start = text.lastIndex(where: { $0.isWhitespace }).map { text.index(after: $0) } ?? text.startIndex
        return (start, String(text[start...]))
    }

    private func updateSuggestions(_ text: String) {
        // `/skill` only at the very start of the message.
        if text.hasPrefix("/"), !text.contains(where: { $0.isWhitespace }) {
            let q = text.dropFirst().lowercased()
            suggestions = session.skills.all()
                .filter { q.isEmpty || $0.name.lowercased().hasPrefix(q) }
                .prefix(8).map { .skill($0) }
            return
        }
        let (_, token) = currentToken(in: text)
        guard token.hasPrefix("@") else { suggestions = []; return }
        let q = token.dropFirst().lowercased()
        suggestions = mentionSuggestions(query: String(q))
    }

    private func mentionSuggestions(query q: String) -> [ComposerSuggestion] {
        var out: [ComposerSuggestion] = []
        let specials: [ComposerSuggestion] = [
            .mention(token: "selection", title: "@selection", icon: "text.cursor",
                     subtitle: editor.selection.map { "\($0.text.count) selected characters" } ?? "nothing selected"),
            .mention(token: "terminal", title: "@terminal", icon: "terminal",
                     subtitle: session.terminals.recentOutput == nil ? "no terminal output yet" : "recent terminal output"),
            .mention(token: "problems", title: "@problems", icon: "exclamationmark.triangle",
                     subtitle: session.problems.isEmpty ? "no problems" : "\(session.problems.count) problem\(session.problems.count == 1 ? "" : "s")"),
            .mention(token: "changes", title: "@changes", icon: "pencil.line",
                     subtitle: session.changedFiles.isEmpty ? "no changes this task" : "\(session.changedFiles.count) changed file\(session.changedFiles.count == 1 ? "" : "s")"),
        ]
        out += specials.filter { q.isEmpty || $0.title.dropFirst().lowercased().hasPrefix(q) }

        // Project files and folders, fuzzy-matched against the cached index (empty until the
        // first build finishes, in which case only the specials show).
        let ranked: [(String, Int)] = q.isEmpty
            ? fileIndex.prefix(8).map { ($0, 0) }
            : fileIndex.compactMap { path in fuzzyScore(q, in: path.lowercased()).map { (path, $0 + (path.lowercased().hasPrefix(q) ? 50 : 0)) } }
                .sorted { $0.1 > $1.1 }
        for (path, _) in ranked.prefix(max(2, 8 - out.count)) {
            let isDir = path.hasSuffix("/")
            out.append(.mention(token: path, title: "@\(path)", icon: isDir ? "folder" : FileIcon.symbol(for: path),
                                subtitle: isDir ? "folder listing" : "file contents"))
        }
        return out
    }

    private func accept(_ item: ComposerSuggestion) {
        switch item {
        case .skill(let skill):
            draft = "/\(skill.name) "
        case .mention(let token, _, _, _):
            let (start, _) = currentToken(in: draft)
            draft = String(draft[..<start]) + "@\(token) "
        }
        suggestions = []
    }

    private func send() {
        // No model until the user picks one; keep the draft so nothing typed is lost.
        guard let model = models.selected else {
            session.lastError = "Choose a model first: click Choose Model in the toolbar."
            return
        }
        suggestions = []
        let (text, attachments) = ContextResolver(workspace: session.workspace, editor: editor, session: session).resolve(draft)
        session.send(text, attachments: attachments, auth: auth, model: model)
        draft = ""
    }

    // MARK: Sign-in

    private var signInCard: some View {
        VStack(spacing: 10) {
            if auth.state == .signingIn {
                ProgressView().controlSize(.small)
                Text("Finish signing in in your browser…").font(.callout).foregroundStyle(.secondary)
                Button("Cancel") { Task { await auth.cancelSignIn() } }
            } else {
                Button {
                    Task { await auth.signInWithChatGPT() }
                } label: {
                    Label("Sign in with ChatGPT", systemImage: "person.crop.circle")
                        .frame(maxWidth: .infinity)
                }
                .controlSize(.large)
                .buttonStyle(.borderedProminent)

                if openRouterVisible {
                    HStack {
                        SecureField("OpenRouter key (sk-or-…)", text: $openRouterDraft)
                            .textFieldStyle(.roundedBorder)
                            .onSubmit { Task { await auth.useOpenRouter(openRouterDraft) } }
                        Button("Connect") {
                            Task { await auth.useOpenRouter(openRouterDraft) }
                        }.disabled(openRouterDraft.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                    Text("One key, any OpenRouter model — search them from the model menu once connected.")
                        .font(.caption2).foregroundStyle(.tertiary).multilineTextAlignment(.center)
                } else {
                    Button {
                        openRouterVisible = true
                    } label: {
                        Label("Connect OpenRouter", systemImage: "point.3.connected.trianglepath.dotted")
                            .frame(maxWidth: .infinity)
                    }
                    .controlSize(.large)
                    .buttonStyle(.bordered)
                }

                if showAPIKeyField {
                    HStack {
                        SecureField("OpenAI key (sk-…)", text: $apiKeyDraft).textFieldStyle(.roundedBorder)
                        Button("Use") {
                            Task { await auth.useAPIKey(apiKeyDraft); apiKeyDraft = "" }
                        }.disabled(apiKeyDraft.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                } else {
                    Button("Use an OpenAI API key instead") { showAPIKeyField = true }
                        .buttonStyle(.link).font(.caption)
                }
                if let error = auth.lastError {
                    Text(error).font(.caption).foregroundStyle(.red).multilineTextAlignment(.center)
                }
            }
        }
        .padding(14)
    }
}

/// Turns `@path`, `@selection`, `@terminal`, `@problems`, `@changes` mentions into attachments.
@MainActor
struct ContextResolver {
    let workspace: ProjectWorkspace
    let editor: EditorCoordinator
    var session: AgentSession? = nil

    func resolve(_ text: String) -> (String, [ContextAttachment]) {
        var attachments: [ContextAttachment] = []
        let mentions = text.matches(of: #/(?:^|[^\w@])@([\w.\/\-]+)/#).map { String($0.output.1) }
        for m in Set(mentions) {
            switch m {
            case "selection":
                if let s = editor.selection { attachments.append(.init(label: "@selection", body: s.text)) }
            case "terminal":
                if let out = session?.terminals.recentOutput, !out.isEmpty { attachments.append(.init(label: "@terminal", body: out)) }
            case "problems":
                if let problems = session?.problems, !problems.isEmpty {
                    let body = problems.map { "\($0.path):\($0.line)\($0.column.map { ":\($0)" } ?? ""): \($0.severity.rawValue): \($0.message) [\($0.source)]" }.joined(separator: "\n")
                    attachments.append(.init(label: "@problems", body: body))
                }
            case "changes":
                if let files = session?.changedFiles, !files.isEmpty { attachments.append(.init(label: "@changes", body: files.joined(separator: "\n"))) }
            default:
                let url = workspace.root.appendingPathComponent(m)
                if workspace.files.isDirectory(url) {
                    let listing = workspace.tree.children(of: url).map { $0.name + ($0.isDirectory ? "/" : "") }.joined(separator: "\n")
                    attachments.append(.init(label: "@\(m)", body: listing))
                } else if let body = try? workspace.files.readTextForAgent(url) {
                    attachments.append(.init(label: "@\(m)", body: String(body.prefix(40_000))))
                }
            }
        }
        return (text, attachments)
    }
}


/// One row in the composer's `/` or `@` suggestion list.
enum ComposerSuggestion: Identifiable {
    case skill(Skill)
    case mention(token: String, title: String, icon: String, subtitle: String)

    var id: String {
        switch self {
        case .skill(let s): "skill:\(s.id)"
        case .mention(let token, _, _, _): "mention:\(token)"
        }
    }
    var title: String {
        switch self {
        case .skill(let s): "/\(s.name)"
        case .mention(_, let t, _, _): t
        }
    }
    var subtitle: String {
        switch self {
        case .skill(let s): s.description
        case .mention(_, _, _, let sub): sub
        }
    }
    var icon: String {
        switch self {
        case .skill: "wand.and.stars"
        case .mention(_, _, let i, _): i
        }
    }
}
