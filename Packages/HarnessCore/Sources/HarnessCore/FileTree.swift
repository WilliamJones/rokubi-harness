import Foundation
import Observation

/// One entry in the project explorer.
public struct FileNode: Identifiable, Hashable, Sendable {
    public let url: URL
    public let name: String
    public let isDirectory: Bool

    public var id: String { url.path }

    public init(url: URL, isDirectory: Bool) {
        self.url = url
        self.name = url.lastPathComponent
        self.isDirectory = isDirectory
    }
}

/// Lazily-loaded directory tree rooted at a project folder.
/// Children are read on first access and dropped again by `invalidate`.
@MainActor
@Observable
public final class FileTree {
    public let root: URL
    public var expanded: Set<String> = []

    /// Bumped on every invalidation; views read it to re-render after lazy reloads.
    public private(set) var version = 0

    @ObservationIgnored private var ignore: IgnoreRules
    // Ignored so that lazy loads during view rendering don't count as mutations.
    @ObservationIgnored private var cache: [String: [FileNode]] = [:]

    public init(root: URL, ignore: IgnoreRules) {
        self.root = root
        self.ignore = ignore
        expanded.insert(root.path)
    }

    public func children(of directory: URL) -> [FileNode] {
        if let cached = cache[directory.path] { return cached }
        let nodes = load(directory)
        cache[directory.path] = nodes
        return nodes
    }

    public func isExpanded(_ url: URL) -> Bool { expanded.contains(url.path) }

    public func setExpanded(_ url: URL, _ value: Bool) {
        if value { expanded.insert(url.path) } else { expanded.remove(url.path) }
    }

    /// Forgets cached listings for `directories` (and, when `recursive`, everything below them).
    public func invalidate(_ directories: [URL], recursive: Bool = false) {
        for dir in directories {
            cache[dir.path] = nil
            if recursive {
                let prefix = dir.path + "/"
                for key in cache.keys where key.hasPrefix(prefix) { cache[key] = nil }
            }
        }
        version += 1
    }

    public func invalidateAll() {
        cache.removeAll()
        version += 1
    }

    public func updateIgnoreRules(_ rules: IgnoreRules) {
        ignore = rules
        invalidateAll()
    }

    private func load(_ directory: URL) -> [FileNode] {
        let keys: [URLResourceKey] = [.isDirectoryKey, .isSymbolicLinkKey]
        guard let urls = try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: keys, options: []
        ) else { return [] }

        let rootPath = root.path
        var nodes: [FileNode] = []
        for url in urls {
            let values = try? url.resourceValues(forKeys: Set(keys))
            let isDir = values?.isDirectory ?? false
            let rel = String(url.path.dropFirst(rootPath.count + 1))
            if ignore.isIgnored(relativePath: rel, isDirectory: isDir) { continue }
            nodes.append(FileNode(url: url, isDirectory: isDir))
        }
        return nodes.sorted { a, b in
            if a.isDirectory != b.isDirectory { return a.isDirectory }
            return a.name.localizedStandardCompare(b.name) == .orderedAscending
        }
    }
}
