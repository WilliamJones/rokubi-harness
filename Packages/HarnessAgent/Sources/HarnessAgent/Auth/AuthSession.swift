import Foundation
import Observation

/// App-wide sign-in state for the UI. Owns both providers and exposes whichever is active.
@MainActor
@Observable
public final class AuthSession {
    public enum State: Equatable, Sendable {
        case signedOut
        case signingIn
        case signedIn(AccountInfo)
    }

    public private(set) var state: State = .signedOut
    public var lastError: String?

    public let chatGPT: ChatGPTAuth
    public let apiKey: APIKeyAuth
    public let openRouter: OpenRouterAuth

    /// Which provider requests go through. Persisted so relaunch keeps the choice.
    public private(set) var activeMode: AccountInfo.Mode? {
        didSet { UserDefaults.standard.set(activeMode?.rawValue, forKey: "auth.activeMode") }
    }

    public init(chatGPT: ChatGPTAuth = ChatGPTAuth(), apiKey: APIKeyAuth = APIKeyAuth(),
                openRouter: OpenRouterAuth = OpenRouterAuth()) {
        self.chatGPT = chatGPT
        self.apiKey = apiKey
        self.openRouter = openRouter
        self.activeMode = UserDefaults.standard.string(forKey: "auth.activeMode").flatMap(AccountInfo.Mode.init)
        Task { await restore() }
    }

    public var provider: (any AuthProvider)? {
        switch activeMode {
        case .chatGPT: chatGPT
        case .apiKey: apiKey
        case .openRouter: openRouter
        case nil: nil
        }
    }

    public var isSignedIn: Bool {
        if case .signedIn = state { return true }
        return false
    }

    public var account: AccountInfo? {
        if case .signedIn(let a) = state { return a }
        return nil
    }

    // MARK: Actions

    public func signInWithChatGPT() async {
        guard state != .signingIn else { return }
        state = .signingIn
        lastError = nil
        do {
            let account = try await chatGPT.signIn()
            activeMode = .chatGPT
            state = .signedIn(account)
        } catch {
            state = .signedOut
            if !(error is CancellationError) { lastError = error.localizedDescription }
        }
    }

    public func cancelSignIn() async {
        await chatGPT.cancelSignIn()
    }

    public func useAPIKey(_ key: String) async {
        do {
            try await apiKey.set(key: key)
            activeMode = .apiKey
            state = .signedIn(await apiKey.account)
            lastError = nil
        } catch {
            lastError = error.localizedDescription
        }
    }

    public func useOpenRouter(_ key: String) async {
        do {
            try await openRouter.set(key: key)
            activeMode = .openRouter
            state = .signedIn(await openRouter.account)
            lastError = nil
        } catch {
            lastError = error.localizedDescription
        }
    }

    public func signOut() async {
        switch activeMode {
        case .chatGPT: await chatGPT.signOut()
        case .apiKey: await apiKey.clear()
        case .openRouter: await openRouter.clear()
        case nil: break
        }
        activeMode = nil
        state = .signedOut
    }

    private func restore() async {
        // Test/CI runs seed a key via flag/env: sign in with it and don't touch the Keychain or the
        // persisted mode (a fresh ad-hoc-signed build would otherwise trigger a Keychain prompt).
        if await apiKey.isEphemeral {
            state = .signedIn(await apiKey.account)
            activeMode = .apiKey
            return
        }
        if await openRouter.isEphemeral {
            state = .signedIn(await openRouter.account)
            activeMode = .openRouter
            return
        }
        switch activeMode {
        case .chatGPT where await chatGPT.isSignedIn:
            state = .signedIn(await chatGPT.account)
        case .apiKey where await apiKey.isConfigured:
            state = .signedIn(await apiKey.account)
        case .openRouter where await openRouter.isConfigured:
            state = .signedIn(await openRouter.account)
        default:
            // Prefer whichever credential exists if the stored mode is stale.
            if await chatGPT.isSignedIn { activeMode = .chatGPT; state = .signedIn(await chatGPT.account) }
            else if await apiKey.isConfigured { activeMode = .apiKey; state = .signedIn(await apiKey.account) }
            else if await openRouter.isConfigured { activeMode = .openRouter; state = .signedIn(await openRouter.account) }
            else { activeMode = nil; state = .signedOut }
        }
    }
}
