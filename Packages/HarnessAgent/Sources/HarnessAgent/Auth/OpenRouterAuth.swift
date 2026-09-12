import Foundation

/// OpenRouter: a single API key that fronts hundreds of models from many providers, over the
/// Chat Completions API. Key lives in the Keychain and is read lazily (never in init, so app
/// launch can't block on a Keychain prompt).
public actor OpenRouterAuth: AuthProvider {
    public nonisolated let baseURL = OpenAIEndpoints.openRouterBaseURL
    public nonisolated let api = ModelAPIStyle.chatCompletions
    public nonisolated let providerLabel = "OpenRouter"

    private let keychain: Keychain
    private let keychainAccount = "openrouter.apiKey"
    private var key: String?
    private var ephemeral = false
    private var loaded = false

    public init(keychain: Keychain = Keychain()) {
        self.keychain = keychain
    }

    private func ensureLoaded() {
        guard !loaded else { return }
        loaded = true
        if let seeded = OpenAIEndpoints.testOverride(env: "ROKUBI_OPENROUTER_KEY", flag: "--openrouter-key"), !seeded.isEmpty {
            key = seeded
            ephemeral = true   // never persisted
        } else {
            key = keychain.read(keychainAccount).flatMap { String(data: $0, encoding: .utf8) }
        }
    }

    public var isConfigured: Bool { ensureLoaded(); return key != nil }
    /// Seeded from a test flag/env rather than the Keychain.
    public var isEphemeral: Bool { ensureLoaded(); return ephemeral }

    public var account: AccountInfo { AccountInfo(mode: .openRouter) }

    public func set(key newKey: String) throws {
        let trimmed = newKey.trimmingCharacters(in: .whitespacesAndNewlines)
        key = trimmed
        loaded = true
        ephemeral = false
        try keychain.write(Data(trimmed.utf8), account: keychainAccount)
    }

    public func clear() {
        key = nil
        loaded = true
        keychain.delete(keychainAccount)
    }

    public func authHeaders() async throws -> [String: String] {
        ensureLoaded()
        guard let key else { throw AuthError.notSignedIn }
        return [
            "Authorization": "Bearer \(key)",
            "HTTP-Referer": OpenAIEndpoints.openRouterReferer,
            "X-Title": OpenAIEndpoints.openRouterTitle,
        ]
    }

    public func invalidate() async {}
}
