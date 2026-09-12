import Foundation
import HarnessCore

/// Decides whether a tool call may run. Implemented by the permission engine (M3);
/// the M2 default allows read-only classes and denies the rest.
public protocol PermissionGate: Sendable {
    func decide(tool: any Tool, arguments: JSONValue, summary: String) async -> PermissionDecision
}

public enum PermissionDecision: Sendable, Equatable {
    case allow
    case deny(reason: String)
}

public struct ReadOnlyGate: PermissionGate {
    public init() {}
    public func decide(tool: any Tool, arguments: JSONValue, summary: String) async -> PermissionDecision {
        switch tool.permission {
        case .read, .search, .gitRead: .allow
        default: .deny(reason: "Autonomy is Read Only")
        }
    }
}

/// Runs one user turn: stream → execute tool calls → append outputs → repeat until the
/// model stops calling tools. Emits `AgentEvent`s for the UI and mutates the conversation
/// through `apply`, which the caller runs on the main actor.
public actor AgentOrchestrator {
    public struct Configuration: Sendable {
        public var model: String
        public var reasoning = ReasoningConfig()
        public var maxToolRounds = 60
        public init(model: String) { self.model = model }
    }

    private let client: any LLMClient
    private var tools: ToolRegistry
    private var gate: any PermissionGate
    private var currentStream: Task<Void, Never>?

    public init(client: any LLMClient, tools: ToolRegistry, gate: any PermissionGate) {
        self.client = client
        self.tools = tools
        self.gate = gate
    }

    public func update(tools: ToolRegistry, gate: any PermissionGate) {
        self.tools = tools
        self.gate = gate
    }

    /// `conversation` is a snapshot; new entries are reported through `.entryAppended`.
    public func run(conversation: Conversation, instructions: String, configuration: Configuration,
                    context: ToolContext) -> AsyncStream<AgentEvent> {
        let (stream, continuation) = AsyncStream<AgentEvent>.makeStream()
        let task = Task { [client, tools, gate] in
            var convo = conversation
            continuation.yield(.turnStarted)
            var outcome: TurnOutcome = .completed
            var roundsUsed = 0
            var lastRoundHadCalls = false
            rounds: for _ in 0..<configuration.maxToolRounds {
                roundsUsed += 1
                let events = client.streamTurn(
                    model: configuration.model, instructions: instructions, input: convo.inputItems,
                    tools: tools.definitions, reasoning: configuration.reasoning,
                    sessionID: convo.id, promptCacheKey: convo.id)
                var calls: [(id: String, callID: String, name: String, arguments: String)] = []
                var items: [String: ResponseItem] = [:]
                var texts: [String: String] = [:]
                var summaries: [String: String] = [:]

                do {
                    for try await event in events {
                        try Task.checkCancellation()
                        switch event {
                        case .outputItemAdded(_, let item):
                            if let id = item.id { items[id] = item }
                        case .outputTextDelta(let id, let delta):
                            texts[id, default: ""] += delta
                            continuation.yield(.assistantTextDelta(itemID: id, delta: delta))
                        case .reasoningSummaryDelta(let id, let delta):
                            summaries[id, default: ""] += delta
                            continuation.yield(.reasoningDelta(itemID: id, delta: delta))
                        case .outputItemDone(_, let item):
                            let id = item.id ?? UUID().uuidString
                            switch item.type {
                            case "message":
                                let text = item.text.isEmpty ? texts[id, default: ""] : item.text
                                let entry = ConversationEntry.assistant(id: id, text: text)
                                convo.append(entry)
                                continuation.yield(.entryAppended(entry))
                            case "reasoning":
                                let summary = (item.summary ?? []).map(\.text).joined(separator: "\n")
                                let entry = ConversationEntry.reasoning(id: id, summary: summary.isEmpty ? summaries[id, default: ""] : summary,
                                                                        encryptedContent: item.encrypted_content)
                                convo.append(entry)
                                continuation.yield(.entryAppended(entry))
                            case "function_call":
                                let call = (id: id, callID: item.call_id ?? id, name: item.name ?? "", arguments: item.arguments ?? "{}")
                                calls.append(call)
                                let entry = ConversationEntry.functionCall(id: id, callID: call.callID, name: call.name, arguments: call.arguments)
                                convo.append(entry)
                                continuation.yield(.entryAppended(entry))
                            default:
                                break
                            }
                        case .completed(let usage):
                            if let usage {
                                continuation.yield(.usage(input: usage.input_tokens, output: usage.output_tokens))
                            }
                        case .failed(let message), .error(_, let message):
                            throw ToolError(message)
                        case .incomplete(let reason):
                            let note = ConversationEntry.note(id: UUID().uuidString, text: "Response incomplete: \(reason ?? "unknown")")
                            continuation.yield(.entryAppended(note))
                        default:
                            break
                        }
                    }
                } catch is CancellationError {
                    outcome = .cancelled
                    break rounds
                } catch {
                    // A cancelled URLSession surfaces as a transport error, not CancellationError.
                    outcome = Task.isCancelled ? .cancelled : .failed(error.localizedDescription)
                    break rounds
                }

                lastRoundHadCalls = !calls.isEmpty
                if calls.isEmpty { break }

                // Execute tool calls (sequentially — edits must not race; reads are fast enough).
                for call in calls {
                    if Task.isCancelled { outcome = .cancelled; break rounds }
                    let output = await Self.execute(call, tools: tools, gate: gate, context: context, continuation: continuation)
                    let entry = ConversationEntry.functionCallOutput(id: UUID().uuidString, callID: call.callID,
                                                                     output: output.modelText, activity: output.activity)
                    convo.append(entry)
                    continuation.yield(.entryAppended(entry))
                }

                // A round that reported completion (plus at most a final plan update) alongside a closing
                // message is the end of the task; no need for one more "anything else?" round trip.
                let reportedAndClosed = calls.contains { $0.name == "report_completion" }
                    && calls.allSatisfy { $0.name == "report_completion" || $0.name == "update_plan" }
                    && !texts.values.joined().isEmpty
                if reportedAndClosed { lastRoundHadCalls = false; break }
            }
            if case .completed = outcome, lastRoundHadCalls, roundsUsed >= configuration.maxToolRounds {
                // Ran out of rounds with tool calls still pending — say so instead of looking finished.
                let note = ConversationEntry.note(id: UUID().uuidString,
                                                  text: "Stopped after \(configuration.maxToolRounds) tool rounds. Send another message to continue.")
                convo.append(note)
                continuation.yield(.entryAppended(note))
                outcome = .failed("Reached the limit of \(configuration.maxToolRounds) tool rounds")
            }
            continuation.yield(.turnFinished(outcome))
            continuation.finish()
        }
        currentStream = task
        continuation.onTermination = { _ in task.cancel() }
        return stream
    }

    public func cancel() {
        currentStream?.cancel()
    }

    private static func execute(_ call: (id: String, callID: String, name: String, arguments: String),
                                tools: ToolRegistry, gate: any PermissionGate, context: ToolContext,
                                continuation: AsyncStream<AgentEvent>.Continuation) async -> ToolOutput {
        guard let tool = tools[call.name] else {
            let a = ActivityRecord(kind: .other, title: "Unknown tool \(call.name)", succeeded: false)
            continuation.yield(.activityFinished(callID: call.callID, activity: a))
            return ToolOutput("Error: unknown tool \(call.name)", activity: a)
        }
        let arguments = JSONValue.parse(call.arguments) ?? .object([:])
        let summary = tool.summary(for: arguments)
        let started = ActivityRecord(kind: kind(for: tool), title: summary)
        continuation.yield(.activityStarted(callID: call.callID, activity: started))

        switch await gate.decide(tool: tool, arguments: arguments, summary: summary) {
        case .deny(let reason):
            let a = ActivityRecord(kind: started.kind, title: summary, detail: "Not permitted: \(reason)", succeeded: false)
            continuation.yield(.activityFinished(callID: call.callID, activity: a))
            return ToolOutput("Permission denied: \(reason). Ask the user or choose another approach.", activity: a)
        case .allow:
            break
        }

        do {
            let output = try await tool.execute(arguments, context: context)
            continuation.yield(.activityFinished(callID: call.callID, activity: output.activity))
            return ToolOutput(String(output.modelText.prefix(60_000)), activity: output.activity)
        } catch {
            let a = ActivityRecord(kind: started.kind, title: summary, detail: error.localizedDescription, succeeded: false)
            continuation.yield(.activityFinished(callID: call.callID, activity: a))
            return ToolOutput("Error: \(error.localizedDescription)", activity: a)
        }
    }

    private static func kind(for tool: any Tool) -> ActivityRecord.Kind {
        switch tool.permission {
        case .read: .read
        case .search: .search
        case .edit: .edit
        case .create: .create
        case .delete: .delete
        case .run, .packageInstall, .network: .run
        case .gitRead, .gitWrite: .git
        }
    }
}
