import Foundation

/// Git via the `/usr/bin/git` subprocess (PRD §23). Surfaces contextually; no permanent sidebar.
public struct GitService: Sendable {
    public struct FileStatus: Sendable, Equatable, Identifiable {
        public enum State: String, Sendable { case modified, added, deleted, renamed, untracked, conflicted }
        public var path: String
        public var state: State
        public var staged: Bool
        public var id: String { path }
    }

    public struct Commit: Sendable, Equatable, Identifiable {
        public var hash: String
        public var shortHash: String
        public var subject: String
        public var author: String
        public var date: String
        public var id: String { hash }
    }

    public let root: URL
    private let git = "/usr/bin/git"

    public init(root: URL) { self.root = root }

    public var isRepository: Bool {
        (try? run(["rev-parse", "--is-inside-work-tree"]))?.output.trimmingCharacters(in: .whitespacesAndNewlines) == "true"
    }

    public func initRepository() throws { _ = try run(["init"]) }

    public func currentBranch() -> String? {
        guard let r = try? run(["rev-parse", "--abbrev-ref", "HEAD"]), r.exitCode == 0 else { return nil }
        let b = r.output.trimmingCharacters(in: .whitespacesAndNewlines)
        return b == "HEAD" ? nil : b
    }

    /// Parses `git status --porcelain=v1 -z`. In `-z` mode a rename/copy is two NUL-separated
    /// fields (`R  new\0old\0`), so the old path has to be consumed explicitly.
    public func status() throws -> [FileStatus] {
        let r = try run(["status", "--porcelain=v1", "-z"])
        guard r.exitCode == 0 else { return [] }
        var result: [FileStatus] = []
        let fields = r.output.split(separator: "\0", omittingEmptySubsequences: true).map(String.init)
        var index = 0
        while index < fields.count {
            let line = fields[index]
            index += 1
            guard line.count >= 3 else { continue }
            let x = line[line.startIndex]
            let y = line[line.index(after: line.startIndex)]
            let path = String(line.dropFirst(3))
            if "RC".contains(x) || "RC".contains(y) { index += 1 }   // skip the "old" path field
            if x == "?" && y == "?" {
                result.append(FileStatus(path: path, state: .untracked, staged: false)); continue
            }
            if x == "U" || y == "U" {
                result.append(FileStatus(path: path, state: .conflicted, staged: false)); continue
            }
            if x != " " { result.append(FileStatus(path: path, state: state(for: x), staged: true)) }
            if y != " " { result.append(FileStatus(path: path, state: state(for: y), staged: false)) }
        }
        return result
    }

    public func diff(path: String? = nil, staged: Bool = false) throws -> String {
        var args = ["diff"]
        if staged { args.append("--cached") }
        if let path { args += ["--", path] }
        return try run(args).output
    }

    public func log(limit: Int = 30) throws -> [Commit] {
        let sep = "\u{1f}"
        let r = try run(["log", "-n", "\(limit)", "--pretty=format:%H\(sep)%h\(sep)%s\(sep)%an\(sep)%ad", "--date=short"])
        guard r.exitCode == 0 else { return [] }
        return r.output.split(separator: "\n").compactMap { line in
            let f = line.components(separatedBy: sep)
            guard f.count == 5 else { return nil }
            return Commit(hash: f[0], shortHash: f[1], subject: f[2], author: f[3], date: f[4])
        }
    }

    public func stage(_ paths: [String]) throws { _ = try run(["add", "--"] + paths) }
    public func stageAll() throws { _ = try run(["add", "-A"]) }
    public func unstage(_ paths: [String]) throws { _ = try run(["restore", "--staged", "--"] + paths) }

    @discardableResult
    public func commit(message: String) throws -> String {
        let r = try run(["commit", "-m", message])
        guard r.exitCode == 0 else { throw GitError(r.error.isEmpty ? r.output : r.error) }
        return r.output
    }

    public func branches() throws -> [String] {
        try run(["branch", "--format=%(refname:short)"]).output.split(separator: "\n").map(String.init)
    }

    @discardableResult
    public func createBranch(_ name: String) throws -> String {
        let r = try run(["checkout", "-b", name])
        guard r.exitCode == 0 else { throw GitError(r.error) }
        return r.output
    }

    // MARK: Process

    public struct Output: Sendable { public var exitCode: Int32; public var output: String; public var error: String }

    @discardableResult
    public func run(_ args: [String]) throws -> Output {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: git)
        process.arguments = args
        process.currentDirectoryURL = root
        var env = ProcessInfo.processInfo.environment
        env["GIT_PAGER"] = "cat"; env["GIT_TERMINAL_PROMPT"] = "0"
        process.environment = env
        let out = Pipe(), err = Pipe()
        process.standardOutput = out
        process.standardError = err
        try process.run()
        // Drain both pipes concurrently: reading stdout to EOF first deadlocks if git fills the
        // stderr pipe buffer (64 KB) before it finishes writing stdout.
        let errBox = DataBox()
        let group = DispatchGroup()
        group.enter()
        DispatchQueue.global(qos: .utility).async {
            errBox.data = err.fileHandleForReading.readDataToEndOfFile()
            group.leave()
        }
        let outData = out.fileHandleForReading.readDataToEndOfFile()
        group.wait()
        process.waitUntilExit()
        return Output(exitCode: process.terminationStatus,
                      output: String(decoding: outData, as: UTF8.self),
                      error: String(decoding: errBox.data, as: UTF8.self))
    }

    /// Written on one queue and read after `group.wait()`, which orders the accesses.
    private final class DataBox: @unchecked Sendable {
        var data = Data()
    }

    private func state(for c: Character) -> FileStatus.State {
        switch c {
        case "M": .modified
        case "A": .added
        case "D": .deleted
        case "R": .renamed
        default: .modified
        }
    }
}

public struct GitError: LocalizedError {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var errorDescription: String? { message.isEmpty ? "git failed" : message }
}
