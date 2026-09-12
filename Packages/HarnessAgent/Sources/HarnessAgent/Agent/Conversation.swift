import Foundation

/// Everything the model has said or done in a conversation, in order. With
/// `store: false` the full list is resent every turn, so it *is* the transcript.
public enum ConversationEntry: Codable, Sendable, Equatable, Identifiable {
    case user(id: String, text: String, context: [ContextAttachment])
    case assistant(id: String, text: String)
    case reasoning(id: String, summary: String, encryptedContent: String?)
    case functionCall(id: String, callID: String, name: String, arguments: String)
    case functionCallOutput(id: String, callID: String, output: String, activity: ActivityRecord?)
    case note(id: String, text: String)   // local-only (errors, permission decisions); never sent

    public var id: String {
        switch self {
        case .user(let id, _, _), .assistant(let id, _), .reasoning(let id, _, _),
             .functionCall(let id, _, _, _), .functionCallOutput(let id, _, _, _), .note(let id, _):
            id
        }
    }

    /// Wire form for `input`. Local notes are dropped.
    public var responseItem: ResponseItem? {
        switch self {
        case .user(_, let text, let context):
            let extra = context.map(\.rendered).joined(separator: "\n\n")
            return .userMessage(extra.isEmpty ? text : text + "\n\n" + extra)
        case .assistant(_, let text):
            return .assistantMessage(text)
        case .reasoning(let id, let summary, let encrypted):
            guard let encrypted else { return nil }
            return ResponseItem(type: "reasoning", id: id,
                                summary: summary.isEmpty ? [] : [.init(type: "summary_text", text: summary)],
                                encrypted_content: encrypted)
        case .functionCall(_, let callID, let name, let arguments):
            return ResponseItem(type: "function_call", call_id: callID, name: name, arguments: arguments)
        case .functionCallOutput(_, let callID, let output, _):
            return .functionCallOutput(callID: callID, output: output)
        case .note:
            return nil
        }
    }
}

/// Something the user attached with `@` (a file, selection, terminal output…).
public struct ContextAttachment: Codable, Sendable, Equatable, Hashable {
    public var label: String       // e.g. "@src/auth.ts"
    public var body: String

    public init(label: String, body: String) { self.label = label; self.body = body }

    var rendered: String { "<context source=\"\(label)\">\n\(body)\n</context>" }
}

/// Compact, user-facing record of what a tool call did (PRD §6.4 "Everything Is Observable").
public struct ActivityRecord: Codable, Sendable, Equatable {
    public enum Kind: String, Codable, Sendable { case search, read, edit, create, delete, run, git, plan, verify, other }
    public var kind: Kind
    public var title: String        // "Read src/auth.ts"
    public var detail: String?      // expandable body (command output tail, matches…)
    public var succeeded: Bool

    public init(kind: Kind, title: String, detail: String? = nil, succeeded: Bool = true) {
        self.kind = kind; self.title = title; self.detail = detail; self.succeeded = succeeded
    }
}

public struct Conversation: Codable, Sendable, Identifiable, Equatable {
    public var id: String
    public var title: String
    public var createdAt: Date
    public var updatedAt: Date
    public var entries: [ConversationEntry]
    public var totalInputTokens = 0
    public var totalOutputTokens = 0

    public init(id: String = UUID().uuidString, title: String = "New conversation") {
        self.id = id
        self.title = title
        self.createdAt = Date()
        self.updatedAt = createdAt
        self.entries = []
    }

    public var isEmpty: Bool { entries.isEmpty }

    public mutating func append(_ entry: ConversationEntry) {
        entries.append(entry)
        updatedAt = Date()
        if title == "New conversation", case .user(_, let text, _) = entry {
            title = String(text.split(whereSeparator: \.isNewline).first ?? "").prefix(60).description
        }
    }

    public var inputItems: [ResponseItem] { entries.compactMap(\.responseItem) }
}
