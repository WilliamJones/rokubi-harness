import Testing
@testable import HarnessAgent

@Suite struct HarnessAgentSmokeTests {
    @Test func versionIsSet() {
        #expect(!HarnessAgent.version.isEmpty)
    }
}
