import Foundation
import Observation

/// Most-recently-opened projects, persisted as file bookmarks in `UserDefaults`.
@MainActor
@Observable
public final class RecentProjects {
    public static let shared = RecentProjects()

    public private(set) var projects: [ProjectRef] = []

    private let defaults: UserDefaults
    private let key = "recentProjects.bookmarks"
    private let limit = 12

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        load()
    }

    /// Moves `ref` to the front of the list (adding it if new) and persists.
    public func touch(_ ref: ProjectRef) {
        projects.removeAll { $0 == ref }
        projects.insert(ref, at: 0)
        if projects.count > limit { projects.removeLast(projects.count - limit) }
        save()
    }

    public func remove(_ ref: ProjectRef) {
        projects.removeAll { $0 == ref }
        save()
    }

    public func clear() {
        projects.removeAll()
        save()
    }

    private func load() {
        guard let blobs = defaults.array(forKey: key) as? [Data] else { return }
        projects = blobs.compactMap { data in
            var stale = false
            guard let url = try? URL(resolvingBookmarkData: data, options: [.withoutUI], bookmarkDataIsStale: &stale),
                  FileManager.default.fileExists(atPath: url.path)
            else { return nil }
            return ProjectRef(url: url)
        }
    }

    private func save() {
        let blobs = projects.compactMap { try? $0.url.bookmarkData(options: [.minimalBookmark]) }
        defaults.set(blobs, forKey: key)
    }
}
