import Foundation

/// Applies search/replace edits to text. The model supplies `old` blocks that must
/// match exactly once; when an exact match fails we retry ignoring trailing whitespace
/// and then leading indentation, which absorbs the most common model slips.
public enum PatchApplier {
    public struct Edit: Sendable, Equatable {
        public var old: String
        public var new: String
        public init(old: String, new: String) { self.old = old; self.new = new }
    }

    public enum Failure: LocalizedError, Sendable, Equatable {
        case notFound(index: Int, snippet: String)
        case ambiguous(index: Int, count: Int)
        case emptyOld(index: Int)

        public var errorDescription: String? {
            switch self {
            case .notFound(let i, let s): "Edit \(i + 1): the text to replace was not found. Re-read the file and try again. Looking for: \(s)"
            case .ambiguous(let i, let n): "Edit \(i + 1): the text to replace matches \(n) places; include more surrounding lines to make it unique."
            case .emptyOld(let i): "Edit \(i + 1): `old` must not be empty (use create_file or write_file for new content)."
            }
        }
    }

    public struct Result: Sendable, Equatable {
        public let text: String
        public let fuzzyEdits: Int
    }

    public static func apply(_ edits: [Edit], to original: String) throws -> Result {
        // CRLF files: match and edit on LF-normalised text, then restore CRLF. (`"\r\n"` is one
        // `Character`, so neither exact nor line-based matching works on it directly.)
        let crlf = original.contains("\r\n")
        var text = crlf ? original.replacingOccurrences(of: "\r\n", with: "\n") : original
        let edits = crlf ? edits.map { Edit(old: $0.old.replacingOccurrences(of: "\r\n", with: "\n"),
                                            new: $0.new.replacingOccurrences(of: "\r\n", with: "\n")) } : edits
        var fuzzy = 0
        for (i, edit) in edits.enumerated() {
            guard !edit.old.isEmpty else { throw Failure.emptyOld(index: i) }
            let exact = ranges(of: edit.old, in: text)
            if exact.count == 1 {
                text.replaceSubrange(exact[0], with: edit.new)
                continue
            }
            if exact.count > 1 { throw Failure.ambiguous(index: i, count: exact.count) }
            // Fuzzy: line-based comparison ignoring trailing whitespace, then leading whitespace.
            switch fuzzyRange(of: edit, in: text) {
            case .found(let range, let reindented):
                text.replaceSubrange(range, with: reindented)
                fuzzy += 1
            case .ambiguous(let n):
                throw Failure.ambiguous(index: i, count: n)
            case .notFound:
                throw Failure.notFound(index: i, snippet: String(edit.old.prefix(80)).replacingOccurrences(of: "\n", with: "⏎"))
            }
        }
        return Result(text: crlf ? text.replacingOccurrences(of: "\n", with: "\r\n") : text, fuzzyEdits: fuzzy)
    }

    private static func ranges(of needle: String, in text: String) -> [Range<String.Index>] {
        var ranges: [Range<String.Index>] = []
        var start = text.startIndex
        while let r = text.range(of: needle, range: start..<text.endIndex) {
            ranges.append(r)
            if ranges.count > 1 { break }
            start = r.upperBound
        }
        return ranges
    }

    private enum FuzzyOutcome { case found(Range<String.Index>, String), ambiguous(Int), notFound }

    /// Returns the range of the matching lines and the replacement re-indented to match.
    private static func fuzzyRange(of edit: Edit, in text: String) -> FuzzyOutcome {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        let oldLines = edit.old.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        guard !oldLines.isEmpty, oldLines.count <= lines.count else { return .notFound }

        func norm(_ s: String, leading: Bool) -> String {
            var t = s
            while t.last?.isWhitespace == true { t.removeLast() }
            if leading { while t.first?.isWhitespace == true { t.removeFirst() } }
            return t
        }

        var ambiguousCount = 0
        for leading in [false, true] {
            let target = oldLines.map { norm($0, leading: leading) }
            var found: [Int] = []
            for start in 0...(lines.count - oldLines.count) {
                var ok = true
                for j in 0..<oldLines.count where norm(lines[start + j], leading: leading) != target[j] { ok = false; break }
                if ok { found.append(start); if found.count > 1 { break } }
            }
            if found.count > 1 { ambiguousCount = found.count; continue }
            guard found.count == 1 else { continue }
            let start = found[0]
            let end = start + oldLines.count - 1
            // Compute character range of lines[start...end].
            var offset = 0
            for i in 0..<start { offset += lines[i].count + 1 }
            let from = text.index(text.startIndex, offsetBy: offset)
            var length = 0
            for i in start...end { length += lines[i].count + (i < end ? 1 : 0) }
            let to = text.index(from, offsetBy: length)

            var replacement = edit.new
            if leading {
                // Re-indent replacement by the difference between the file's and the edit's first-line indent.
                let fileIndent = lines[start].prefix { $0.isWhitespace }
                let editIndent = oldLines[0].prefix { $0.isWhitespace }
                if fileIndent != editIndent {
                    replacement = edit.new.split(separator: "\n", omittingEmptySubsequences: false).map { line -> String in
                        var l = String(line)
                        if l.hasPrefix(editIndent) { l.removeFirst(editIndent.count); return fileIndent + l }
                        return l
                    }.joined(separator: "\n")
                }
            }
            return .found(from..<to, replacement)
        }
        return ambiguousCount > 1 ? .ambiguous(ambiguousCount) : .notFound
    }
}
