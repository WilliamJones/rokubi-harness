import Foundation

/// What the UI sees while a turn runs.
public enum AgentEvent: Sendable, Equatable {
    case turnStarted
    case assistantTextDelta(itemID: String, delta: String)
    case reasoningDelta(itemID: String, delta: String)
    case activityStarted(callID: String, activity: ActivityRecord)
    case activityFinished(callID: String, activity: ActivityRecord)
    case permissionRequested(PermissionRequest)
    case entryAppended(ConversationEntry)
    case usage(input: Int, output: Int)
    case turnFinished(TurnOutcome)
}

public enum TurnOutcome: Sendable, Equatable {
    case completed
    case cancelled
    case failed(String)
}

/// An approval the orchestrator is waiting on (PRD §18 — inline, never modal).
public struct PermissionRequest: Sendable, Equatable, Identifiable {
    public let id: String
    public let toolName: String
    public let summary: String
    public let detail: String?
    public init(id: String, toolName: String, summary: String, detail: String?) {
        self.id = id; self.toolName = toolName; self.summary = summary; self.detail = detail
    }
}
