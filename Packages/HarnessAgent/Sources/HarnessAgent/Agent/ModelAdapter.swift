import Foundation

/// PRD §26 — the UI depends on this, not on OpenAI types. `AgentSession` (HarnessUI) is
/// the only consumer; `AgentOrchestrator` is the OpenAI-backed implementation behind it.
public protocol ModelAdapter: Sendable {
    func run(conversation: Conversation, instructions: String, model: String, context: ToolContext) async -> AsyncStream<AgentEvent>
    func cancel() async
}

extension AgentOrchestrator: ModelAdapter {
    public func run(conversation: Conversation, instructions: String, model: String, context: ToolContext) async -> AsyncStream<AgentEvent> {
        run(conversation: conversation, instructions: instructions, configuration: Configuration(model: model), context: context)
    }
}
