import Foundation

/// A compiler / linter / test problem (PRD §24).
public struct Problem: Sendable, Hashable, Identifiable, Codable {
    public enum Severity: String, Sendable, Codable { case error, warning, info }

    public var path: String          // project-relative when possible
    public var line: Int
    public var column: Int?
    public var message: String
    public var severity: Severity
    public var source: String        // "tsc", "eslint", "swift", "cargo", "pytest", "jest", "node"…

    public var id: String { "\(source):\(path):\(line):\(column ?? 0):\(message)" }

    public init(path: String, line: Int, column: Int? = nil, message: String, severity: Severity, source: String) {
        self.path = path; self.line = line; self.column = column
        self.message = message; self.severity = severity; self.source = source
    }
}

/// Regex parsers for the output formats developers actually hit. Each parser is cheap and
/// runs over every command's output; unknown output just yields nothing.
public enum DiagnosticsParser {
    private struct Pattern {
        let source: String
        let regex: NSRegularExpression
        let path: Int, line: Int, column: Int?, severity: Int?, message: Int
    }

    private static let patterns: [Pattern] = {
        func p(_ source: String, _ pattern: String, path: Int, line: Int, column: Int? = nil, severity: Int? = nil, message: Int) -> Pattern {
            Pattern(source: source, regex: try! NSRegularExpression(pattern: pattern, options: [.anchorsMatchLines]),
                    path: path, line: line, column: column, severity: severity, message: message)
        }
        return [
            // tsc:   src/a.ts(12,5): error TS2322: Type 'x' is not assignable
            p("tsc", #"^([^\s(]+\.[cm]?[jt]sx?)\((\d+),(\d+)\): (error|warning) TS\d+: (.+)$"#, path: 1, line: 2, column: 3, severity: 4, message: 5),
            // gcc/clang/swift/rustc-style:  path:12:5: error: message
            p("compiler", #"^((?:/|\./|[\w.-]+/)?[\w./-]+\.(?:swift|c|cc|cpp|m|mm|h|hpp|rs|go|ts|tsx|js|jsx|py|java|kt)):(\d+):(\d+): (error|warning|note): (.+)$"#,
              path: 1, line: 2, column: 3, severity: 4, message: 5),
            // eslint stylish:   12:5  error  Unexpected var  no-var   (path is on a preceding line — handled below)
            p("eslint", #"^\s+(\d+):(\d+)\s+(error|warning)\s+(.+?)\s{2,}[\w@/-]+$"#, path: 0, line: 1, column: 2, severity: 3, message: 4),
            // cargo: "  --> src/main.rs:12:5" preceded by "error[E0308]: mismatched types"
            p("cargo", #"^(error|warning)(?:\[\w+\])?: (.+)\n\s+--> ([^:\n]+):(\d+):(\d+)"#, path: 3, line: 4, column: 5, severity: 1, message: 2),
            // pytest:  tests/test_a.py:12: AssertionError  /  FAILED tests/test_a.py::test_x - assert ...
            p("pytest", #"^([\w./-]+\.py):(\d+): (\w*Error.*|assert .*)$"#, path: 1, line: 2, message: 3),
            p("pytest", #"^FAILED ([\w./-]+\.py)::[\w\[\]-]+ - (.+)$"#, path: 1, line: 0, message: 2),
            // jest/vitest:  ● suite › test  ...  at Object.<anonymous> (src/a.test.ts:12:5)  → keep the location line
            p("jest", #"^\s+at .*\(([\w./-]+\.(?:[cm]?[jt]sx?)):(\d+):(\d+)\)$"#, path: 1, line: 2, column: 3, message: 0),
            // Node's built-in test runner, spec reporter (what a terminal shows):
            //   ✖ fixed discount comes off the order once (0.31ms)
            //     AssertionError [ERR_ASSERTION]: Expected values to be strictly equal:
            //     …
            //       at TestContext.<anonymous> (file:///repo/test/cart.test.js:16:10)
            // The first stack frame inside the project (not node_modules, not node:internal) is the location.
            p("node", #"^✖ (.+?)(?: \([\d.]+m?s\))?\n\s+\w*Error[^\n]*(?:\n[^\n]*){0,12}?\n\s+at [^\n]*\((?:file://)?(/(?![^()\s]*node_modules)[^()\s:]+\.[cm]?[jt]sx?):(\d+):(\d+)\)$"#,
              path: 2, line: 3, column: 4, message: 1),
            // Node's test runner, TAP reporter (piped output):  not ok 2 - title … location: '/repo/test/a.test.js:15:1'
            p("node", #"^not ok \d+ - (.+)\n(?:[^\n]*\n){0,8}?\s+location: '(?:file://)?(/[^'\n]+\.[cm]?[jt]sx?):(\d+):(\d+)'$"#,
              path: 2, line: 3, column: 4, message: 1),
            // go test / go vet:  ./a.go:12:5: message
            p("go", #"^(\./[\w./-]+\.go):(\d+):(\d+): (.+)$"#, path: 1, line: 2, column: 3, message: 4),
        ]
    }()

    public static func parse(_ output: String, projectRoot: URL? = nil) -> [Problem] {
        var problems: [Problem] = []
        let ns = output as NSString
        let full = NSRange(location: 0, length: ns.length)

        for pattern in patterns {
            var lastFilePath: String? = nil
            if pattern.source == "eslint" {
                // eslint prints the file path on its own line before the numbered findings.
                var current: String? = nil
                for rawLine in output.split(separator: "\n", omittingEmptySubsequences: false) {
                    let line = String(rawLine)
                    if !line.hasPrefix(" "), line.range(of: #"\.[cm]?[jt]sx?$"#, options: .regularExpression) != nil {
                        current = line.trimmingCharacters(in: .whitespaces)
                        continue
                    }
                    guard let current, let m = pattern.regex.firstMatch(in: line, range: NSRange(location: 0, length: (line as NSString).length)) else { continue }
                    let l = line as NSString
                    problems.append(Problem(path: relative(current, root: projectRoot), line: Int(l.substring(with: m.range(at: 1))) ?? 0,
                                            column: Int(l.substring(with: m.range(at: 2))), message: l.substring(with: m.range(at: 4)),
                                            severity: l.substring(with: m.range(at: 3)) == "error" ? .error : .warning, source: "eslint"))
                }
                continue
            }
            for m in pattern.regex.matches(in: output, range: full) {
                func g(_ i: Int?) -> String? { guard let i, i > 0, m.range(at: i).location != NSNotFound else { return nil }; return ns.substring(with: m.range(at: i)) }
                let path = g(pattern.path) ?? lastFilePath ?? ""
                lastFilePath = path
                let sevRaw = g(pattern.severity) ?? "error"
                let severity: Problem.Severity = sevRaw == "warning" ? .warning : sevRaw == "note" ? .info : .error
                let message = g(pattern.message).map { $0.trimmingCharacters(in: .whitespaces) } ?? ns.substring(with: m.range).trimmingCharacters(in: .whitespaces)
                problems.append(Problem(path: relative(path, root: projectRoot), line: Int(g(pattern.line) ?? "") ?? 1,
                                        column: g(pattern.column).flatMap(Int.init), message: message, severity: severity, source: pattern.source))
            }
        }
        // De-duplicate identical findings that several patterns may both catch.
        var seen = Set<String>()
        return problems.filter { seen.insert("\($0.path):\($0.line):\($0.message)").inserted }
    }

    private static func relative(_ path: String, root: URL?) -> String {
        guard let root, path.hasPrefix(root.path + "/") else { return path.hasPrefix("./") ? String(path.dropFirst(2)) : path }
        return String(path.dropFirst(root.path.count + 1))
    }
}
