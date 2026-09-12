import Testing
@testable import HarnessCore

@Suite struct DiagnosticsParserTests {
    /// Real `npm test` output from demo-project in a terminal (spec reporter), paths shortened to /repo.
    @Test func parsesNodeTestRunnerSpecReporter() {
        let out = """
        ✔ subtotal sums price x quantity (0.254917ms)
        ✖ fixed discount comes off the order once (0.310125ms)
        ✔ percent discount comes off the order once (0.044333ms)
        ℹ tests 5
        ℹ fail 1

        ✖ failing tests:

        test at test/cart.test.js:15:1
        ✖ fixed discount comes off the order once (0.310125ms)
          AssertionError [ERR_ASSERTION]: Expected values to be strictly equal:

          80 !== 120

              at TestContext.<anonymous> (file:///repo/test/cart.test.js:16:10)
              at Test.runInAsyncScope (node:async_hooks:211:14)
              at Test.run (node:internal/test_runner/test:979:25)
        """
        let p = DiagnosticsParser.parse(out, projectRoot: .init(fileURLWithPath: "/repo"))
        #expect(p.count == 1)
        #expect(p.first?.source == "node")
        #expect(p.first?.path == "test/cart.test.js" && p.first?.line == 16 && p.first?.column == 10)
        #expect(p.first?.message == "fixed discount comes off the order once")
    }

    @Test func parsesNodeTestRunnerTAPReporter() {
        let out = """
        ok 1 - subtotal sums price x quantity
        not ok 2 - fixed discount comes off the order once
          ---
          duration_ms: 0.4
          type: 'test'
          location: '/repo/test/cart.test.js:15:1'
          failureType: 'testCodeFailure'
        """
        let p = DiagnosticsParser.parse(out, projectRoot: .init(fileURLWithPath: "/repo"))
        #expect(p.count == 1)
        #expect(p.first?.path == "test/cart.test.js" && p.first?.line == 15 && p.first?.message == "fixed discount comes off the order once")
    }

    @Test func passingNodeRunYieldsNoProblems() {
        let out = """
        ✔ subtotal sums price x quantity (0.259208ms)
        ✔ fixed discount comes off the order once (0.059458ms)
        ℹ tests 5
        ℹ pass 5
        ℹ fail 0
        """
        #expect(DiagnosticsParser.parse(out, projectRoot: .init(fileURLWithPath: "/repo")).isEmpty)
    }

    @Test func parsesTypeScriptAndCompilerStyle() {
        let out = """
        src/auth/session.ts(12,5): error TS2322: Type 'string' is not assignable to type 'number'.
        Sources/App/Main.swift:8:12: warning: variable 'x' was never used
        ./cmd/main.go:3:1: undefined: foo
        """
        let p = DiagnosticsParser.parse(out)
        #expect(p.count == 3)
        #expect(p[0].source == "tsc" && p[0].line == 12 && p[0].column == 5 && p[0].severity == .error)
        #expect(p[1].path == "Sources/App/Main.swift" && p[1].severity == .warning)
        #expect(p[2].path == "cmd/main.go" && p[2].message == "undefined: foo")
    }

    @Test func parsesESLintStylish() {
        let out = """
        /repo/src/a.ts
          12:5  error  Unexpected var, use let or const instead  no-var
          14:1  warning  Missing semicolon  semi

        ✖ 2 problems (1 error, 1 warning)
        """
        let p = DiagnosticsParser.parse(out, projectRoot: .init(fileURLWithPath: "/repo"))
        #expect(p.count == 2)
        #expect(p[0].path == "src/a.ts" && p[0].line == 12 && p[0].message == "Unexpected var, use let or const instead")
        #expect(p[1].severity == .warning)
    }

    @Test func parsesCargoAndPytest() {
        let out = """
        error[E0308]: mismatched types
          --> src/main.rs:4:18
        FAILED tests/test_math.py::test_add - assert 3 == 4
        """
        let p = DiagnosticsParser.parse(out)
        #expect(p.contains { $0.source == "cargo" && $0.path == "src/main.rs" && $0.line == 4 && $0.message == "mismatched types" })
        #expect(p.contains { $0.source == "pytest" && $0.path == "tests/test_math.py" && $0.message == "assert 3 == 4" })
    }

    @Test func ignoresUnrelatedOutput() {
        #expect(DiagnosticsParser.parse("added 12 packages in 2s\n> build\nDone in 1.2s").isEmpty)
    }
}
