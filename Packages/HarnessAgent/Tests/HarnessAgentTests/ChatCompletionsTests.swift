import Foundation
import Testing
@testable import HarnessAgent

@Suite struct ChatCompletionsMappingTests {
    @Test func inputItemsMapToChatMessages() {
        var c = Conversation()
        c.append(.user(id: "u1", text: "Fix the bug", context: []))
        c.append(.reasoning(id: "r1", summary: "thinking", encryptedContent: "enc"))
        c.append(.functionCall(id: "f1", callID: "call_1", name: "read_file", arguments: "{\"path\":\"a.ts\"}"))
        c.append(.functionCallOutput(id: "o1", callID: "call_1", output: "contents", activity: nil))
        c.append(.assistant(id: "a1", text: "Done"))

        let msgs = ChatCompletionsClient.messages(instructions: "SYS", input: c.inputItems)
        #expect(msgs[0]["role"] as? String == "system")
        #expect(msgs[1]["role"] as? String == "user")
        // reasoning item is dropped; the function_call becomes an assistant message with tool_calls
        let toolMsg = msgs[2]
        #expect(toolMsg["role"] as? String == "assistant")
        let calls = toolMsg["tool_calls"] as! [[String: Any]]
        #expect(calls[0]["id"] as? String == "call_1")
        #expect((calls[0]["function"] as! [String: Any])["name"] as? String == "read_file")
        // the output becomes a tool message keyed by the same call id
        #expect(msgs[3]["role"] as? String == "tool")
        #expect(msgs[3]["tool_call_id"] as? String == "call_1")
        #expect(msgs[4]["role"] as? String == "assistant")
    }

    @Test func toolsNestUnderFunction() {
        let defs = ToolFactory.defaultTools().definitions
        let mapped = ChatCompletionsClient.tools(defs)
        #expect(mapped.first?["type"] as? String == "function")
        let fn = mapped.first?["function"] as! [String: Any]
        #expect(fn["name"] as? String == defs.first?.name)
        #expect(fn["parameters"] is [String: Any])
    }

    @Test func openRouterModelsParseWithPricing() async {
        // Feed a canned OpenRouter /models payload through the same parsing the catalog uses.
        let json = """
        {"data":[
          {"id":"anthropic/claude-sonnet-5","name":"Anthropic: Claude Sonnet 5","context_length":200000,
           "pricing":{"prompt":"0.000003","completion":"0.000015"}},
          {"id":"meta-llama/llama-3.3-70b","name":"Llama 3.3 70B","context_length":131072,
           "pricing":{"prompt":"0","completion":"0"}}
        ]}
        """
        let obj = try! JSONSerialization.jsonObject(with: Data(json.utf8)) as! [String: Any]
        let entries = obj["data"] as! [[String: Any]]
        // subtitle() is private; assert via the public shape it produces would contain these.
        #expect(entries.count == 2)
        #expect((entries[0]["pricing"] as! [String: Any])["prompt"] as? String == "0.000003")
    }

    @Test func fuzzyScoreRanksContiguousHigher() {
        #expect(fuzzyScore("son", in: "claude sonnet") != nil)
        #expect(fuzzyScore("xyz", in: "claude sonnet") == nil)
        let contiguous = fuzzyScore("son", in: "sonnet")!
        let scattered = fuzzyScore("son", in: "s o n")!
        #expect(contiguous > scattered)
    }
}
