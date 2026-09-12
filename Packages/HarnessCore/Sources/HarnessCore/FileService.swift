import Foundation

public enum FileServiceError: LocalizedError, Sendable {
    case outsideProject(String)
    case notUTF8(String)
    case tooLarge(String, Int)
    case alreadyExists(String)
    case protected(String)

    public var errorDescription: String? {
        switch self {
        case .outsideProject(let p): "\(p) is outside the project"
        case .notUTF8(let p): "\(p) is not a UTF-8 text file"
        case .tooLarge(let p, let n): "\(p) is too large (\(n) bytes)"
        case .alreadyExists(let p): "\(p) already exists"
        case .protected(let p): "\(p) is protected and cannot be read by the agent"
        }
    }
}

/// Root-scoped file operations shared by the explorer, editor and agent tools.
/// Every path is checked to be inside the project root; the agent additionally
/// cannot read files matching `protectedPatterns` (secrets).
public struct FileService: Sendable {
    public let root: URL
    public var maxTextBytes = 4 * 1024 * 1024

    /// Glob patterns (basename) the agent may never read. PRD §27.
    public var protectedPatterns: [String] = [".env", ".env.*", "*.pem", "*.key", "credentials.json", "*.p12", "id_rsa", "id_ed25519"]

    /// `root` with every symlink resolved, so containment checks can't be fooled by links.
    private let canonicalRoot: String

    public init(root: URL) {
        self.root = root.standardizedFileURL
        self.canonicalRoot = Self.canonicalPath(self.root.path)
    }

    // MARK: Paths

    /// True when `url` lives inside the project after resolving symlinks on both sides. A link
    /// inside the project that points outside (`src/etc -> /etc`) is *not* contained.
    public func contains(_ url: URL) -> Bool {
        let path = Self.canonicalPath(url.standardizedFileURL.path)
        return path == canonicalRoot || path.hasPrefix(canonicalRoot + "/")
    }

    /// `realpath` for existing paths; for paths that don't exist yet, resolves the deepest existing
    /// ancestor and re-appends the remaining components.
    static func canonicalPath(_ path: String) -> String {
        var existing = path
        var tail: [String] = []
        while !existing.isEmpty, existing != "/" {
            if let real = realpath(existing, nil) {
                let resolved = String(cString: real)
                free(real)
                return tail.reversed().reduce(resolved) { ($0 as NSString).appendingPathComponent($1) }
            }
            tail.append((existing as NSString).lastPathComponent)
            existing = (existing as NSString).deletingLastPathComponent
        }
        return path
    }

    public func relativePath(_ url: URL) -> String {
        let path = url.standardizedFileURL.path
        guard path.hasPrefix(root.path + "/") else { return url.lastPathComponent }
        return String(path.dropFirst(root.path.count + 1))
    }

    /// Resolves a project-relative (or absolute) path, rejecting anything outside the root.
    public func resolve(_ relativeOrAbsolute: String) throws -> URL {
        let url = relativeOrAbsolute.hasPrefix("/")
            ? URL(fileURLWithPath: relativeOrAbsolute)
            : root.appendingPathComponent(relativeOrAbsolute)
        let standardized = url.standardizedFileURL
        guard contains(standardized) else { throw FileServiceError.outsideProject(relativeOrAbsolute) }
        return standardized
    }

    /// Matches the basename of `url` *and* of whatever it resolves to, so `notsecret.txt -> .env`
    /// is still protected.
    public func isProtected(_ url: URL) -> Bool {
        var names = [url.lastPathComponent]
        let resolved = (Self.canonicalPath(url.standardizedFileURL.path) as NSString).lastPathComponent
        if resolved != names[0] { names.append(resolved) }
        return names.contains { name in
            protectedPatterns.contains { fnmatch($0, name, 0) == 0 }
        }
    }

    // MARK: Reading

    public func readText(_ url: URL) throws -> String {
        guard contains(url) else { throw FileServiceError.outsideProject(url.path) }
        let data = try Data(contentsOf: url)
        guard data.count <= maxTextBytes else { throw FileServiceError.tooLarge(relativePath(url), data.count) }
        guard let text = String(data: data, encoding: .utf8) else { throw FileServiceError.notUTF8(relativePath(url)) }
        return text
    }

    /// Same as `readText` but also enforces the secrets exclusion list — use from agent tools.
    public func readTextForAgent(_ url: URL) throws -> String {
        guard !isProtected(url) else { throw FileServiceError.protected(relativePath(url)) }
        return try readText(url)
    }

    public func exists(_ url: URL) -> Bool { FileManager.default.fileExists(atPath: url.path) }

    public func isDirectory(_ url: URL) -> Bool {
        var isDir: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) && isDir.boolValue
    }

    // MARK: Writing

    public func writeText(_ text: String, to url: URL) throws {
        guard contains(url) else { throw FileServiceError.outsideProject(url.path) }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.data(using: .utf8)!.write(to: url, options: .atomic)
    }

    public func createFile(at url: URL, contents: String = "") throws {
        guard contains(url) else { throw FileServiceError.outsideProject(url.path) }
        guard !exists(url) else { throw FileServiceError.alreadyExists(relativePath(url)) }
        try writeText(contents, to: url)
    }

    public func createDirectory(at url: URL) throws {
        guard contains(url) else { throw FileServiceError.outsideProject(url.path) }
        guard !exists(url) else { throw FileServiceError.alreadyExists(relativePath(url)) }
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    public func move(_ url: URL, to destination: URL) throws {
        guard contains(url), contains(destination) else { throw FileServiceError.outsideProject(destination.path) }
        guard !exists(destination) else { throw FileServiceError.alreadyExists(relativePath(destination)) }
        try FileManager.default.moveItem(at: url, to: destination)
    }

    public func rename(_ url: URL, to name: String) throws -> URL {
        let destination = url.deletingLastPathComponent().appendingPathComponent(name)
        try move(url, to: destination)
        return destination
    }

    /// Copies `url` next to itself as "name copy.ext" (or "name copy 2.ext"…).
    @discardableResult
    public func duplicate(_ url: URL) throws -> URL {
        guard contains(url) else { throw FileServiceError.outsideProject(url.path) }
        let dir = url.deletingLastPathComponent()
        let ext = url.pathExtension
        let base = ext.isEmpty ? url.lastPathComponent : url.deletingPathExtension().lastPathComponent
        var candidate = dir.appendingPathComponent("\(base) copy" + (ext.isEmpty ? "" : ".\(ext)"))
        var n = 2
        while exists(candidate) {
            candidate = dir.appendingPathComponent("\(base) copy \(n)" + (ext.isEmpty ? "" : ".\(ext)"))
            n += 1
        }
        try FileManager.default.copyItem(at: url, to: candidate)
        return candidate
    }

    /// Moves to the Trash so a user (or the agent) can recover it from Finder.
    public func trash(_ url: URL) throws {
        guard contains(url) else { throw FileServiceError.outsideProject(url.path) }
        try FileManager.default.trashItem(at: url, resultingItemURL: nil)
    }

    /// Splits text into lines on `\n`, tolerating CRLF (`"\r\n"` is a single `Character`, so
    /// `split(separator: "\n")` would never split a Windows-style file).
    public static func lines(of text: String) -> [String] {
        text.components(separatedBy: "\n").map { $0.hasSuffix("\r") ? String($0.dropLast()) : $0 }
    }

    /// Modification date + size, used to detect concurrent human edits before the agent writes.
    public func fingerprint(_ url: URL) -> String? {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              let date = attrs[.modificationDate] as? Date,
              let size = attrs[.size] as? NSNumber
        else { return nil }
        return "\(date.timeIntervalSince1970):\(size)"
    }
}
