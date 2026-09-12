import Foundation
import HarnessCore
import HarnessEditor
import Observation

/// Keeps the Monaco web view in step with `ProjectWorkspace.documents`.
///
/// Documents flow Swift → Monaco on open/activate/disk reload, and Monaco → Swift
/// on every content change (debounced in JS). `TextDocument.text` is authoritative.
@MainActor
@Observable
public final class EditorCoordinator {
    public let workspace: ProjectWorkspace
    public let monaco = MonacoController()

    /// Current selection in the active document, for `@selection` context.
    public private(set) var selection: Selection?
    public private(set) var cursor: (line: Int, column: Int) = (1, 1)

    public struct Selection: Sendable, Hashable {
        public let documentID: UUID
        public let range: EditorTextRange
        public let text: String
    }

    @ObservationIgnored private var opened: [UUID: Int] = [:]   // doc id → diskVersion pushed
    /// Diagnostics to show as Monaco markers, keyed by project-relative path.
    public var problems: [Problem] = [] { didSet { applyMarkers() } }

    public init(workspace: ProjectWorkspace) {
        self.workspace = workspace
        monaco.onEvent = { [weak self] event in self?.handle(event) }
    }

    /// Hashable snapshot of everything that should trigger a `sync()`.
    public var syncKey: SyncKey {
        SyncKey(active: workspace.activeDocumentID,
                docs: workspace.documents.map { .init(id: $0.id, diskVersion: $0.diskVersion) })
    }

    public struct SyncKey: Hashable, Sendable {
        public struct Doc: Hashable, Sendable { let id: UUID; let diskVersion: Int }
        let active: UUID?
        let docs: [Doc]
    }

    /// Reconciles open Monaco models with the workspace's documents.
    public func sync() {
        let live = Set(workspace.documents.map(\.id))
        for id in opened.keys where !live.contains(id) {
            monaco.closeModel(id: id.uuidString)
            opened[id] = nil
        }
        for doc in workspace.documents {
            if let pushed = opened[doc.id] {
                if pushed != doc.diskVersion {
                    monaco.setContent(id: doc.id.uuidString, text: doc.text)
                    opened[doc.id] = doc.diskVersion
                }
            } else if doc.id == workspace.activeDocumentID {
                monaco.openModel(id: doc.id.uuidString, path: doc.url.path, text: doc.text)
                opened[doc.id] = doc.diskVersion
            }
        }
        if let active = workspace.activeDocument {
            if opened[active.id] == nil {
                monaco.openModel(id: active.id.uuidString, path: active.url.path, text: active.text)
                opened[active.id] = active.diskVersion
            } else {
                monaco.activate(id: active.id.uuidString)
            }
        }
        if !problems.isEmpty { applyMarkers() }
    }

    public func applyMarkers() {
        for doc in workspace.documents where opened[doc.id] != nil {
            let rel = workspace.files.relativePath(doc.url)
            let markers = problems.filter { $0.path == rel || doc.url.path.hasSuffix("/" + $0.path) }.map {
                MonacoMarker(line: max(1, $0.line), column: $0.column ?? 1, message: $0.message,
                             severity: $0.severity == .error ? .error : $0.severity == .warning ? .warning : .info, source: $0.source)
            }
            monaco.setMarkers(id: doc.id.uuidString, markers)
        }
    }

    public func reveal(_ url: URL, line: Int, column: Int = 1) {
        guard let doc = workspace.open(url) else { return }
        sync()
        monaco.revealLine(id: doc.id.uuidString, line: line, column: column)
    }

    public func runAction(_ action: String) { monaco.runAction(action) }

    private func handle(_ event: MonacoEvent) {
        switch event {
        case .ready:
            opened.removeAll()
            sync()
        case let .contentChanged(id, _, text):
            guard let uuid = UUID(uuidString: id),
                  let doc = workspace.documents.first(where: { $0.id == uuid }) else { return }
            if doc.text != text { doc.text = text }
        case let .selectionChanged(id, range, text):
            guard let uuid = UUID(uuidString: id) else { return }
            selection = range.isEmpty ? nil : Selection(documentID: uuid, range: range, text: text)
        case let .cursor(_, line, column):
            cursor = (line, column)
        case let .save(id):
            guard let uuid = UUID(uuidString: id) else { return }
            workspace.save(uuid)
        case let .log(level, message):
            NSLog("[Monaco:\(level)] \(message)")
        }
    }
}
