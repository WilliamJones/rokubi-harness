import Foundation

// Message types exchanged with Web/monaco/src/bridge.ts. Keep both sides in sync.

/// A marker rendered in the gutter / squiggles (diagnostics).
public struct MonacoMarker: Codable, Sendable, Hashable {
    public enum Severity: String, Codable, Sendable { case error, warning, info, hint }

    public var line: Int
    public var column: Int
    public var endLine: Int?
    public var endColumn: Int?
    public var message: String
    public var severity: Severity
    public var source: String?

    public init(line: Int, column: Int = 1, endLine: Int? = nil, endColumn: Int? = nil,
                message: String, severity: Severity, source: String? = nil) {
        self.line = line
        self.column = column
        self.endLine = endLine
        self.endColumn = endColumn
        self.message = message
        self.severity = severity
        self.source = source
    }
}

public struct EditorTextRange: Sendable, Hashable, Codable {
    public var startLine: Int, startColumn: Int, endLine: Int, endColumn: Int
    public var isEmpty: Bool { startLine == endLine && startColumn == endColumn }
    public init(startLine: Int, startColumn: Int, endLine: Int, endColumn: Int) {
        self.startLine = startLine; self.startColumn = startColumn
        self.endLine = endLine; self.endColumn = endColumn
    }
}

/// One changed region reported by the diff editor (1-based, `0` end = empty side).
public struct DiffHunk: Sendable, Hashable, Codable {
    public var index: Int
    public var originalStart: Int, originalEnd: Int
    public var modifiedStart: Int, modifiedEnd: Int
}

/// Events emitted by the editor web view.
public enum MonacoEvent: Sendable {
    case ready
    case contentChanged(id: String, version: Int, text: String)
    case selectionChanged(id: String, range: EditorTextRange, text: String)
    case cursor(id: String, line: Int, column: Int)
    case save(id: String)
    case log(level: String, message: String)
}

/// Reply to a request/response message.
struct MonacoResponse: Sendable {
    var text: String?
    var hunks: [DiffHunk] = []
    var ok = false
}

enum MonacoMessageParser {
    /// Decodes a `WKScriptMessage.body` dictionary into an event or a response.
    static func parse(_ body: Any) -> (event: MonacoEvent?, response: (id: String, MonacoResponse)?) {
        guard let dict = body as? [String: Any], let type = dict["type"] as? String else { return (nil, nil) }
        func str(_ k: String) -> String { dict[k] as? String ?? "" }
        func int(_ k: String) -> Int { (dict[k] as? NSNumber)?.intValue ?? 0 }

        switch type {
        case "ready":
            return (.ready, nil)
        case "contentChanged":
            return (.contentChanged(id: str("id"), version: int("version"), text: str("text")), nil)
        case "selectionChanged":
            let range = EditorTextRange(startLine: int("startLine"), startColumn: int("startColumn"),
                                  endLine: int("endLine"), endColumn: int("endColumn"))
            return (.selectionChanged(id: str("id"), range: range, text: str("text")), nil)
        case "cursor":
            return (.cursor(id: str("id"), line: int("line"), column: int("column")), nil)
        case "save":
            return (.save(id: str("id")), nil)
        case "log":
            return (.log(level: str("level"), message: str("message")), nil)
        case "response":
            var response = MonacoResponse()
            response.text = dict["text"] as? String
            response.ok = (dict["ok"] as? Bool) ?? false
            if let hunks = dict["hunks"] as? [[String: Any]] {
                response.hunks = hunks.map { h in
                    func n(_ k: String) -> Int { (h[k] as? NSNumber)?.intValue ?? 0 }
                    return DiffHunk(index: n("index"), originalStart: n("originalStart"), originalEnd: n("originalEnd"),
                                    modifiedStart: n("modifiedStart"), modifiedEnd: n("modifiedEnd"))
                }
            }
            return (nil, (str("requestId"), response))
        default:
            return (nil, nil)
        }
    }
}
