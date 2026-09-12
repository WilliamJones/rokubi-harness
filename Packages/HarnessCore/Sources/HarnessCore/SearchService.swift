import Foundation

/// Filename and content search over the project, honoring ignore rules and caps.
public struct SearchService: Sendable {
    public struct Match: Sendable, Equatable {
        public let path: String
        public let line: Int
        public let text: String
    }

    public let files: FileService
    public let ignore: IgnoreRules
    public var maxFileBytes = 2 * 1024 * 1024

    public init(files: FileService, ignore: IgnoreRules) {
        self.files = files
        self.ignore = ignore
    }

    /// Project-relative paths matching a glob (`src/**/*.ts`, `*.swift`). Patterns without `/`
    /// match the basename at any depth.
    public func glob(_ pattern: String, limit: Int = 500) -> [String] {
        guard let regex = Glob.regex(for: pattern) else { return [] }
        let anchored = pattern.contains("/")
        var results: [String] = []
        walk { rel, isDir in
            guard !isDir, results.count < limit else { return }
            let subject = anchored ? rel : String(rel.split(separator: "/").last ?? "")
            if regex.firstMatch(in: subject, range: NSRange(subject.startIndex..., in: subject)) != nil {
                results.append(rel)
            }
        }
        return results
    }

    /// Regex (or literal) search across text files. Returns at most `limit` matches.
    public func grep(_ pattern: String, isRegex: Bool = true, caseSensitive: Bool = false,
                     pathGlob: String? = nil, limit: Int = 200, perFileLimit: Int = 20) -> (matches: [Match], filesScanned: Int, truncated: Bool) {
        var options: NSRegularExpression.Options = []
        if !caseSensitive { options.insert(.caseInsensitive) }
        let source = isRegex ? pattern : NSRegularExpression.escapedPattern(for: pattern)
        guard let regex = try? NSRegularExpression(pattern: source, options: options) else { return ([], 0, false) }
        let pathRegex = pathGlob.flatMap(Glob.regex(for:))
        let pathAnchored = pathGlob?.contains("/") ?? false

        var matches: [Match] = []
        var scanned = 0
        var truncated = false
        walk { rel, isDir in
            guard !isDir, !truncated else { return }
            if let pathRegex {
                let subject = pathAnchored ? rel : String(rel.split(separator: "/").last ?? "")
                guard pathRegex.firstMatch(in: subject, range: NSRange(subject.startIndex..., in: subject)) != nil else { return }
            }
            let url = files.root.appendingPathComponent(rel)
            guard !files.isProtected(url), let text = readTextIfSmall(url) else { return }
            scanned += 1
            var perFile = 0
            for (i, s) in FileService.lines(of: text).enumerated() {
                if regex.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)) != nil {
                    matches.append(Match(path: rel, line: i + 1, text: String(s.prefix(300))))
                    perFile += 1
                    if matches.count >= limit { truncated = true; return }
                    if perFile >= perFileLimit { return }
                }
            }
        }
        return (matches, scanned, truncated)
    }

    /// Lists one directory (non-recursive), respecting ignore rules.
    public func list(_ directory: URL) -> [(name: String, isDirectory: Bool)] {
        guard let urls = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.isDirectoryKey]) else { return [] }
        return urls.compactMap { url in
            let isDir = (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
            let rel = files.relativePath(url)
            if ignore.isIgnored(relativePath: rel, isDirectory: isDir) { return nil }
            return (url.lastPathComponent, isDir)
        }
        .sorted { a, b in a.isDirectory != b.isDirectory ? a.isDirectory : a.name.localizedStandardCompare(b.name) == .orderedAscending }
    }

    // MARK: Private

    private func walk(_ visit: (String, Bool) -> Void) {
        let fm = FileManager.default
        var stack: [URL] = [files.root]
        while let dir = stack.popLast() {
            guard let urls = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey]) else { continue }
            for url in urls.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
                let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
                if values?.isSymbolicLink == true { continue }
                let isDir = values?.isDirectory ?? false
                let rel = files.relativePath(url)
                if ignore.isIgnored(relativePath: rel, isDirectory: isDir) { continue }
                visit(rel, isDir)
                if isDir { stack.append(url) }
            }
        }
    }

    private func readTextIfSmall(_ url: URL) -> String? {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = attrs[.size] as? Int, size <= maxFileBytes,
              let data = try? Data(contentsOf: url)
        else { return nil }
        if data.prefix(8192).contains(0) { return nil }   // binary
        return String(data: data, encoding: .utf8)
    }
}

/// Glob → regex, shared by search and ignore rules.
public enum Glob {
    public static func regex(for glob: String) -> NSRegularExpression? {
        var out = "^"
        let chars = Array(glob)
        var i = 0
        while i < chars.count {
            let c = chars[i]
            switch c {
            case "*":
                if i + 1 < chars.count, chars[i + 1] == "*" {
                    out += ".*"
                    i += 1
                    if i + 1 < chars.count, chars[i + 1] == "/" { out += "/?"; i += 1 }
                } else {
                    out += "[^/]*"
                }
            case "?": out += "[^/]"
            case "{":
                // {a,b} alternation
                if let close = chars[i...].firstIndex(of: "}") {
                    let alts = String(chars[(i + 1)..<close]).split(separator: ",").map { NSRegularExpression.escapedPattern(for: String($0)) }
                    out += "(?:" + alts.joined(separator: "|") + ")"
                    i = close
                } else { out += "\\{" }
            case ".", "(", ")", "+", "|", "^", "$", "}", "[", "]", "\\":
                out += "\\" + String(c)
            default: out.append(c)
            }
            i += 1
        }
        return try? NSRegularExpression(pattern: out + "$")
    }
}
