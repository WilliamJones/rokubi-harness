import Foundation
import Testing
@testable import HarnessAgent

/// The app never picks a model. Each account type (ChatGPT sign-in, OpenAI API key, OpenRouter)
/// keeps its own choice, which survives restarts and refreshes. Only a user choice is ever written.
@MainActor
@Suite struct ModelSelectionTests {
    private let allModes: [AccountInfo.Mode] = [.chatGPT, .apiKey, .openRouter]

    private func freshDefaults() -> UserDefaults {
        let name = "model-selection-tests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return defaults
    }

    private func catalog(_ defaults: UserDefaults, override: String? = nil) -> ModelCatalog {
        ModelCatalog(defaults: defaults, launchOverride: override)
    }

    @Test func eachAccountTypeHasItsOwnKey() {
        #expect(ModelCatalog.selectionKey(for: .chatGPT) == "model.userSelected.chatGPT")
        #expect(ModelCatalog.selectionKey(for: .apiKey) == "model.userSelected.apiKey")
        #expect(ModelCatalog.selectionKey(for: .openRouter) == "model.userSelected.openRouter")
    }

    @Test func nothingIsSelectedUntilTheUserChooses() {
        let models = catalog(freshDefaults())
        #expect(models.selected == nil)
        for mode in allModes {
            models.setAccount(mode)
            #expect(models.selected == nil)
            #expect(models.selectedInfo == nil)
        }
    }

    @Test func olderAppWideKeysAreIgnored() {
        let defaults = freshDefaults()
        defaults.set("gpt-5.4", forKey: "model.selected")
        defaults.set("gpt-5.4-mini", forKey: "model.userSelected")
        let models = catalog(defaults)
        for mode in allModes {
            models.setAccount(mode)
            #expect(models.selected == nil)
        }
    }

    @Test func eachAccountTypeRemembersItsOwnChoice() {
        let models = catalog(freshDefaults())
        models.setAccount(.openRouter)
        models.select("anthropic/claude-sonnet-5")

        models.setAccount(.chatGPT)
        #expect(models.selected == nil)
        models.select("gpt-5.4")

        models.setAccount(.apiKey)
        #expect(models.selected == nil)

        models.setAccount(.openRouter)
        #expect(models.selected == "anthropic/claude-sonnet-5")
        models.setAccount(.chatGPT)
        #expect(models.selected == "gpt-5.4")
    }

    @Test func choicesSurviveRestarts() {
        let defaults = freshDefaults()
        let first = catalog(defaults)
        first.setAccount(.openRouter)
        first.select("anthropic/claude-sonnet-5")
        first.setAccount(.apiKey)
        first.select("gpt-5.4-mini")

        let relaunched = catalog(defaults)
        #expect(relaunched.selected == nil)   // nothing until the account is known
        relaunched.setAccount(.apiKey)
        #expect(relaunched.selected == "gpt-5.4-mini")
        relaunched.setAccount(.openRouter)
        #expect(relaunched.selected == "anthropic/claude-sonnet-5")
        relaunched.setAccount(.chatGPT)
        #expect(relaunched.selected == nil)
    }

    @Test func signingOutHidesTheChoiceWithoutForgettingIt() {
        let models = catalog(freshDefaults())
        models.setAccount(.chatGPT)
        models.select("gpt-5.4")

        models.setAccount(nil)
        #expect(models.selected == nil)
        models.select("gpt-5.2")   // no account: kept for this run only
        #expect(models.selected == "gpt-5.2")

        models.setAccount(.chatGPT)
        #expect(models.selected == "gpt-5.4")
    }

    @Test func restoringAChoiceWritesNothing() {
        let defaults = RecordingDefaults(values: ["model.userSelected.apiKey": "gpt-5.4-mini"])!
        let models = catalog(defaults)
        models.setAccount(.apiKey)
        #expect(models.selected == "gpt-5.4-mini")
        #expect(defaults.writes == 0)

        models.select("gpt-5.4")
        #expect(defaults.writes == 1)
        #expect(defaults.values["model.userSelected.apiKey"] == "gpt-5.4")
    }

    @Test func launchOverrideAppliesToEveryAccountAndIsNeverSaved() {
        let defaults = RecordingDefaults(values: ["model.userSelected.chatGPT": "gpt-5.2"])!
        let models = catalog(defaults, override: "gpt-5.4")
        #expect(models.selected == "gpt-5.4")
        models.setAccount(.chatGPT)
        #expect(models.selected == "gpt-5.4")
        models.setAccount(.openRouter)
        #expect(models.selected == "gpt-5.4")
        #expect(defaults.writes == 0)
    }

    @Test func switchingAccountsResetsTheModelList() async {
        let models = catalog(freshDefaults())
        models.setAccount(.openRouter)
        await models.refresh(using: StubAuth(), session: StubModelsProtocol.session(json: Self.twoModels))
        #expect(models.models.map(\.id) == ["model-a", "model-b"])

        models.setAccount(.chatGPT)
        #expect(models.models.map(\.id) == ModelCatalog.fallbackModels)
    }

    @Test func refreshNeverChoosesOrReplacesAModel() async {
        let defaults = freshDefaults()
        let models = catalog(defaults)
        models.setAccount(.apiKey)
        let session = StubModelsProtocol.session(json: Self.twoModels)

        await models.refresh(using: StubAuth(), session: session)
        #expect(models.models.map(\.id) == ["model-a", "model-b"])
        #expect(models.selected == nil)

        models.select("gpt-5.4")   // not in the refreshed list
        await models.refresh(using: StubAuth(), session: session)
        #expect(models.selected == "gpt-5.4")

        let relaunched = catalog(defaults)
        relaunched.setAccount(.apiKey)
        #expect(relaunched.selected == "gpt-5.4")
    }

    private static let twoModels = #"{"data":[{"id":"model-a","name":"Model A"},{"id":"model-b","name":"Model B"}]}"#
}

/// Returns fixed saved values and counts writes, without touching any shared defaults domain.
private final class RecordingDefaults: UserDefaults, @unchecked Sendable {
    var values: [String: String]
    var writes = 0

    init?(values: [String: String]) {
        self.values = values
        super.init(suiteName: "recording-\(UUID().uuidString)")
    }

    override func string(forKey defaultName: String) -> String? { values[defaultName] }
    override func set(_ value: Any?, forKey defaultName: String) {
        writes += 1
        values[defaultName] = value as? String
    }
    override func removeObject(forKey defaultName: String) {
        writes += 1
        values[defaultName] = nil
    }
}

private struct StubAuth: AuthProvider {
    let baseURL = URL(string: "https://models.stub.invalid/v1")!
    let providerLabel = "Stub"
    var account: AccountInfo { get async { AccountInfo(mode: .apiKey) } }
    func authHeaders() async throws -> [String: String] { ["Authorization": "Bearer test"] }
    func invalidate() async {}
}

/// Serves a fixed `/models` response without touching the network.
private final class StubModelsProtocol: URLProtocol {
    nonisolated(unsafe) static var body = Data()

    static func session(json: String) -> URLSession {
        body = Data(json.utf8)
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubModelsProtocol.self]
        return URLSession(configuration: config)
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil,
                                       headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Self.body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
