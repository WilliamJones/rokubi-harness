import Testing
@testable import HarnessCore

@Suite struct DiagnosticsParserTests {
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
