import Foundation
import HarnessCore

/// PRD §21 — a skill is a markdown file whose body is prepended to the user's message as
/// extra instructions. Project skills live in `.rokubi/skills/`, user skills in
/// `~/.rokubi/skills/`. No UI beyond `/name` in the composer and the command palette.
public struct Skill: Sendable, Equatable, Identifiable {
    public var name: String            // slash name, e.g. "review"
    public var description: String     // first heading or first line
    public var body: String
    public var scope: Scope
    public enum Scope: String, Sendable { case builtin, project, user }
    public var id: String { "\(scope.rawValue):\(name)" }
}

public struct SkillStore: Sendable {
    public let projectRoot: URL
    /// Shared across copies of this value so `AgentSession.skills` and any caller that copies
    /// the struct see one cache.
    private let cache: Cache

    /// - Parameter recheckInterval: how long a cached listing is trusted before the two skill
    ///   directories are stat'ed again. `0` re-checks on every call (tests).
    public init(projectRoot: URL, recheckInterval: TimeInterval = 2) {
        self.projectRoot = projectRoot
        self.cache = Cache(recheckInterval: recheckInterval)
    }

    public var projectDirectory: URL { projectRoot.appendingPathComponent(".rokubi/skills", isDirectory: true) }
    public static var userDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".rokubi/skills", isDirectory: true)
    }

    /// Built-ins first, then user, then project — later scopes override earlier ones by name.
    ///
    /// Cached: this is called from SwiftUI bodies and per keystroke, so it must not read
    /// directories each time. The cache is trusted for `recheckInterval`; after that the two
    /// directories' modification dates are compared (two `stat`s, no listing) and the files are
    /// only re-read when a directory changed. Editing a skill file *in place* does not bump the
    /// directory mtime — call `invalidate()` (or wait for an atomic-save rename) for that case.
    public func all() -> [Skill] {
        let now = Date()
        if let hit = cache.valid(at: now) { return hit }
        let stamp = stamp()
        if let hit = cache.valid(for: stamp, at: now) { return hit }
        let skills = loadAll()
        cache.store(skills, stamp: stamp, at: now)
        return skills
    }

    /// Drops the cached listing so the next `all()` re-reads both directories.
    public func invalidate() { cache.clear() }

    private func loadAll() -> [Skill] {
        var byName: [String: Skill] = [:]
        for skill in Self.builtins { byName[skill.name] = skill }
        for skill in load(from: Self.userDirectory, scope: .user) { byName[skill.name] = skill }
        for skill in load(from: projectDirectory, scope: .project) { byName[skill.name] = skill }
        return byName.values.sorted { $0.name < $1.name }
    }

    /// Modification dates of the two skill directories (nil = missing).
    private func stamp() -> Stamp {
        func mtime(_ url: URL) -> Date? {
            (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
        }
        return Stamp(user: mtime(Self.userDirectory), project: mtime(projectDirectory))
    }

    private struct Stamp: Equatable, Sendable {
        var user: Date?
        var project: Date?
    }

    private final class Cache: @unchecked Sendable {
        private let lock = NSLock()
        private let recheckInterval: TimeInterval
        private var skills: [Skill]?
        private var stamp: Stamp?
        private var checkedAt: Date = .distantPast

        init(recheckInterval: TimeInterval) { self.recheckInterval = recheckInterval }

        /// The cached listing if it was verified against disk recently enough.
        func valid(at now: Date) -> [Skill]? {
            lock.lock(); defer { lock.unlock() }
            guard let skills, now.timeIntervalSince(checkedAt) < recheckInterval else { return nil }
            return skills
        }

        /// The cached listing if the directories have not changed since it was built; refreshes the check time.
        func valid(for current: Stamp, at now: Date) -> [Skill]? {
            lock.lock(); defer { lock.unlock() }
            guard let skills, stamp == current else { return nil }
            checkedAt = now
            return skills
        }

        func store(_ skills: [Skill], stamp: Stamp, at now: Date) {
            lock.lock(); defer { lock.unlock() }
            self.skills = skills
            self.stamp = stamp
            checkedAt = now
        }

        func clear() {
            lock.lock(); defer { lock.unlock() }
            skills = nil
            stamp = nil
            checkedAt = .distantPast
        }
    }

    /// Starter skills (PRD §21 examples) so `/` is useful before anyone writes a skill file.
    /// Drop a same-named `.md` in `.rokubi/skills/` to replace one.
    public static let builtins: [Skill] = [
        Skill(name: "review", description: "Review the current changes for bugs and risks", body: """
        # Review
        Review the project's uncommitted changes (use git_diff, and read surrounding code as needed). \
        Look for correctness bugs, missing error handling, security issues, and regressions. \
        Do not edit anything. Report findings ordered by severity with file:line references, then a short verdict.
        """, scope: .builtin),
        Skill(name: "test", description: "Run the project's tests and fix failures", body: """
        # Test
        Detect the project's test command (package.json scripts, Makefile, Package.swift, pyproject, Cargo.toml). \
        Run it with run_command. If anything fails, read the failing test and the code under test, fix the root cause \
        (not the test), re-run until green, then report_completion listing exactly what passed.
        """, scope: .builtin),
        Skill(name: "refactor", description: "Refactor the selected code or named module without changing behaviour", body: """
        # Refactor
        Refactor the code the user points at (use @selection or the named files). Preserve behaviour exactly: \
        improve names, structure, and duplication; keep public interfaces stable. Run the tests before and after \
        with run_command and only report_completion if they still pass.
        """, scope: .builtin),
        Skill(name: "explain", description: "Explain how part of the project works", body: """
        # Explain
        Explain how the code the user asks about works. Search and read the relevant files first. \
        Answer with a concise walkthrough: entry points, data flow, key types, and gotchas, citing file paths. \
        Do not modify any files.
        """, scope: .builtin),
        Skill(name: "security-review", description: "Audit the changes or project for security issues", body: """
        # Security review
        Audit for security problems: injection, auth/permission gaps, secrets in code, unsafe file or shell use, \
        unvalidated input, and dependency risks. Use grep and read_file; do not edit. \
        Report each finding with severity, location, why it matters, and a concrete fix.
        """, scope: .builtin),
    ]

    public func skill(named name: String) -> Skill? {
        all().first { $0.name == name }
    }

    private func load(from directory: URL, scope: Skill.Scope) -> [Skill] {
        guard let urls = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) else { return [] }
        return urls.filter { $0.pathExtension == "md" }.compactMap { url in
            guard let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
            let name = url.deletingPathExtension().lastPathComponent
            let firstLine = text.split(whereSeparator: \.isNewline).first.map(String.init) ?? name
            let description = firstLine.drop(while: { $0 == "#" || $0 == " " }).description
            return Skill(name: name, description: description.isEmpty ? name : description, body: text, scope: scope)
        }
    }

    /// Expands a leading `/name` in `text` into the skill body + remaining text.
    public func expand(_ text: String) -> (prompt: String, usedSkill: String?) {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix("/") else { return (text, nil) }
        let rest = trimmed.dropFirst()
        let name = String(rest.prefix { !$0.isWhitespace })
        guard let skill = skill(named: name) else { return (text, nil) }
        let remainder = rest.dropFirst(name.count).trimmingCharacters(in: .whitespaces)
        var prompt = skill.body
        if !remainder.isEmpty { prompt += "\n\n---\n\(remainder)" }
        return (prompt, name)
    }
}
