import Foundation
import Testing
@testable import HarnessAgent

@Suite struct SkillStoreTests {
    private func makeProject() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("skills-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root.appendingPathComponent(".rokubi/skills"), withIntermediateDirectories: true)
        return root
    }

    @Test func builtinsAreAvailableWithNoSkillFiles() throws {
        let store = SkillStore(projectRoot: try makeProject())
        let names = store.all().map(\.name)
        #expect(names.contains("review") && names.contains("test") && names.contains("explain"))
        #expect(store.skill(named: "review")?.scope == .builtin)
    }

    @Test func projectSkillOverridesBuiltinByName() throws {
        let root = try makeProject()
        try "# My review\nDo it my way.".write(to: root.appendingPathComponent(".rokubi/skills/review.md"), atomically: true, encoding: .utf8)
        let store = SkillStore(projectRoot: root)
        let review = store.skill(named: "review")
        #expect(review?.scope == .project)
        #expect(review?.body.contains("Do it my way.") == true)
        // Only one entry per name.
        #expect(store.all().filter { $0.name == "review" }.count == 1)
    }

    @Test func slashExpansionPrependsSkillBody() throws {
        let store = SkillStore(projectRoot: try makeProject())
        let (prompt, used) = store.expand("/explain the auth flow")
        #expect(used == "explain")
        #expect(prompt.hasPrefix("# Explain"))
        #expect(prompt.hasSuffix("the auth flow"))
        #expect(store.expand("plain message").usedSkill == nil)
    }

    @Test func listingIsCachedAndInvalidates() throws {
        let root = try makeProject()
        let store = SkillStore(projectRoot: root, recheckInterval: 0)   // stat the directories on every call
        #expect(store.skill(named: "custom") == nil)
        // A new file bumps the directory mtime, so the mtime check picks it up.
        try "# Custom\nBody".write(to: root.appendingPathComponent(".rokubi/skills/custom.md"), atomically: true, encoding: .utf8)
        #expect(store.skill(named: "custom")?.description == "Custom")
        // Within the trust window the cache is returned without touching disk...
        let trusting = SkillStore(projectRoot: root, recheckInterval: 60)
        #expect(trusting.skill(named: "custom") != nil)
        try FileManager.default.removeItem(at: root.appendingPathComponent(".rokubi/skills/custom.md"))
        #expect(trusting.skill(named: "custom") != nil)
        // ...and `invalidate()` forces a re-read.
        trusting.invalidate()
        #expect(trusting.skill(named: "custom") == nil)
    }
}
