import Foundation
import Observation

/// Live state for one open project window: file tree, open documents, watcher.
@MainActor
@Observable
public final class ProjectWorkspace {
    public let ref: ProjectRef
    public let files: FileService
    public let tree: FileTree
    public private(set) var ignore: IgnoreRules

    public private(set) var documents: [TextDocument] = []
    public var activeDocumentID: UUID?

    /// Last error worth surfacing to the user (file ops, saves).
    public var lastError: String?

    /// Incremented by menu commands that want a terminal; the window observes it.
    public private(set) var terminalRequests = 0
    public func requestTerminal() { terminalRequests += 1 }

    private var watcher: FileWatcher?
    private var watchTask: Task<Void, Never>?

    public init(ref: ProjectRef) {
        let rules = IgnoreRules.load(root: ref.url)
        self.ref = ref
        self.files = FileService(root: ref.url)
        self.ignore = rules
        self.tree = FileTree(root: ref.url, ignore: rules)
    }

    public var root: URL { ref.url }

    public var activeDocument: TextDocument? {
        guard let id = activeDocumentID else { return nil }
        return documents.first { $0.id == id }
    }

    public var hasUnsavedChanges: Bool { documents.contains { $0.isDirty } }

    // MARK: Lifecycle

    public func start() {
        guard watcher == nil else { return }
        let w = FileWatcher(root: root)
        watcher = w
        w.start()
        watchTask = Task { [weak self] in
            for await batch in w.events {
                guard let self else { return }
                self.handle(batch)
            }
        }
    }

    public func stop() {
        watchTask?.cancel()
        watchTask = nil
        watcher?.stop()
        watcher = nil
    }

    // MARK: Documents

    @discardableResult
    public func open(_ url: URL) -> TextDocument? {
        if let existing = documents.first(where: { $0.url == url }) {
            activeDocumentID = existing.id
            return existing
        }
        do {
            let text = try files.readText(url)
            let doc = TextDocument(url: url, text: text)
            documents.append(doc)
            activeDocumentID = doc.id
            return doc
        } catch {
            lastError = error.localizedDescription
            return nil
        }
    }

    /// Closes a tab immediately, discarding unsaved edits. User-facing close goes through `requestClose`.
    public func close(_ id: UUID) {
        guard let index = documents.firstIndex(where: { $0.id == id }) else { return }
        documents.remove(at: index)
        if activeDocumentID == id {
            activeDocumentID = documents.indices.contains(index) ? documents[index].id : documents.last?.id
        }
    }

    public enum CloseChoice: Sendable { case save, discard, cancel }

    /// A tab the user asked to close while it had unsaved edits. The window asks Save / Don't Save / Cancel.
    public var closeRequest: UUID?

    /// Closes the tab, or asks first when it has unsaved edits.
    public func requestClose(_ id: UUID) {
        guard let doc = documents.first(where: { $0.id == id }) else { return }
        if doc.isDirty { closeRequest = id } else { close(id) }
    }

    /// Answers the pending close request. A save that fails keeps the tab open.
    public func resolveClose(_ choice: CloseChoice) {
        guard let id = closeRequest else { return }
        closeRequest = nil
        switch choice {
        case .cancel:
            return
        case .discard:
            close(id)
        case .save:
            save(id)
            if documents.first(where: { $0.id == id })?.isDirty == false { close(id) }
        }
    }

    public func save(_ id: UUID) {
        guard let doc = documents.first(where: { $0.id == id }) else { return }
        do {
            try files.writeText(doc.text, to: doc.url)
            doc.markSaved()
        } catch {
            lastError = error.localizedDescription
        }
    }

    public func saveAll() {
        for doc in documents where doc.isDirty { save(doc.id) }
    }

    /// Reloads the document for `url` from disk if it is open and clean; flags it otherwise.
    public func refreshFromDisk(_ url: URL) {
        guard let doc = documents.first(where: { $0.url == url }) else { return }
        guard let text = try? files.readText(url), text != doc.savedText else { return }
        if doc.isDirty {
            doc.hasExternalChange = true
        } else {
            doc.reload(text: text)
        }
    }

    // MARK: Explorer operations

    public func createFile(in directory: URL, name: String) {
        perform { try files.createFile(at: directory.appendingPathComponent(name)) }
        tree.invalidate([directory])
    }

    public func createDirectory(in directory: URL, name: String) {
        perform { try files.createDirectory(at: directory.appendingPathComponent(name)) }
        tree.invalidate([directory])
        tree.setExpanded(directory, true)
    }

    public func rename(_ url: URL, to name: String) {
        perform {
            let newURL = try files.rename(url, to: name)
            rebind(from: url, to: newURL)
        }
        tree.invalidate([url.deletingLastPathComponent()], recursive: true)
    }

    public func move(_ url: URL, into directory: URL) {
        let destination = directory.appendingPathComponent(url.lastPathComponent)
        guard destination != url, !destination.path.hasPrefix(url.path + "/") else { return }
        perform {
            try files.move(url, to: destination)
            rebind(from: url, to: destination)
        }
        tree.invalidate([url.deletingLastPathComponent(), directory], recursive: true)
    }

    public func duplicate(_ url: URL) {
        perform { try files.duplicate(url) }
        tree.invalidate([url.deletingLastPathComponent()])
    }

    public func trash(_ url: URL) {
        perform { try files.trash(url) }
        for doc in documents where doc.url == url || doc.url.path.hasPrefix(url.path + "/") {
            close(doc.id)
        }
        tree.invalidate([url.deletingLastPathComponent()], recursive: true)
    }

    // MARK: Private

    private func perform(_ op: () throws -> Void) {
        do { try op() } catch { lastError = error.localizedDescription }
    }

    /// Repoints open documents after a rename/move so tabs stay attached.
    private func rebind(from old: URL, to new: URL) {
        for (i, doc) in documents.enumerated() {
            let path = doc.url.path
            let mapped: URL?
            if path == old.path { mapped = new }
            else if path.hasPrefix(old.path + "/") { mapped = new.appendingPathComponent(String(path.dropFirst(old.path.count + 1))) }
            else { mapped = nil }
            guard let mapped else { continue }
            // Seed with the saved text so unsaved edits stay dirty after the move.
            let replacement = TextDocument(url: mapped, text: doc.savedText)
            if doc.isDirty { replacement.text = doc.text }
            documents[i] = replacement
            if activeDocumentID == doc.id { activeDocumentID = replacement.id }
        }
    }

    private func handle(_ batch: [FileEvent]) {
        var dirs = Set<URL>()
        for event in batch {
            let parent = event.isDirectory ? event.url : event.url.deletingLastPathComponent()
            dirs.insert(parent)
            dirs.insert(event.url.deletingLastPathComponent())
            if !event.isDirectory { refreshFromDisk(event.url) }
            if event.url.lastPathComponent == ".gitignore", event.url.deletingLastPathComponent() == root {
                ignore = IgnoreRules.load(root: root)
                tree.updateIgnoreRules(ignore)
            }
        }
        tree.invalidate(Array(dirs), recursive: true)
    }
}
