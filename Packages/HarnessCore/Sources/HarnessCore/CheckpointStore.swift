import CryptoKit
import Foundation

/// PRD §17 — checkpoints independent of Git. Before an agent mutates a file we store
/// its current bytes (content-addressed) and record it in the task's manifest, so the
/// user can revert a file, undo the last action, or restore the task start.
public actor CheckpointStore {
    public struct Snapshot: Codable, Sendable, Equatable {
        public let path: String          // project-relative
        public let blob: String?         // sha256 of content; nil = file did not exist
        public let takenAt: Date
        public let label: String?        // tool call description
    }

    public struct TaskManifest: Codable, Sendable {
        public let id: String
        public let startedAt: Date
        /// First snapshot per path — the task-start state.
        public var initial: [String: Snapshot]
        /// Every snapshot in order — for "undo latest action".
        public var history: [Snapshot]
    }

    public let projectRoot: URL
    public let directory: URL
    private var manifests: [String: TaskManifest] = [:]

    public init(projectRoot: URL, baseDirectory: URL? = nil) {
        self.projectRoot = projectRoot.standardizedFileURL
        let hash = SHA256.hash(data: Data(self.projectRoot.path.utf8)).prefix(8).map { String(format: "%02x", $0) }.joined()
        let base = baseDirectory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ROKUBI Harness/projects/\(hash)")
        directory = base.appendingPathComponent("checkpoints", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory.appendingPathComponent("blobs"), withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: directory.appendingPathComponent("tasks"), withIntermediateDirectories: true)
    }

    // MARK: Recording

    public func beginTask(id: String) {
        guard manifests[id] == nil else { return }
        manifests[id] = TaskManifest(id: id, startedAt: Date(), initial: [:], history: [])
        persist(id)
    }

    /// Call before writing/deleting/renaming `url`. Cheap when unchanged (blobs are deduplicated).
    public func snapshot(_ url: URL, taskID: String, label: String? = nil) throws {
        if manifests[taskID] == nil { beginTask(id: taskID) }
        let rel = relative(url)
        var blob: String? = nil
        if let data = try? Data(contentsOf: url) {
            blob = try store(data)
        }
        let snap = Snapshot(path: rel, blob: blob, takenAt: Date(), label: label)
        if manifests[taskID]!.initial[rel] == nil { manifests[taskID]!.initial[rel] = snap }
        manifests[taskID]!.history.append(snap)
        persist(taskID)
    }

    // MARK: Querying

    public func manifest(taskID: String) -> TaskManifest? {
        manifests[taskID] ?? load(taskID)
    }

    /// Files touched during the task, in first-touched order.
    public func changedPaths(taskID: String) -> [String] {
        guard let m = manifest(taskID: taskID) else { return [] }
        var seen = Set<String>()
        return m.history.compactMap { seen.insert($0.path).inserted ? $0.path : nil }
    }

    /// Content of `url` when the task first touched it (nil if it did not exist then).
    public func original(of url: URL, taskID: String) -> String? {
        guard let snap = manifest(taskID: taskID)?.initial[relative(url)], let blob = snap.blob else { return nil }
        return read(blob).flatMap { String(data: $0, encoding: .utf8) }
    }

    public func hasCheckpoint(for url: URL, taskID: String) -> Bool {
        manifest(taskID: taskID)?.initial[relative(url)] != nil
    }

    // MARK: Restoring

    /// Puts every file the task touched back to its task-start state. Returns restored paths.
    @discardableResult
    public func restoreTaskStart(taskID: String) throws -> [String] {
        guard let m = manifest(taskID: taskID) else { return [] }
        for snap in m.initial.values { try restore(snap) }
        return Array(m.initial.keys).sorted()
    }

    /// Reverts one file to its task-start state.
    public func revertFile(_ url: URL, taskID: String) throws {
        guard let snap = manifest(taskID: taskID)?.initial[relative(url)] else { return }
        try restore(snap)
    }

    /// Restores the most recent snapshot (the state just before the last mutating action).
    @discardableResult
    public func undoLastAction(taskID: String) throws -> String? {
        guard var m = manifest(taskID: taskID), let last = m.history.popLast() else { return nil }
        try restore(last)
        if !m.history.contains(where: { $0.path == last.path }) { m.initial[last.path] = nil }
        manifests[taskID] = m
        persist(taskID)
        return last.path
    }

    // MARK: Whole-project capture (commands, folder moves and deletes)

    /// One file as it was when the project was captured.
    public struct FileStamp: Sendable, Equatable {
        public let size: Int
        public let modified: Date
        public let blob: String
    }

    /// The project's files before an action that can change many of them at once, such as a shell
    /// command. `recordChanges(since:)` turns the difference into checkpoints, so Undo Task covers it.
    public struct TreeCapture: Sendable {
        public let files: [String: FileStamp]
        /// Files that exist but weren't stored (too large, or past the limits); never reported as new.
        public let uncaptured: Set<String>
    }

    public static let maxCapturedFileBytes = 5 * 1024 * 1024
    public static let maxCapturedFiles = 20_000
    public static let maxCapturedTotalBytes = 500 * 1024 * 1024

    /// Stamps from earlier captures, so a repeat capture only reads files whose size or date changed.
    private var stampCache: [String: FileStamp] = [:]

    /// Stores every project file the agent can see (honouring `ignore`, so `node_modules` and build
    /// output are skipped). Unchanged files cost a `stat`, because their content is already stored.
    public func captureTree(ignore: IgnoreRules) -> TreeCapture {
        var files: [String: FileStamp] = [:]
        var uncaptured = Set<String>()
        var total = 0
        for file in walkFiles(ignore: ignore) {
            guard file.size <= Self.maxCapturedFileBytes, files.count < Self.maxCapturedFiles,
                  total + file.size <= Self.maxCapturedTotalBytes else {
                uncaptured.insert(file.rel); continue
            }
            if let cached = stampCache[file.rel], cached.size == file.size, cached.modified == file.modified {
                files[file.rel] = cached
                total += file.size
                continue
            }
            guard let data = try? Data(contentsOf: file.url), let blob = try? store(data) else {
                uncaptured.insert(file.rel); continue
            }
            let stamp = FileStamp(size: file.size, modified: file.modified, blob: blob)
            stampCache[file.rel] = stamp
            files[file.rel] = stamp
            total += file.size
        }
        return TreeCapture(files: files, uncaptured: uncaptured)
    }

    /// Compares the project with `capture` and records every file that changed, appeared, or
    /// disappeared as part of the task, with its content from before. A file the task already touched
    /// keeps its earlier original. Returns the recorded paths, sorted.
    @discardableResult
    public func recordChanges(since capture: TreeCapture, ignore: IgnoreRules, taskID: String, label: String?) -> [String] {
        if manifests[taskID] == nil { beginTask(id: taskID) }
        var current: [String: WalkedFile] = [:]
        for file in walkFiles(ignore: ignore) { current[file.rel] = file }

        var changed: [String] = []
        let now = Date()
        func record(_ rel: String, blob: String?) {
            let snap = Snapshot(path: rel, blob: blob, takenAt: now, label: label)
            if manifests[taskID]!.initial[rel] == nil { manifests[taskID]!.initial[rel] = snap }
            manifests[taskID]!.history.append(snap)
            changed.append(rel)
        }
        for (rel, before) in capture.files {
            guard let now = current[rel] else { record(rel, blob: before.blob); continue }   // deleted
            if now.size == before.size && now.modified == before.modified { continue }
            guard let data = try? Data(contentsOf: now.url) else { continue }
            if Self.sha256(data) != before.blob { record(rel, blob: before.blob) }
        }
        for rel in current.keys where capture.files[rel] == nil && !capture.uncaptured.contains(rel) {
            record(rel, blob: nil)   // created
        }
        if !changed.isEmpty { persist(taskID) }
        return changed.sorted()
    }

    private struct WalkedFile {
        let rel: String
        let url: URL
        let size: Int
        let modified: Date
    }

    private func walkFiles(ignore: IgnoreRules) -> [WalkedFile] {
        let fm = FileManager.default
        let keys: [URLResourceKey] = [.isDirectoryKey, .isSymbolicLinkKey, .fileSizeKey, .contentModificationDateKey]
        let ownDirectory = directory.standardizedFileURL.path
        var result: [WalkedFile] = []
        var stack = [projectRoot]
        while let dir = stack.popLast() {
            guard let urls = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: keys) else { continue }
            for url in urls {
                guard url.lastPathComponent != ".git",
                      !url.standardizedFileURL.path.hasPrefix(ownDirectory),
                      let values = try? url.resourceValues(forKeys: Set(keys)),
                      values.isSymbolicLink != true else { continue }
                let rel = relative(url)
                let isDirectory = values.isDirectory ?? false
                if ignore.isIgnored(relativePath: rel, isDirectory: isDirectory) { continue }
                if isDirectory {
                    stack.append(url)
                } else {
                    result.append(WalkedFile(rel: rel, url: url, size: values.fileSize ?? 0,
                                             modified: values.contentModificationDate ?? .distantPast))
                }
            }
        }
        return result
    }

    // MARK: Private

    private func restore(_ snap: Snapshot) throws {
        let url = projectRoot.appendingPathComponent(snap.path)
        if let blob = snap.blob, let data = read(blob) {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: url, options: .atomic)
        } else if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
            removeEmptyParents(of: url)
        }
    }

    /// After removing a file the task created, removes folders it left empty (up to the project root).
    private func removeEmptyParents(of url: URL) {
        var dir = url.deletingLastPathComponent().standardizedFileURL
        while dir.path.hasPrefix(projectRoot.path + "/"),
              let contents = try? FileManager.default.contentsOfDirectory(atPath: dir.path), contents.isEmpty {
            try? FileManager.default.removeItem(at: dir)
            dir = dir.deletingLastPathComponent()
        }
    }

    static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private func relative(_ url: URL) -> String {
        let p = url.standardizedFileURL.path
        return p.hasPrefix(projectRoot.path + "/") ? String(p.dropFirst(projectRoot.path.count + 1)) : p
    }

    private func store(_ data: Data) throws -> String {
        let sha = Self.sha256(data)
        let url = directory.appendingPathComponent("blobs/\(sha)")
        if !FileManager.default.fileExists(atPath: url.path) { try data.write(to: url, options: .atomic) }
        return sha
    }

    private func read(_ sha: String) -> Data? {
        try? Data(contentsOf: directory.appendingPathComponent("blobs/\(sha)"))
    }

    private func persist(_ id: String) {
        guard let m = manifests[id] else { return }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        if let data = try? encoder.encode(m) {
            try? data.write(to: directory.appendingPathComponent("tasks/\(id).json"), options: .atomic)
        }
    }

    private func load(_ id: String) -> TaskManifest? {
        let url = directory.appendingPathComponent("tasks/\(id).json")
        guard let data = try? Data(contentsOf: url) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let m = try? decoder.decode(TaskManifest.self, from: data)
        if let m { manifests[id] = m }
        return m
    }
}
