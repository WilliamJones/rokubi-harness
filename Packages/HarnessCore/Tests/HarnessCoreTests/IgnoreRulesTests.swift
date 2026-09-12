import Testing
@testable import HarnessCore

@Suite struct IgnoreRulesTests {
    @Test func basenamePatternsMatchAtAnyDepth() {
        let rules = IgnoreRules(patterns: ["node_modules", "*.log"])
        #expect(rules.isIgnored(relativePath: "node_modules", isDirectory: true))
        #expect(rules.isIgnored(relativePath: "packages/a/node_modules", isDirectory: true))
        #expect(rules.isIgnored(relativePath: "packages/a/node_modules/x.js", isDirectory: false))
        #expect(rules.isIgnored(relativePath: "logs/app.log", isDirectory: false))
        #expect(!rules.isIgnored(relativePath: "src/index.ts", isDirectory: false))
    }

    @Test func anchoredPatternsOnlyMatchFromRoot() {
        let rules = IgnoreRules(patterns: ["/dist", "build/output"])
        #expect(rules.isIgnored(relativePath: "dist", isDirectory: true))
        #expect(rules.isIgnored(relativePath: "dist/bundle.js", isDirectory: false))
        #expect(!rules.isIgnored(relativePath: "packages/dist", isDirectory: true))
        #expect(rules.isIgnored(relativePath: "build/output/a.o", isDirectory: false))
        #expect(!rules.isIgnored(relativePath: "other/build/output", isDirectory: true))
    }

    @Test func directoryOnlyRules() {
        let rules = IgnoreRules(patterns: ["cache/"])
        #expect(rules.isIgnored(relativePath: "cache", isDirectory: true))
        #expect(!rules.isIgnored(relativePath: "cache", isDirectory: false))
        #expect(rules.isIgnored(relativePath: "cache/entry", isDirectory: false))
    }

    @Test func negationReinstatesLaterMatches() {
        let rules = IgnoreRules(patterns: ["*.env", "!example.env"])
        #expect(rules.isIgnored(relativePath: "prod.env", isDirectory: false))
        #expect(!rules.isIgnored(relativePath: "example.env", isDirectory: false))
    }

    @Test func doubleStarAndQuestionMark() {
        let rules = IgnoreRules(patterns: ["docs/**/draft-?.md"])
        #expect(rules.isIgnored(relativePath: "docs/draft-1.md", isDirectory: false))
        #expect(rules.isIgnored(relativePath: "docs/a/b/draft-2.md", isDirectory: false))
        #expect(!rules.isIgnored(relativePath: "docs/a/draft-10.md", isDirectory: false))
    }

    @Test func commentsAndBlanksIgnored() {
        let rules = IgnoreRules(patterns: ["# comment", "", "   ", "secret"])
        #expect(rules.isIgnored(relativePath: "secret", isDirectory: false))
        #expect(!rules.isIgnored(relativePath: "# comment", isDirectory: false))
    }
}
