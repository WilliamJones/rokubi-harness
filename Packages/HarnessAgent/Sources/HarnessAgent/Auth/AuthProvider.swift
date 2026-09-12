import Foundation

/// Which HTTP API a provider speaks. The Responses API carries reasoning/tool state;
/// Chat Completions is the universal, provider-agnostic shape (what OpenRouter's whole
/// catalog supports).
public enum ModelAPIStyle: String, Codable, Sendable { case responses, chatCompletions }

/// Who the user is signed in as.
public struct AccountInfo: Codable, Sendable, Equatable {
    public enum Mode: String, Codable, Sendable { case chatGPT, apiKey, openRouter }
    public var mode: Mode
    public var email: String?
    public var accountID: String?
    public var planType: String?

    public var displayName: String {
        switch mode {
        case .chatGPT: email ?? "ChatGPT account"
        case .apiKey: "API key"
        case .openRouter: "OpenRouter"
        }
    }
}

public enum AuthError: LocalizedError, Sendable {
    case notSignedIn
    case stateMismatch
    case tokenExchangeFailed(Int, String)
    case refreshFailed(Int, String)
    case missingAccountID
    case invalidResponse

    public var errorDescription: String? {
        switch self {
        case .notSignedIn: "Sign in with ChatGPT or add an API key to start."
        case .stateMismatch: "Sign-in response didn't match this request. Please try again."
        case .tokenExchangeFailed(let s, let b): "Token exchange failed (\(s)): \(b)"
        case .refreshFailed(let s, let b): "Session refresh failed (\(s)): \(b). Please sign in again."
        case .missingAccountID: "The ChatGPT account has no account id; is a workspace selected?"
        case .invalidResponse: "Unexpected response from OpenAI."
        }
    }
}

/// Source of credentials for the model client. Implementations: `ChatGPTAuth`, `APIKeyAuth`, `OpenRouterAuth`.
public protocol AuthProvider: Sendable {
    var baseURL: URL { get }
    /// Which HTTP API this provider's models speak, so the session picks the right client.
    var api: ModelAPIStyle { get }
    /// Human name used in error messages ("OpenRouter returned HTTP 403").
    var providerLabel: String { get }
    var account: AccountInfo { get async }
    /// Headers to attach to every request (Authorization and, for ChatGPT, account id).
    func authHeaders() async throws -> [String: String]
    /// Called after a 401 so the provider can drop cached tokens and refresh.
    func invalidate() async
}

public extension AuthProvider {
    var api: ModelAPIStyle { .responses }
    var providerLabel: String { "OpenAI" }
}
