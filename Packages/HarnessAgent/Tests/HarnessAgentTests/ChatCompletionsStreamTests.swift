import Foundation
import Testing
@testable import HarnessAgent

/// The Chat Completions stream sends tool-call arguments in fragments across many chunks
/// (and text alongside). This verifies they're reassembled into the same normalized events
/// the orchestrator consumes from the Responses API.
@Suite struct ChatCompletionsStreamTests {
    private func chunk(_ json: String) -> SSEEvent { SSEEvent(event: nil, data: json) }

    @Test func reassemblesTextAndFragmentedToolCalls() {
        let events = ChatCompletionsClient.replay([
            chunk(#"{"choices":[{"delta":{"role":"assistant","content":"I'll "}}]}"#),
            chunk(#"{"choices":[{"delta":{"content":"read it."}}]}"#),
            chunk(#"{"choices":[{"delta":{"tool_calls":[{"index":0,"id":"call_abc","type":"function","function":{"name":"read_file","arguments":""}}]}}]}"#),
            chunk(#"{"choices":[{"delta":{"tool_calls":[{"index":0,"function":{"arguments":"{\"pa"}}]}}]}"#),
            chunk(#"{"choices":[{"delta":{"tool_calls":[{"index":0,"function":{"arguments":"th\":\"a.ts\"}"}}]}}]}"#),
            chunk(#"{"choices":[{"delta":{"tool_calls":[{"index":1,"id":"call_def","type":"function","function":{"name":"grep","arguments":"{\"pattern\":\"x\"}"}}]}}]}"#),
            chunk(#"{"choices":[{"delta":{},"finish_reason":"tool_calls"}],"usage":{"prompt_tokens":100,"completion_tokens":20,"total_tokens":120}}"#),
            SSEEvent(event: nil, data: "[DONE]"),
        ])

        // Text streamed as deltas, then finalized as one assistant message item.
        let deltas = events.compactMap { e -> String? in if case let .outputTextDelta(_, d) = e { return d }; return nil }
        #expect(deltas.joined() == "I'll read it.")

        let done = events.compactMap { e -> ResponseItem? in if case let .outputItemDone(_, item) = e { return item }; return nil }
        let message = done.first { $0.type == "message" }
        #expect(message?.text == "I'll read it.")

        // Both tool calls, with fragmented arguments joined and ids preserved as call_id.
        let calls = done.filter { $0.type == "function_call" }
        #expect(calls.count == 2)
        #expect(calls[0].call_id == "call_abc")
        #expect(calls[0].name == "read_file")
        #expect(calls[0].arguments == #"{"path":"a.ts"}"#)
        #expect(calls[1].call_id == "call_def")
        #expect(calls[1].name == "grep")

        // Usage surfaces from the final chunk.
        #expect(events.contains { if case let .completed(u) = $0 { return u?.input_tokens == 100 && u?.output_tokens == 20 }; return false })
    }

    @Test func plainTextOnlyProducesOneMessageAndNoCalls() {
        let events = ChatCompletionsClient.replay([
            chunk(#"{"choices":[{"delta":{"content":"Hello"}}]}"#),
            chunk(#"{"choices":[{"delta":{},"finish_reason":"stop"}]}"#),
        ])
        let done = events.compactMap { e -> ResponseItem? in if case let .outputItemDone(_, i) = e { return i }; return nil }
        #expect(done.count == 1 && done[0].type == "message" && done[0].text == "Hello")
    }
}
