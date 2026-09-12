import Foundation

/// Every OpenAI / ChatGPT constant in one place. The ChatGPT backend is what the
/// Codex CLI talks to; it is undocumented and may change — see the PRD risk note.
/// Verified against `openai/codex` (codex-rs/login) on 2026-09-05.
public enum OpenAIEndpoints {
    // OAuth (ChatGPT sign-in)
    public static let authorizeURL = URL(string: "https://auth.openai.com/oauth/authorize")!
    public static let tokenURL = URL(string: "https://auth.openai.com/oauth/token")!
    public static let clientID = "app_EMoamEEZ73f0CkXaXp7hrann"
    public static let redirectPort: UInt16 = 1455
    public static let redirectPath = "/auth/callback"
    public static var redirectURI: String { "http://localhost:\(redirectPort)\(redirectPath)" }
    public static let scope = "openid profile email offline_access"

    /// Identifies the client to the ChatGPT backend. Community clients send the Codex
    /// CLI's value because the backend gates on it.
    public static let originator = "codex_cli_rs"
    public static let betaHeader = "responses=experimental"
    public static let userAgent = "RokubiHarness/\(HarnessAgent.version) (macOS)"

    // ChatGPT-subscription backend
    public static let chatGPTBaseURL = URL(string: "https://chatgpt.com/backend-api/codex")!
    // Platform API (API-key mode). Overridable for tests via env or `--base-url`.
    public static var apiBaseURL: URL {
        if let raw = testOverride(env: "ROKUBI_OPENAI_BASE_URL", flag: "--base-url"), let url = URL(string: raw) { return url }
        return URL(string: "https://api.openai.com/v1")!
    }

    // OpenRouter — one key, ~any model, Chat Completions API.
    /// `--base-url` also redirects OpenRouter traffic, but only when the key is seeded by
    /// `--openrouter-key` (a scripted run against `scripts/mock-openai.py`).
    public static var openRouterBaseURL: URL {
        if testOverride(env: "ROKUBI_OPENROUTER_KEY", flag: "--openrouter-key") != nil,
           let raw = testOverride(env: "ROKUBI_OPENAI_BASE_URL", flag: "--base-url"), let url = URL(string: raw) {
            return url
        }
        return URL(string: "https://openrouter.ai/api/v1")!
    }
    /// OpenRouter asks clients to identify themselves; these show on your OpenRouter activity page.
    public static let openRouterReferer = "https://github.com/rokubi/harness"
    public static let openRouterTitle = "ROKUBI Harness"

    /// DEBUG-only test override from an env var or a CLI flag (`--flag value`).
    static func testOverride(env: String, flag: String) -> String? {
        #if DEBUG
        if let v = ProcessInfo.processInfo.environment[env], !v.isEmpty { return v }
        let args = CommandLine.arguments
        if let i = args.firstIndex(of: flag), i + 1 < args.count { return args[i + 1] }
        #endif
        return nil
    }

    /// Refresh this long before the access token expires.
    public static let refreshWindow: TimeInterval = 5 * 60
    /// Proactively refresh tokens older than this even if not near expiry (Codex uses 8h).
    public static let proactiveRefreshInterval: TimeInterval = 8 * 60 * 60
}
