import Foundation
import HarnessCore

/// Permission class a tool falls under (PRD §18). The engine maps classes to allow/ask/deny.
public enum PermissionClass: String, Codable, Sendable, CaseIterable {
    case read, search, edit, create, delete, run, gitRead, gitWrite, network, packageInstall
}

/// Result of a tool call: what the model sees, plus what the user sees.
public struct ToolOutput: Sendable {
    public var modelText: String
    public var activity: ActivityRecord

    public init(_ modelText: String, activity: ActivityRecord) {
        self.modelText = modelText
        self.activity = activity
    }
}

/// One step of a contextual plan (PRD §19).
public struct PlanStep: Codable, Sendable, Equatable, Identifiable {
    public enum Status: String, Codable, Sendable { case pending, inProgress = "in_progress", done, skipped }
    public var title: String
    public var status: Status
    public var id: String { title }
    public init(title: String, status: Status) { self.title = title; self.status = status }
}

/// Structured end-of-task report (PRD §31).
public struct CompletionReport: Codable, Sendable, Equatable {
    public struct Verification: Codable, Sendable, Equatable, Identifiable {
        public enum Status: String, Codable, Sendable { case passed, failed, skipped, notRun = "not_run" }
        public var name: String
        public var status: Status
        public var detail: String?
        public var id: String { name }
    }
    public var summary: String
    public var changedFiles: [String]
    public var verifications: [Verification]
    public var notes: String?
}

/// Side channel from tools to the UI (plan, completion, file changes). Implemented on the main actor.
public protocol ToolEventSink: Sendable {
    func planUpdated(_ steps: [PlanStep]) async
    func completionReported(_ report: CompletionReport) async
    func fileChanged(_ url: URL) async
    func diagnosticsReported(_ problems: [Problem], source: String) async
}

public struct NullToolEventSink: ToolEventSink {
    public init() {}
    public func planUpdated(_ steps: [PlanStep]) async {}
    public func completionReported(_ report: CompletionReport) async {}
    public func fileChanged(_ url: URL) async {}
    public func diagnosticsReported(_ problems: [Problem], source: String) async {}
}

/// Everything a tool may touch. Handed to `Tool.execute`.
public struct ToolContext: Sendable {
    public let files: FileService
    public let ignore: IgnoreRules
    public let search: SearchService
    public let checkpoints: CheckpointStore?
    public let sink: any ToolEventSink
    public let conversationID: String
    public let taskID: String

    public init(files: FileService, ignore: IgnoreRules, checkpoints: CheckpointStore? = nil,
                sink: any ToolEventSink = NullToolEventSink(), conversationID: String, taskID: String) {
        self.files = files
        self.ignore = ignore
        self.search = SearchService(files: files, ignore: ignore)
        self.checkpoints = checkpoints
        self.sink = sink
        self.conversationID = conversationID
        self.taskID = taskID
    }

    /// Snapshot before mutating `url` and tell the UI it changed.
    func willMutate(_ url: URL, label: String) async throws {
        try await checkpoints?.snapshot(url, taskID: taskID, label: label)
    }

    func didMutate(_ url: URL) async {
        await sink.fileChanged(url)
    }
}

/// A capability exposed to the model as a function tool.
public protocol Tool: Sendable {
    var name: String { get }
    var description: String { get }
    var parameters: JSONValue { get }
    var permission: PermissionClass { get }

    /// One-line human summary of a pending call, shown in approval cards and activity rows.
    func summary(for arguments: JSONValue) -> String
    /// The thing the permission rules match on (a path, a command…).
    func subject(for arguments: JSONValue) -> String?
    func execute(_ arguments: JSONValue, context: ToolContext) async throws -> ToolOutput
}

extension Tool {
    public var definition: FunctionToolDefinition {
        FunctionToolDefinition(name: name, description: description, parameters: parameters, strict: false)
    }
    public func subject(for arguments: JSONValue) -> String? { nil }
}

/// The set of tools a turn may call.
public struct ToolRegistry: Sendable {
    public private(set) var tools: [String: any Tool] = [:]
    public private(set) var order: [String] = []

    public init(_ tools: [any Tool] = []) {
        for t in tools { register(t) }
    }

    public mutating func register(_ tool: any Tool) {
        if tools[tool.name] == nil { order.append(tool.name) }
        tools[tool.name] = tool
    }

    public subscript(name: String) -> (any Tool)? { tools[name] }

    public var definitions: [FunctionToolDefinition] { order.compactMap { tools[$0]?.definition } }
}

public struct ToolError: LocalizedError, Sendable {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var errorDescription: String? { message }
}

// MARK: - Schema helpers

enum Schema {
    static func object(_ properties: [String: JSONValue], required: [String]) -> JSONValue {
        .object([
            "type": .string("object"),
            "properties": .object(properties),
            "required": .array(required.map(JSONValue.string)),
            "additionalProperties": .bool(false),
        ])
    }
    static func string(_ description: String, enumValues: [String]? = nil) -> JSONValue {
        var o: [String: JSONValue] = ["type": .string("string"), "description": .string(description)]
        if let enumValues { o["enum"] = .array(enumValues.map(JSONValue.string)) }
        return .object(o)
    }
    static func integer(_ description: String) -> JSONValue {
        .object(["type": .string("integer"), "description": .string(description)])
    }
    static func boolean(_ description: String) -> JSONValue {
        .object(["type": .string("boolean"), "description": .string(description)])
    }
    static func array(_ description: String, items: JSONValue) -> JSONValue {
        .object(["type": .string("array"), "description": .string(description), "items": items])
    }
}

extension JSONValue {
    func string(_ key: String) -> String? { self[key]?.stringValue }
    func int(_ key: String) -> Int? { self[key]?.intValue }
    func bool(_ key: String) -> Bool? { self[key]?.boolValue }
    func requiredString(_ key: String) throws -> String {
        guard let s = string(key), !s.isEmpty else { throw ToolError("Missing required argument `\(key)`") }
        return s
    }
}
