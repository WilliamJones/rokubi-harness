import Foundation
import HarnessAgent
import HarnessCore
import HarnessTerminal
import Observation

/// Per-window agent state: the current conversation, live streaming output, tools,
/// permissions, checkpoints, and the bridge from `AgentEvent`s to observable UI state.
@MainActor
@Observable
public final class AgentSession {
    public let workspace: ProjectWorkspace
    public let store: ConversationStore
    public let checkpoints: CheckpointStore
    public let terminals: TerminalManager
    public private(set) var conversation: Conversation
    public private(set) var isRunning = false
    public var autonomy: AutonomyPreset = .standard {
        didSet { UserDefaults.standard.set(autonomy.rawValue, forKey: "autonomy.preset") }
    }

    /// Text still streaming for assistant message items, keyed by item id.
    public private(set) var streamingText: [String: String] = [:]
    public private(set) var streamingOrder: [String] = []
    /// Live activity rows for the current turn, keyed by call id.
    public private(set) var liveActivity: [String: ActivityRecord] = [:]
    public private(set) var liveActivityOrder: [String] = []
    public private(set) var reasoningPreview = ""
    public var lastError: String?

    // Contextual surfaces (PRD §11) — empty means hidden.
    public private(set) var plan: [PlanStep] = []
    public private(set) var completion: CompletionReport?
    public private(set) var pendingPermission: PermissionRequest?
    /// Project-relative paths touched by the current/last task, in first-touched order.
    public private(set) var changedFiles: [String] = []
    public private(set) var currentTaskID: String?
    /// Diagnostics parsed from the most recent command output (PRD §24). Empty = hidden.
    public var problems: [Problem] = []
    /// Which command produced each problem, so a clean re-run of that command clears it.
    @ObservationIgnored private var problemCommands: [Problem.ID: String] = [:]
    /// Bumped on any transcript change; the chat view keys its auto-scroll on this.
    public private(set) var contentRevision = 0

    /// Supplied by the editor so `@selection` and "current file" context work.
    public var currentFile: (() -> String?)?
    public var currentSelection: (() -> String?)?

    @ObservationIgnored private var orchestrator: AgentOrchestrator?
    @ObservationIgnored private var runTask: Task<Void, Never>?
    @ObservationIgnored private var permissionContinuation: CheckedContinuation<PermissionEngine.AskResponse, Never>?
    @ObservationIgnored private var extraTools: [any Tool] = GitTools.all()
    @ObservationIgnored public private(set) lazy var skills = SkillStore(projectRoot: workspace.root)
    /// Model used for the previous turn, so a switch is called out in the transcript.
    @ObservationIgnored private var lastModelID: String?

    public init(workspace: ProjectWorkspace) {
        self.workspace = workspace
        self.store = ConversationStore(projectRoot: workspace.root)
        self.checkpoints = CheckpointStore(projectRoot: workspace.root)
        self.terminals = TerminalManager(cwd: workspace.root)
        if let raw = UserDefaults.standard.string(forKey: "autonomy.preset"), let p = AutonomyPreset(rawValue: raw) { autonomy = p }
        if let latest = store.summaries.first, let c = store.load(id: latest.id) {
            conversation = c
        } else {
            conversation = Conversation()
        }
        let root = workspace.root
        Task.detached(priority: .utility) { [weak self] in
            let isRepo = GitService(root: root).isRepository
            await MainActor.run { self?.isGitRepository = isRepo }
        }
    }

    /// Adds tools on top of the defaults and the git tools; the orchestrator is rebuilt on the next turn.
    public func register(tools: [any Tool]) {
        extraTools += tools
        orchestrator = nil
    }

    // MARK: Conversations

    public func newConversation() {
        guard !isRunning else { return }
        store.save(conversation)
        conversation = Conversation()
        clearLiveState()
        plan = []; completion = nil; changedFiles = []; currentTaskID = nil
    }

    public func open(conversationID: String) {
        guard !isRunning, let c = store.load(id: conversationID) else { return }
        store.save(conversation)
        conversation = c
        clearLiveState()
        plan = []; completion = nil; changedFiles = []; currentTaskID = nil
    }

    public func delete(conversationID: String) {
        store.delete(id: conversationID)
        if conversation.id == conversationID { conversation = Conversation(); clearLiveState() }
    }

    // MARK: Turns

    public func send(_ text: String, attachments: [ContextAttachment], auth: AuthSession, model: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !isRunning else { return }
        guard let provider = auth.provider else { lastError = AuthError.notSignedIn.localizedDescription; return }

        if let previous = lastModelID, previous != model, !conversation.isEmpty {
            conversation.append(.note(id: UUID().uuidString, text: "Now using \(model) — earlier replies were from \(previous)."))
        }
        lastModelID = model
        let (expanded, usedSkill) = skills.expand(trimmed)
        conversation.append(.user(id: UUID().uuidString, text: expanded, context: attachments))
        if let usedSkill { conversation.append(.note(id: UUID().uuidString, text: "Ran /\(usedSkill)")) }
        store.save(conversation)
        clearLiveState()
        completion = nil
        isRunning = true
        lastError = nil

        // A task = one user turn; checkpoints and the change set are scoped to it.
        let taskID = UUID().uuidString
        currentTaskID = taskID
        changedFiles = []

        let tools = ToolFactory.defaultTools(executor: TerminalExecutor(runner: CommandRunner(terminals: terminals)), extra: extraTools)
        let policy = PermissionPolicy(preset: autonomy, project: PermissionPolicy.loadProjectRules(root: workspace.root))
        let gate = PermissionEngine(policy: policy) { [weak self] request in
            await self?.ask(request) ?? .deny
        }
        // Pick the client for the active provider's API, and rebuild each turn so switching
        // provider or model mid-session takes effect immediately.
        let client: any LLMClient = provider.api == .chatCompletions
            ? ChatCompletionsClient(auth: provider)
            : ResponsesClient(auth: provider)
        let orchestrator = AgentOrchestrator(client: client, tools: tools, gate: gate)
        self.orchestrator = orchestrator

        let ignore = IgnoreRules.load(root: workspace.root, defaults: IgnoreRules.searchDefaults)
        let assembler = ContextAssembler(
            files: workspace.files, ignore: ignore,
            autonomySummary: "\(autonomy.title) — \(autonomy.summary)",
            currentFile: currentFile?(), selection: currentSelection?(),
            modelName: model, providerName: AssistantIdentity.providerName(for: auth.account?.mode)
        )
        let context = ToolContext(files: workspace.files, ignore: ignore, checkpoints: checkpoints,
                                  sink: SessionSink(session: self), conversationID: conversation.id, taskID: taskID)
        let snapshot = conversation
        let instructions = assembler.instructions()

        runTask = Task { [weak self] in
            await orchestrator.update(tools: tools, gate: gate)
            await self?.checkpoints.beginTask(id: taskID)
            let events = await orchestrator.run(conversation: snapshot, instructions: instructions,
                                                configuration: .init(model: model), context: context)
            for await event in events {
                guard let self else { return }
                self.handle(event)
            }
            self?.finishRun()
        }
    }

    public func cancel() {
        runTask?.cancel()
        permissionContinuation?.resume(returning: .deny)
        permissionContinuation = nil
        pendingPermission = nil
        Task { await orchestrator?.cancel() }
    }

    // MARK: Permissions (inline approval, PRD §18)

    private func ask(_ request: PermissionRequest) async -> PermissionEngine.AskResponse {
        pendingPermission = request
        return await withCheckedContinuation { continuation in
            permissionContinuation = continuation
        }
    }

    public func respond(_ response: PermissionEngine.AskResponse) {
        pendingPermission = nil
        permissionContinuation?.resume(returning: response)
        permissionContinuation = nil
    }

    // MARK: Git (PRD §23)

    /// Computed once, off the main thread, right after init — reading it in a view body is then a
    /// plain observable read (a lazy var here initialized *during* body and spawned `git` mid-render).
    public private(set) var isGitRepository = false

    /// Stages all changes and commits — the human action from the completion card.
    public func commitChanges(_ message: String) {
        let git = GitService(root: workspace.root)
        do {
            if !git.isRepository { lastError = "This project is not a git repository."; return }
            try git.stageAll()
            let subject = message.split(whereSeparator: \.isNewline).first.map(String.init) ?? "Update"
            _ = try git.commit(message: subject)
            conversation.append(.note(id: UUID().uuidString, text: "Committed: \(subject)"))
            changedFiles = []
            store.save(conversation)
        } catch {
            lastError = "Commit failed: \(error.localizedDescription)"
        }
    }

    // MARK: Checkpoints (PRD §17)

    /// Restores every file the last task touched to its pre-task state.
    public func undoTask() async {
        guard let taskID = currentTaskID, !isRunning else { return }
        do {
            let restored = try await checkpoints.restoreTaskStart(taskID: taskID)
            for path in restored { workspace.refreshFromDisk(workspace.root.appendingPathComponent(path)) }
            workspace.tree.invalidateAll()
            conversation.append(.note(id: UUID().uuidString, text: "Undid task — restored \(restored.count) file\(restored.count == 1 ? "" : "s")."))
            changedFiles = []
            completion = nil
            store.save(conversation)
        } catch {
            lastError = "Undo failed: \(error.localizedDescription)"
        }
    }

    /// PRD §16 accept — the user has reviewed these files and is keeping what's on disk, so
    /// they leave the pending change set (the "N files changed" chip / completion card).
    public func markReviewed(_ paths: [String]) {
        let done = Set(paths)
        changedFiles.removeAll { done.contains($0) }
    }

    public func revertFile(_ path: String) async {
        guard let taskID = currentTaskID else { return }
        let url = workspace.root.appendingPathComponent(path)
        try? await checkpoints.revertFile(url, taskID: taskID)
        workspace.refreshFromDisk(url)
        workspace.tree.invalidate([url.deletingLastPathComponent()])
        changedFiles.removeAll { $0 == path }
    }

    // MARK: Event handling

    private func handle(_ event: AgentEvent) {
        contentRevision &+= 1
        switch event {
        case .turnStarted:
            break
        case let .assistantTextDelta(itemID, delta):
            if streamingText[itemID] == nil { streamingOrder.append(itemID) }
            streamingText[itemID, default: ""] += delta
        case let .reasoningDelta(_, delta):
            reasoningPreview += delta
        case let .activityStarted(callID, activity):
            if liveActivity[callID] == nil { liveActivityOrder.append(callID) }
            liveActivity[callID] = activity
        case let .activityFinished(callID, activity):
            liveActivity[callID] = activity
        case .permissionRequested:
            break
        case .entryAppended(let entry):
            conversation.append(entry)
            if case .assistant(let id, _) = entry {
                streamingText[id] = nil
                streamingOrder.removeAll { $0 == id }
            }
            if case .reasoning = entry { reasoningPreview = "" }
        case let .usage(input, output):
            conversation.totalInputTokens += input
            conversation.totalOutputTokens += output
        case .turnFinished(let outcome):
            if case .failed(let message) = outcome {
                lastError = message
                conversation.append(.note(id: UUID().uuidString, text: message))
            }
            if case .cancelled = outcome {
                conversation.append(.note(id: UUID().uuidString, text: "Stopped."))
            }
        }
    }

    private func finishRun() {
        isRunning = false
        runTask = nil
        streamingText.removeAll()
        streamingOrder.removeAll()
        reasoningPreview = ""
        pendingPermission = nil
        store.save(conversation)
    }

    private func clearLiveState() {
        streamingText.removeAll()
        streamingOrder.removeAll()
        liveActivity.removeAll()
        liveActivityOrder.removeAll()
        reasoningPreview = ""
    }

    // Sink callbacks (called from SessionSink on the main actor)
    fileprivate func planUpdated(_ steps: [PlanStep]) { plan = steps }
    fileprivate func completionReported(_ report: CompletionReport) {
        completion = report
        if plan.contains(where: { $0.status != .done && $0.status != .skipped }) {
            plan = plan.map { PlanStep(title: $0.title, status: $0.status == .pending || $0.status == .inProgress ? .done : $0.status) }
        }
    }
    fileprivate func diagnosticsReported(_ new: [Problem], source command: String) {
        // A command's output replaces whatever that same command reported last time (so a passing
        // re-run of `npm test` clears its failures) and findings from the same tool family; others are kept.
        let families = Set(new.map(\.source))
        problems = problems.filter { problemCommands[$0.id] != command && !families.contains($0.source) } + new
        for problem in new { problemCommands[problem.id] = command }
    }

    fileprivate func fileChanged(_ url: URL) {
        let rel = workspace.files.relativePath(url)
        if !changedFiles.contains(rel) { changedFiles.append(rel) }
        workspace.refreshFromDisk(url)
        workspace.tree.invalidate([url.deletingLastPathComponent()])
    }
}

/// Hops tool side effects onto the main actor.
private struct SessionSink: ToolEventSink {
    weak var session: AgentSession?

    init(session: AgentSession) { self.session = session }

    func planUpdated(_ steps: [PlanStep]) async { await MainActor.run { session?.planUpdated(steps) } }
    func completionReported(_ report: CompletionReport) async { await MainActor.run { session?.completionReported(report) } }
    func fileChanged(_ url: URL) async { await MainActor.run { session?.fileChanged(url) } }
    func diagnosticsReported(_ problems: [Problem], source: String) async {
        await MainActor.run { session?.diagnosticsReported(problems, source: source) }
    }
}

/// Bridges the main-actor `CommandRunner` into the `CommandExecutor` protocol used by tools.
private struct TerminalExecutor: CommandExecutor {
    let runner: CommandRunner

    func run(_ command: String, timeout: TimeInterval) async -> CommandResult {
        let r = await runner.run(command, timeout: timeout)
        return CommandResult(exitCode: r.exitCode, output: r.output, timedOut: r.timedOut, duration: r.duration)
    }
}
