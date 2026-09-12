import Foundation
import Observation

/// An open editor buffer. `text` is the live content; `savedText` mirrors disk.
@MainActor
@Observable
public final class TextDocument: Identifiable {
    public let id: UUID
    public let url: URL
    public var text: String
    public private(set) var savedText: String

    /// Incremented whenever the buffer is replaced from disk so the editor can resync.
    public private(set) var diskVersion = 0

    /// Set when the file changed on disk while the buffer had unsaved edits.
    public var hasExternalChange = false

    public var isDirty: Bool { text != savedText }
    public var name: String { url.lastPathComponent }

    public init(url: URL, text: String) {
        self.id = UUID()
        self.url = url
        self.text = text
        self.savedText = text
    }

    public func markSaved() {
        savedText = text
        hasExternalChange = false
    }

    /// Replaces both buffer and saved text with fresh disk contents.
    public func reload(text newText: String) {
        text = newText
        savedText = newText
        hasExternalChange = false
        diskVersion += 1
    }
}
