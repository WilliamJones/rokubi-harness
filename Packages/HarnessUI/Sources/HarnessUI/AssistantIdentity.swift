import HarnessAgent

/// What to call the assistant in the UI and in its own instructions. "ChatGPT" is only accurate
/// for OpenAI-served models; through OpenRouter we name the actual model.
enum AssistantIdentity {
    /// Display name for the chat pane, placeholders, and approval cards.
    static func name(mode: AccountInfo.Mode?, model: ModelInfo?) -> String {
        switch mode {
        case .openRouter:
            guard let model else { return "Assistant" }
            // OpenRouter names look like "Poolside: Laguna S 2.1" — drop the vendor prefix.
            if let colon = model.name.firstIndex(of: ":") {
                let short = model.name[model.name.index(after: colon)...].trimmingCharacters(in: .whitespaces)
                return short.isEmpty ? model.name : short
            }
            return model.name
        case .chatGPT, .apiKey, nil:
            return "ChatGPT"
        }
    }

    /// Provider label for the system prompt.
    static func providerName(for mode: AccountInfo.Mode?) -> String {
        switch mode {
        case .openRouter: "OpenRouter"
        case .chatGPT: "OpenAI (ChatGPT sign-in)"
        case .apiKey: "OpenAI"
        case nil: "the configured provider"
        }
    }
}
