import Foundation
import Testing
@testable import HarnessAgent

@Suite struct ResponsesTests {
    @Test func decodesStreamingEvents() {
        let created = SSEEvent(event: "response.created", data: #"{"type":"response.created","response":{"id":"resp_1"}}"#)
        #expect(ResponseStreamEvent.decode(created) == .created(responseID: "resp_1"))

        let delta = SSEEvent(event: nil, data: #"{"type":"response.output_text.delta","item_id":"msg_1","delta":"Hel"}"#)
        #expect(ResponseStreamEvent.decode(delta) == .outputTextDelta(itemID: "msg_1", delta: "Hel"))

        let call = SSEEvent(event: nil, data: #"{"type":"response.output_item.done","output_index":1,"item":{"type":"function_call","id":"fc_1","call_id":"call_1","name":"read_file","arguments":"{\"path\":\"a.ts\"}","status":"completed"}}"#)
        guard case let .outputItemDone(index, item)? = ResponseStreamEvent.decode(call) else {
            Issue.record("expected outputItemDone"); return
        }
        #expect(index == 1)
        #expect(item.name == "read_file")
        #expect(item.call_id == "call_1")

        let reasoning = SSEEvent(event: nil, data: #"{"type":"response.output_item.done","item":{"type":"reasoning","id":"rs_1","summary":[{"type":"summary_text","text":"Thinking"}],"encrypted_content":"abc"}}"#)
        guard case let .outputItemDone(_, r)? = ResponseStreamEvent.decode(reasoning) else { Issue.record("expected reasoning"); return }
        #expect(r.encrypted_content == "abc")
        #expect(r.summary?.first?.text == "Thinking")

        let done = SSEEvent(event: nil, data: #"{"type":"response.completed","response":{"id":"resp_1","usage":{"input_tokens":10,"output_tokens":5}}}"#)
        #expect(ResponseStreamEvent.decode(done) == .completed(usage: ResponseUsage(input_tokens: 10, output_tokens: 5)))

        #expect(ResponseStreamEvent.decode(SSEEvent(event: nil, data: "[DONE]")) == nil)
        let err = SSEEvent(event: "error", data: #"{"type":"error","code":"rate_limit","message":"slow down"}"#)
        #expect(ResponseStreamEvent.decode(err) == .error(code: "rate_limit", message: "slow down"))
    }

    @Test func requestBodyHasChatGPTBackendInvariants() throws {
        let req = ResponsesRequest(model: "gpt-5.4", instructions: "sys", input: [.userMessage("hi")], tools: [])
        let json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(req)) as! [String: Any]
        #expect(json["store"] as? Bool == false)
        #expect(json["stream"] as? Bool == true)
        #expect((json["include"] as? [String]) == ["reasoning.encrypted_content"])
        #expect(json["tool_choice"] as? String == "auto")
        let input = json["input"] as! [[String: Any]]
        #expect(input[0]["role"] as? String == "user")
        let content = input[0]["content"] as! [[String: Any]]
        #expect(content[0]["type"] as? String == "input_text")
    }

    @Test func conversationRoundTripsToInputItems() {
        var c = Conversation()
        c.append(.user(id: "u1", text: "Fix tests", context: [ContextAttachment(label: "@a.ts", body: "let a = 1")]))
        c.append(.reasoning(id: "rs_1", summary: "plan", encryptedContent: "enc"))
        c.append(.functionCall(id: "fc_1", callID: "call_1", name: "read_file", arguments: "{}"))
        c.append(.functionCallOutput(id: "o1", callID: "call_1", output: "contents", activity: nil))
        c.append(.note(id: "n1", text: "local only"))
        c.append(.assistant(id: "m1", text: "Done"))

        let items = c.inputItems
        #expect(items.count == 5)
        #expect(items[0].text.contains("<context source=\"@a.ts\">"))
        #expect(items[1].type == "reasoning" && items[1].encrypted_content == "enc" && items[1].id == "rs_1")
        #expect(items[2].type == "function_call" && items[2].call_id == "call_1")
        #expect(items[3].type == "function_call_output" && items[3].output == "contents")
        #expect(items[4].role == "assistant")
        #expect(c.title == "Fix tests")
    }

    @Test func reasoningWithoutEncryptedContentIsNotResent() {
        var c = Conversation()
        c.append(.reasoning(id: "rs", summary: "x", encryptedContent: nil))
        #expect(c.inputItems.isEmpty)
    }
}
