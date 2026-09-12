import Foundation

/// A reference to an opened project folder. Used as the `WindowGroup` value so
/// each project gets its own window and can be restored on relaunch.
public struct ProjectRef: Codable, Hashable, Sendable, Identifiable {
    public let url: URL

    public init(url: URL) {
        self.url = url.standardizedFileURL
    }

    public var id: String { url.path }
    public var name: String { url.lastPathComponent }
}
