import Foundation

/// Platform-API fallback: a user-supplied `sk-…` key stored in the Keychain.
public actor APIKeyAuth: AuthProvider {
    /// Points API-key mode at a local mock server for tests (env or `--base-url`).
    public nonisolated let baseURL = OpenAIEndpoints.apiBaseURL

    private let keychain: Keychain
    private let keychainAccount = "openai.apiKey"
    private var key: String?
    private var ephemeral = false
    private var loaded = false

    public init(keychain: Keychain = Keychain()) {
        self.keychain = keychain
    }

    /// Reads the Keychain on first use — never in init, so app launch can't block on a
    /// Keychain access prompt.
    private func ensureLoaded() {
        guard !loaded else { return }
        loaded = true
        if let seeded = OpenAIEndpoints.testOverride(env: "ROKUBI_API_KEY", flag: "--api-key"), !seeded.isEmpty {
            key = seeded
            ephemeral = true   // never persisted
        } else {
            key = keychain.read(keychainAccount).flatMap { String(data: $0, encoding: .utf8) }
        }
    }

    public var isConfigured: Bool { ensureLoaded(); return key != nil }
    public var isEphemeral: Bool { ensureLoaded(); return ephemeral }

    public var account: AccountInfo { AccountInfo(mode: .apiKey) }

    public func set(key newKey: String) throws {
        let trimmed = newKey.trimmingCharacters(in: .whitespacesAndNewlines)
        key = trimmed
        ephemeral = false
        try keychain.write(Data(trimmed.utf8), account: keychainAccount)
    }

    public func clear() {
        key = nil
        keychain.delete(keychainAccount)
    }

    public func authHeaders() async throws -> [String: String] {
        ensureLoaded()
        guard let key else { throw AuthError.notSignedIn }
        return ["Authorization": "Bearer \(key)"]
    }

    public func invalidate() async {}
}
