import HarnessAgent
import HarnessCore
import HarnessEditor
import Observation
import SwiftUI

/// PRD §16 — a focused diff experience opened from the completion card / changes chip.
/// Original = the file's task-start checkpoint; modified = current disk. Accept keeps the
/// change and drops the file from the pending set; reject reverts the file to its checkpoint.
/// Individual hunks can be reverted, and edits typed into the modified pane are saved to disk.
public struct DiffReviewView: View {
    @State private var model: DiffReviewModel
    @Environment(\.dismiss) private var dismiss

    public init(session: AgentSession) {
        _model = State(initialValue: DiffReviewModel(session: session))
    }

    public var body: some View {
        NavigationSplitView {
            List(model.files, id: \.self, selection: $model.selected) { path in
                Label(path, systemImage: FileIcon.symbol(for: path))
                    .lineLimit(1).help(path)
            }
            .navigationSplitViewColumnWidth(min: 200, ideal: 260, max: 380)
        } detail: {
            VStack(spacing: 0) {
                if let selected = model.selected {
                    HStack {
                        Text(selected).font(.callout).lineLimit(1)
                        Spacer()
                        Button("Reject File", role: .destructive) { Task { await reject(selected) } }
                        Button("Accept File") { accept(selected) }
                    }
                    .padding(.horizontal, 12).frame(height: 36).background(.bar)
                    Divider()
                    MonacoEditorView(controller: model.monaco)
                    Divider()
                    hunkStrip.frame(height: 132)   // explicit height: no competing flexible frames
                } else {
                    ContentUnavailableView("No changes to review", systemImage: "checkmark.circle")
                }
            }
        }
        .frame(minWidth: 900, minHeight: 560)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Close") { model.flush(); dismiss() } }
            ToolbarItemGroup(placement: .confirmationAction) {
                Button("Reject All", role: .destructive) { Task { await rejectAll() } }
                Button("Accept All") { acceptAll() }
            }
        }
        .task { await model.load() }
        .onChange(of: model.selected) { _, path in model.select(path) }
        .onDisappear { model.flush() }
    }

    // MARK: Hunks

    /// Compact list of the selected file's hunks, each with a Revert (PRD §16 "accept individual change").
    private var hunkStrip: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Text(hunkSummary).font(.caption).foregroundStyle(.secondary)
                Spacer()
                if let error = model.saveError {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .font(.caption).foregroundStyle(.orange).lineLimit(1).help(error)
                } else {
                    Text(model.hasUnsavedEdits ? "Saving…" : "Edits in the right pane are saved to disk.")
                        .font(.caption).foregroundStyle(.tertiary)
                }
            }
            .padding(.horizontal, 12).frame(height: 24)
            Divider()
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(model.hunks, id: \.index) { hunk in
                        HStack {
                            Text(Self.describe(hunk)).font(.caption.monospacedDigit()).lineLimit(1)
                            Spacer()
                            Button("Revert") { model.revert(hunk) }
                                .controlSize(.small)
                                .help("Restore the original text for this change and save the file")
                        }
                        .padding(.horizontal, 12).padding(.vertical, 2)
                        Divider()
                    }
                }
            }
        }
        .background(.bar)
    }

    private var hunkSummary: String {
        if model.hunks.isEmpty { return model.hunksLoading ? "Computing changes…" : "No remaining differences" }
        return "\(model.hunks.count) change\(model.hunks.count == 1 ? "" : "s")"
    }

    /// Human-readable hunk label. Monaco reports `0` as the end line for an empty side.
    static func describe(_ h: DiffHunk) -> String {
        func lines(_ a: Int, _ b: Int) -> String { a == b ? "line \(a)" : "lines \(a)–\(b)" }
        if h.originalEnd == 0 { return "Added \(lines(h.modifiedStart, h.modifiedEnd))" }
        if h.modifiedEnd == 0 { return "Removed \(lines(h.originalStart, h.originalEnd)) (after line \(h.modifiedStart))" }
        return "Changed \(lines(h.modifiedStart, h.modifiedEnd)) (was \(lines(h.originalStart, h.originalEnd)))"
    }

    // MARK: Actions

    private func accept(_ path: String) {
        model.accept(path)
        advance(after: path)
    }

    private func reject(_ path: String) async {
        await model.reject(path)
        advance(after: path)
    }

    private func acceptAll() {
        model.acceptAll()
        dismiss()
    }

    private func rejectAll() async {
        await model.rejectAll()
        dismiss()
    }

    private func advance(after path: String) {
        model.files.removeAll { $0 == path }
        if model.files.isEmpty { dismiss() } else { model.selected = model.files.first }
    }
}

/// State behind `DiffReviewView`: the Monaco diff controller, the per-file originals, the current
/// hunk list, and the write-back of edits made in the modified pane.
@MainActor
@Observable
final class DiffReviewModel {
    let session: AgentSession
    let monaco = MonacoController()

    var files: [String] = []
    var selected: String?
    var hunks: [DiffHunk] = []
    var hunksLoading = false
    var hasUnsavedEdits = false
    var saveError: String?

    @ObservationIgnored private var originals: [String: String] = [:]
    /// Text last shown in / received from the modified pane, per path — lets us ignore echoes.
    @ObservationIgnored private var shown: [String: String] = [:]
    @ObservationIgnored private var pendingWrite: (path: String, text: String)?
    @ObservationIgnored private var writeTask: Task<Void, Never>?
    @ObservationIgnored private var hunkTask: Task<Void, Never>?

    init(session: AgentSession) {
        self.session = session
        monaco.onEvent = { [weak self] event in self?.handle(event) }
    }

    private func url(_ path: String) -> URL { session.workspace.root.appendingPathComponent(path) }

    /// Files still pending review: the task's change set, restricted to paths with a checkpoint.
    func load() async {
        guard let taskID = session.currentTaskID else { return }
        let checkpointed = Set(await session.checkpoints.changedPaths(taskID: taskID))
        let pending = session.changedFiles.filter(checkpointed.contains)
        for path in pending {
            originals[path] = await session.checkpoints.original(of: url(path), taskID: taskID) ?? ""
        }
        files = pending
        selected = pending.first
    }

    /// Shows `path` in the diff editor; any unsaved edit to the previous file is written first.
    func select(_ path: String?) {
        flush()
        hunks = []
        saveError = nil
        guard let path else { return }
        let modified = (try? session.workspace.files.readText(url(path))) ?? ""
        shown[path] = modified
        monaco.showDiff(id: path, path: path, original: originals[path] ?? "", modified: modified)
        refreshHunks()
    }

    // MARK: Hunks

    private func refreshHunks() {
        hunkTask?.cancel()
        hunkTask = Task { [weak self] in
            guard let self else { return }
            hunksLoading = true
            defer { hunksLoading = false }
            do {
                let fresh = try await monaco.diffHunks()
                if !Task.isCancelled { hunks = fresh }
            } catch {
                if !Task.isCancelled { hunks = [] }
            }
        }
    }

    /// Reverts one hunk in the modified pane. The resulting `contentChanged` event writes the
    /// file back to disk and refreshes the hunk list.
    func revert(_ hunk: DiffHunk) {
        Task { [weak self] in
            guard let self else { return }
            do {
                if try await monaco.applyHunk(index: hunk.index, direction: .revert) == false {
                    saveError = "Couldn't revert that change — the diff moved; try again."
                    refreshHunks()
                }
            } catch {
                saveError = "Couldn't revert that change: \(error.localizedDescription)"
            }
        }
    }

    // MARK: Write-back of manual edits

    private func handle(_ event: MonacoEvent) {
        guard case let .contentChanged(id, _, text) = event, id == selected, shown[id] != text else { return }
        shown[id] = text
        scheduleWrite(path: id, text: text)
        refreshHunks()
    }

    private func scheduleWrite(path: String, text: String) {
        pendingWrite = (path, text)
        hasUnsavedEdits = true
        writeTask?.cancel()
        writeTask = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(300)) } catch { return }   // superseded
            self?.flush()
        }
    }

    /// Writes any debounced edit now (file switch, accept, close).
    func flush() {
        writeTask?.cancel()
        writeTask = nil
        guard let (path, text) = pendingWrite else { return }
        pendingWrite = nil
        hasUnsavedEdits = false
        let target = url(path)
        do {
            try session.workspace.files.writeText(text, to: target)
            session.workspace.refreshFromDisk(target)   // open editor tab follows (or is flagged if dirty)
            saveError = nil
        } catch {
            saveError = "Couldn't save \(path): \(error.localizedDescription)"
        }
    }

    private func discardPending() {
        writeTask?.cancel()
        writeTask = nil
        pendingWrite = nil
        hasUnsavedEdits = false
    }

    // MARK: Accept / reject

    func accept(_ path: String) {
        flush()
        session.markReviewed([path])
    }

    func reject(_ path: String) async {
        discardPending()
        await session.revertFile(path)
    }

    func acceptAll() {
        flush()
        session.markReviewed(files)
    }

    func rejectAll() async {
        discardPending()
        await session.undoTask()
    }
}
