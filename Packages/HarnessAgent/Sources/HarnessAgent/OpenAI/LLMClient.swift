import Foundation

/// A model backend the orchestrator can drive without knowing which HTTP API it speaks.
/// Both `ResponsesClient` (OpenAI Responses) and `ChatCompletionsClient` (OpenRouter and any
/// OpenAI-compatible chat endpoint) translate their wire format into the same normalized
/// `ResponseStreamEvent` stream, so `AgentOrchestrator` stays identical across providers.
public protocol LLMClient: Sendable {
    func streamTurn(
        model: String,
        instructions: String,
        input: [ResponseItem],
        tools: [FunctionToolDefinition],
        reasoning: ReasoningConfig,
        sessionID: String,
        promptCacheKey: String?
    ) -> AsyncThrowingStream<ResponseStreamEvent, any Error>
}

extension ResponsesClient: LLMClient {
    public func streamTurn(
        model: String, instructions: String, input: [ResponseItem], tools: [FunctionToolDefinition],
        reasoning: ReasoningConfig, sessionID: String, promptCacheKey: String?
    ) -> AsyncThrowingStream<ResponseStreamEvent, any Error> {
        let request = ResponsesRequest(model: model, instructions: instructions, input: input,
                                       tools: tools, reasoning: reasoning, promptCacheKey: promptCacheKey)
        return stream(request, sessionID: sessionID)
    }
}
