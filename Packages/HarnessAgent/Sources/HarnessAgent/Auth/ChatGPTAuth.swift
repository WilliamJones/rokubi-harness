import AppKit
import Foundation

/// ChatGPT sign-in: PKCE authorization-code flow against auth.openai.com, tokens in
/// the Keychain, automatic refresh. Mirrors the Codex CLI's flow.
public actor ChatGPTAuth: AuthProvider {
    struct Tokens: Codable, Sendable {
        var accessToken: String
        var refreshToken: String
        var idToken: String
        var accountID: String
        var lastRefresh: Date
        var expiresAt: Date?
    }

    public nonisolated let baseURL = OpenAIEndpoints.chatGPTBaseURL

    private let keychain: Keychain
    private let keychainAccount = "chatgpt.tokens"
    private let session: URLSession
    private var tokens: Tokens?
    private var loaded = false
    private var loopback: LoopbackServer?
    private var refreshTask: Task<Tokens, any Error>?

    public init(session: URLSession = .shared, keychain: Keychain = Keychain()) {
        self.session = session
        self.keychain = keychain
    }

    /// Reads the Keychain on first use — never in init, so app launch can't block on a
    /// Keychain access prompt.
    private func ensureLoaded() {
        guard !loaded else { return }
        loaded = true
        if let data = keychain.read(keychainAccount) {
            tokens = try? JSONDecoder().decode(Tokens.self, from: data)
        }
    }

    public var isSignedIn: Bool { ensureLoaded(); return tokens != nil }

    public var account: AccountInfo {
        ensureLoaded()
        let claims = tokens.flatMap { IDTokenClaims.parse($0.idToken) }
        return AccountInfo(mode: .chatGPT, email: claims?.email, accountID: tokens?.accountID, planType: claims?.planType)
    }

    // MARK: Sign in / out

    /// Opens the browser and waits for the redirect. Cancel with `cancelSignIn()`.
    public func signIn() async throws -> AccountInfo {
        let pkce = PKCE()
        let state = PKCE.randomState()

        var components = URLComponents(url: OpenAIEndpoints.authorizeURL, resolvingAgainstBaseURL: false)!
        components.queryItems = [
            .init(name: "response_type", value: "code"),
            .init(name: "client_id", value: OpenAIEndpoints.clientID),
            .init(name: "redirect_uri", value: OpenAIEndpoints.redirectURI),
            .init(name: "scope", value: OpenAIEndpoints.scope),
            .init(name: "code_challenge", value: pkce.challenge),
            .init(name: "code_challenge_method", value: "S256"),
            .init(name: "id_token_add_organizations", value: "true"),
            .init(name: "codex_cli_simplified_flow", value: "true"),
            .init(name: "state", value: state),
            .init(name: "originator", value: OpenAIEndpoints.originator),
        ]

        let server = LoopbackServer(port: OpenAIEndpoints.redirectPort, path: OpenAIEndpoints.redirectPath)
        loopback = server
        defer { loopback = nil }

        async let callback = server.waitForCallback()
        let authURL = components.url!
        await MainActor.run { _ = NSWorkspace.shared.open(authURL) }
        let result = try await callback
        guard result.state == state else { throw AuthError.stateMismatch }

        let exchanged = try await exchange(code: result.code, verifier: pkce.verifier)
        try store(exchanged)
        return account
    }

    public func cancelSignIn() {
        loopback?.cancel()
    }

    public func signOut() {
        tokens = nil
        keychain.delete(keychainAccount)
    }

    // MARK: AuthProvider

    public func authHeaders() async throws -> [String: String] {
        let t = try await validTokens()
        return [
            "Authorization": "Bearer \(t.accessToken)",
            "chatgpt-account-id": t.accountID,
        ]
    }

    public func invalidate() async {
        guard var t = tokens else { return }
        t.expiresAt = .distantPast
        tokens = t
    }

    // MARK: Tokens

    private func validTokens() async throws -> Tokens {
        ensureLoaded()
        guard let t = tokens else { throw AuthError.notSignedIn }
        let nearExpiry = (t.expiresAt ?? .distantFuture).timeIntervalSinceNow < OpenAIEndpoints.refreshWindow
        let stale = Date().timeIntervalSince(t.lastRefresh) > OpenAIEndpoints.proactiveRefreshInterval
        guard nearExpiry || stale else { return t }
        return try await refresh()
    }

    private func refresh() async throws -> Tokens {
        if let task = refreshTask { return try await task.value }
        let task = Task<Tokens, any Error> { [session, tokens] in
            guard let current = tokens else { throw AuthError.notSignedIn }
            var request = URLRequest(url: OpenAIEndpoints.tokenURL)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONEncoder().encode([
                "client_id": OpenAIEndpoints.clientID,
                "grant_type": "refresh_token",
                "refresh_token": current.refreshToken,
            ])
            let (data, response) = try await session.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            guard (200..<300).contains(status) else {
                throw AuthError.refreshFailed(status, String(data: data, encoding: .utf8) ?? "")
            }
            let payload = try JSONDecoder().decode(TokenResponse.self, from: data)
            return try Tokens(from: payload, fallback: current)
        }
        refreshTask = task
        defer { refreshTask = nil }
        do {
            let fresh = try await task.value
            try store(fresh)
            return fresh
        } catch let error as AuthError {
            if case .refreshFailed(let status, _) = error, status == 400 || status == 401 { signOut() }
            throw error
        }
    }

    private func exchange(code: String, verifier: String) async throws -> Tokens {
        var request = URLRequest(url: OpenAIEndpoints.tokenURL)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = formEncode([
            "grant_type": "authorization_code",
            "code": code,
            "redirect_uri": OpenAIEndpoints.redirectURI,
            "client_id": OpenAIEndpoints.clientID,
            "code_verifier": verifier,
        ])
        let (data, response) = try await session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            throw AuthError.tokenExchangeFailed(status, String(data: data, encoding: .utf8) ?? "")
        }
        let payload = try JSONDecoder().decode(TokenResponse.self, from: data)
        return try Tokens(from: payload, fallback: nil)
    }

    private func store(_ t: Tokens) throws {
        tokens = t
        try keychain.write(JSONEncoder().encode(t), account: keychainAccount)
    }

    private func formEncode(_ fields: [String: String]) -> Data {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return Data(fields.map { k, v in
            "\(k)=\(v.addingPercentEncoding(withAllowedCharacters: allowed) ?? v)"
        }.joined(separator: "&").utf8)
    }

    struct TokenResponse: Decodable {
        var access_token: String?
        var refresh_token: String?
        var id_token: String?
        var expires_in: Double?
    }
}

private extension ChatGPTAuth.Tokens {
    init(from payload: ChatGPTAuth.TokenResponse, fallback: Self?) throws {
        guard let access = payload.access_token ?? fallback?.accessToken,
              let refresh = payload.refresh_token ?? fallback?.refreshToken,
              let id = payload.id_token ?? fallback?.idToken
        else { throw AuthError.invalidResponse }
        let claims = IDTokenClaims.parse(id)
        // The account id lives in the id_token; some responses also carry it in the access token.
        guard let accountID = claims?.chatgptAccountID
            ?? IDTokenClaims.parse(access)?.chatgptAccountID
            ?? fallback?.accountID
        else { throw AuthError.missingAccountID }
        let expiry = payload.expires_in.map { Date().addingTimeInterval($0) } ?? IDTokenClaims.parse(access)?.expiresAt
        self.init(accessToken: access, refreshToken: refresh, idToken: id, accountID: accountID,
                  lastRefresh: Date(), expiresAt: expiry)
    }
}
