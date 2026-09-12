import Foundation

/// A small gitignore-style matcher.
///
/// Supports the subset that matters for a project explorer and agent search:
/// blank lines / comments, `!` negation, trailing `/` (directory only),
/// patterns containing `/` (anchored to the root), `*`, `**` and `?`.
/// Later rules win, as in git.
public struct IgnoreRules: Sendable {
    /// Hidden from the explorer: things nobody browses by hand.
    public static let explorerDefaults: [String] = [".git", ".DS_Store"]

    /// Additionally skipped by agent search and the project map: large generated trees.
    public static let searchDefaults: [String] = explorerDefaults + [
        "node_modules", ".build", "DerivedData", ".swiftpm", "dist", "build",
        "target", ".venv", "venv", "__pycache__", ".next", ".turbo", "coverage",
        ".idea", ".vscode", "*.xcodeproj", "*.xcworkspace", "Pods",
    ]

    fileprivate struct Rule: Sendable {
        let regex: NSRegularExpression
        let anchored: Bool
        let directoryOnly: Bool
        let negated: Bool

        func matches(_ subject: String) -> Bool {
            let range = NSRange(subject.startIndex..., in: subject)
            return regex.firstMatch(in: subject, options: [], range: range) != nil
        }
    }

    private let rules: [Rule]

    public init(patterns: [String]) {
        rules = patterns.compactMap(Rule.init(pattern:))
    }

    /// Builds rules from `defaults` followed by the root `.gitignore`, if present.
    public static func load(root: URL, defaults: [String] = explorerDefaults) -> IgnoreRules {
        var patterns = defaults
        let gitignore = root.appendingPathComponent(".gitignore")
        if let text = try? String(contentsOf: gitignore, encoding: .utf8) {
            patterns += text.split(whereSeparator: \.isNewline).map(String.init)
        }
        return IgnoreRules(patterns: patterns)
    }

    /// `relativePath` is slash-separated and relative to the project root, no leading slash.
    public func isIgnored(relativePath: String, isDirectory: Bool) -> Bool {
        let path = relativePath.hasSuffix("/") ? String(relativePath.dropLast()) : relativePath
        let name = path.split(separator: "/").last.map(String.init) ?? path
        var ignored = false
        for rule in rules {
            let subject = rule.anchored ? path : name
            let selfMatch = rule.matches(subject) && (isDirectory || !rule.directoryOnly)
            if selfMatch || parentMatches(rule, path: path) {
                ignored = !rule.negated
            }
        }
        return ignored
    }

    /// True when any ancestor directory of `path` matches the rule.
    private func parentMatches(_ rule: Rule, path: String) -> Bool {
        let parts = path.split(separator: "/").map(String.init)
        guard parts.count > 1 else { return false }
        for i in 1..<parts.count {
            let subject = rule.anchored ? parts[0..<i].joined(separator: "/") : parts[i - 1]
            if rule.matches(subject) { return true }
        }
        return false
    }
}

extension IgnoreRules.Rule {
    fileprivate init?(pattern raw: String) {
        var pattern = raw.trimmingCharacters(in: .whitespaces)
        guard !pattern.isEmpty, !pattern.hasPrefix("#") else { return nil }

        var negated = false
        if pattern.hasPrefix("!") { negated = true; pattern.removeFirst() }

        var directoryOnly = false
        if pattern.hasSuffix("/") { directoryOnly = true; pattern.removeLast() }

        var anchored = false
        if pattern.hasPrefix("/") { anchored = true; pattern.removeFirst() }
        else if pattern.contains("/") { anchored = true }

        guard !pattern.isEmpty,
              let regex = try? NSRegularExpression(pattern: "^" + Self.globToRegex(pattern) + "$")
        else { return nil }
        self.init(regex: regex, anchored: anchored, directoryOnly: directoryOnly, negated: negated)
    }

    static func globToRegex(_ glob: String) -> String {
        var out = ""
        let chars = Array(glob)
        var i = 0
        while i < chars.count {
            let c = chars[i]
            switch c {
            case "*":
                if i + 1 < chars.count, chars[i + 1] == "*" {
                    out += ".*"
                    i += 1
                    // Swallow a following slash so `foo/**/bar` matches `foo/bar`.
                    if i + 1 < chars.count, chars[i + 1] == "/" { out += "/?"; i += 1 }
                } else {
                    out += "[^/]*"
                }
            case "?": out += "[^/]"
            case ".", "(", ")", "+", "|", "^", "$", "{", "}", "[", "]", "\\":
                out += "\\" + String(c)
            default: out.append(c)
            }
            i += 1
        }
        return out
    }
}
