import Foundation
import Testing
@testable import HarnessAgent
@testable import HarnessCore

/// The model must be told what it actually is; a hardcoded "You are ChatGPT" made every
/// OpenRouter model claim to be ChatGPT.
@Suite struct IdentityPromptTests {
    @Test func promptNamesTheSelectedModelAndProvider() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("id-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let assembler = ContextAssembler(files: FileService(root: root), ignore: IgnoreRules(patterns: []),
                                         autonomySummary: "Standard", modelName: "poolside/laguna-s-2.1", providerName: "OpenRouter")
        let text = assembler.instructions()
        #expect(text.contains("\"poolside/laguna-s-2.1\""))
        #expect(text.contains("served via OpenRouter"))
        #expect(!text.contains("You are ChatGPT"))
        #expect(text.contains("do not claim to be a different model"))
    }

    @Test func openAIModelsAreStillDescribedAsOpenAI() {
        let text = SystemPrompt.instructions(modelName: "gpt-5.4", providerName: "OpenAI")
        #expect(text.contains("\"gpt-5.4\"") && text.contains("served via OpenAI"))
    }
}
