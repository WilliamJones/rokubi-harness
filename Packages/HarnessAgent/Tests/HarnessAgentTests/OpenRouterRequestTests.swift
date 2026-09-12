import Foundation
import Testing
@testable import HarnessAgent

/// Headless check of the whole OpenRouter integration path: provider → client selection →
/// the exact HTTP request that would be sent, without a window or a network.
@Suite struct OpenRouterRequestTests {
    @Test func openRouterProviderBuildsAChatCompletionsRequest() async throws {
        setenv("ROKUBI_OPENROUTER_KEY", "sk-or-test", 1)
        defer { unsetenv("ROKUBI_OPENROUTER_KEY") }

        let auth = OpenRouterAuth()
        #expect(auth.api == .chatCompletions)
        #expect(await auth.isConfigured)
        #expect(await auth.account.mode == .openRouter)

        let client = ChatCompletionsClient(auth: auth)
        var convo = Conversation()
        convo.append(.user(id: "u", text: "hello", context: []))
        let request = try await client.makeRequest(
            model: "anthropic/claude-sonnet-5", instructions: "SYS", input: convo.inputItems,
            tools: ToolFactory.defaultTools().definitions, reasoning: ReasoningConfig())

        #expect(request.url?.absoluteString == "https://openrouter.ai/api/v1/chat/completions")
        #expect(request.httpMethod == "POST")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer sk-or-test")
        #expect(request.value(forHTTPHeaderField: "HTTP-Referer") == OpenAIEndpoints.openRouterReferer)
        #expect(request.value(forHTTPHeaderField: "X-Title") == OpenAIEndpoints.openRouterTitle)
        #expect(request.value(forHTTPHeaderField: "Accept") == "text/event-stream")

        let body = try JSONSerialization.jsonObject(with: request.httpBody!) as! [String: Any]
        #expect(body["model"] as? String == "anthropic/claude-sonnet-5")
        #expect(body["stream"] as? Bool == true)
        let messages = body["messages"] as! [[String: Any]]
        #expect(messages[0]["role"] as? String == "system" && messages[0]["content"] as? String == "SYS")
        #expect(messages[1]["role"] as? String == "user")
        let tools = body["tools"] as! [[String: Any]]
        #expect(!tools.isEmpty && tools.allSatisfy { ($0["type"] as? String) == "function" && $0["function"] != nil })
        // Responses-only fields must not leak into the chat body.
        #expect(body["store"] == nil && body["include"] == nil && body["input"] == nil)
    }

    @Test func openAIProvidersStayOnResponsesAPI() {
        #expect(APIKeyAuth().api == .responses)
        #expect(ChatGPTAuth().api == .responses)
    }
}
