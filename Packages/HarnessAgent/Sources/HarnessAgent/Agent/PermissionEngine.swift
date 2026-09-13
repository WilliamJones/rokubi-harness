import Foundation
import HarnessCore

/// One rule: a permission class, an optional glob on the tool's subject, and a decision.
public struct PermissionRule: Codable, Sendable, Equatable {
    public enum Decision: String, Codable, Sendable { case allow, ask, deny }
    public var permissionClass: PermissionClass
    public var match: String?          // glob on the subject (path / command); nil = any
    public var decision: Decision

    public init(_ permissionClass: PermissionClass, match: String? = nil, _ decision: Decision) {
        self.permissionClass = permissionClass
        self.match = match
        self.decision = decision
    }

    enum CodingKeys: String, CodingKey { case permissionClass = "class", match, decision }

    func applies(to subject: String?) -> Bool {
        guard let match else { return true }
        guard let subject else { return false }
        // Command lines aren't paths: `*` must span spaces and slashes (`npm *`, `*--force*`).
        let regex = permissionClass.isCommand ? CommandPattern.regex(for: match) : Glob.regex(for: match)
        guard let regex else { return false }
        return regex.firstMatch(in: subject, range: NSRange(subject.startIndex..., in: subject)) != nil
    }
}

extension PermissionClass {
    /// Classes whose subject is a shell command line rather than a project path.
    var isCommand: Bool { self == .run || self == .packageInstall }
}

/// Wildcard matching for command lines: `*` matches anything (including `/` and spaces), `?` one
/// character, everything else is literal. Anchored to the whole line.
enum CommandPattern {
    static func regex(for pattern: String) -> NSRegularExpression? {
        var out = "^"
        for c in pattern {
            switch c {
            case "*": out += ".*"
            case "?": out += "."
            default: out += NSRegularExpression.escapedPattern(for: String(c))
            }
        }
        return try? NSRegularExpression(pattern: out + "$", options: [.dotMatchesLineSeparators])
    }
}

/// Layered policy: hard denies → session → project → global → preset default.
public struct PermissionPolicy: Sendable, Equatable {
    public var preset: AutonomyPreset
    public var global: [PermissionRule]
    public var project: [PermissionRule]
    public var session: [PermissionRule]

    public init(preset: AutonomyPreset, global: [PermissionRule] = [], project: [PermissionRule] = [], session: [PermissionRule] = []) {
        self.preset = preset
        self.global = global
        self.project = project
        self.session = session
    }

    /// Commands nothing may run regardless of autonomy (PRD §13 "hard security boundaries").
    /// Regular expressions matched anywhere in the command line, so `cd x && sudo …`,
    /// `/bin/rm -rf ~/` and `env sudo …` are caught too. This is a backstop, not a sandbox:
    /// `run_command` executes through a login shell, so treat Full Autonomy accordingly.
    public static let hardDenyCommandPatterns: [String] = [
        #"\bgit\s+push\b[^;&|\n]*\s(--force(-with-lease)?|-f)\b"#,
        #"\bgit\s+push\b[^;&|\n]*\s\+\S"#,                                  // `git push origin +main`
        #"\brm\s+(-\S+\s+)*(/|~|\$HOME|\$\{HOME\})/?\*?(?=\s|;|&|\||$)"#,   // rm -rf / ~ $HOME
        // Only in command position (start, after ; & | ( `, or via env/exec/nohup), so `grep sudo .` is fine.
        #"(^|[;&|(`]\s*|\b(env|exec|nohup|time|xargs)\s+)(sudo|doas)(\s|$)"#,
        #"\bmkfs(\.\w+)?\b"#,
        #":\(\)\s*\{\s*:\s*\|\s*:\s*&\s*\}\s*;\s*:"#,                       // fork bomb
        #">\s*/dev/(sd|disk|nvme|rdisk)"#,
        #"\bdd\s+[^;&|\n]*\bof=/dev/"#,
        #"\bchmod\s+(-R|--recursive)\s+777\s+/(\s|$)"#,
        #"\bchown\s+(-R|--recursive)\s+\S+\s+/(\s|$)"#,
    ]

    public func evaluate(_ permissionClass: PermissionClass, subject: String?) -> (PermissionRule.Decision, String) {
        if permissionClass.isCommand, let subject {
            for p in Self.hardDenyCommandPatterns where Self.hardDenyMatches(p, subject) {
                return (.deny, "blocked by a hard security boundary")
            }
        }
        for (layer, rules) in [("session", session), ("project", project), ("global", global)] {
            if let rule = rules.last(where: { $0.permissionClass == permissionClass && $0.applies(to: subject) }) {
                return (rule.decision, "\(layer) rule")
            }
        }
        return (Self.presetDecision(preset, permissionClass), preset.title)
    }

    public static func presetDecision(_ preset: AutonomyPreset, _ c: PermissionClass) -> PermissionRule.Decision {
        switch preset {
        case .readOnly:
            return [.read, .search, .gitRead].contains(c) ? .allow : .deny
        case .standard:
            switch c {
            case .read, .search, .gitRead, .edit, .create: return .allow
            case .delete, .run, .gitWrite, .network, .packageInstall: return .ask
            }
        case .askBeforeCommands:
            switch c {
            case .read, .search, .gitRead, .edit, .create, .delete: return .allow
            case .run, .gitWrite, .network, .packageInstall: return .ask
            }
        case .fullAutonomy:
            return .allow
        }
    }

    private static func hardDenyMatches(_ pattern: String, _ subject: String) -> Bool {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return false }
        return regex.firstMatch(in: subject, range: NSRange(subject.startIndex..., in: subject)) != nil
    }

    /// Loads `.rokubi/permissions.json` (`[{"class":"run","match":"npm test*","decision":"allow"}]`).
    /// A repository ships with the project, so it may only *scope* allowances: a blanket `allow`
    /// (no `match`) for anything beyond reads is dropped — otherwise a cloned repo could grant
    /// itself unprompted shell access under Standard autonomy.
    public static func loadProjectRules(root: URL) -> [PermissionRule] {
        loadProjectRulesReport(root: root).rules
    }

    /// Reads `.rokubi/permissions.json` one rule at a time. A rule with a mistake (unknown class or
    /// decision, a misspelled key, a wrong type) is skipped and reported, and the other rules still
    /// apply. A misspelled `match` key is never treated as "no match", which would widen the rule.
    /// A blanket `allow` for anything beyond reads is skipped and reported too. A file that isn't a
    /// JSON list applies no rules and says so.
    public static func loadProjectRulesReport(root: URL) -> ProjectRulesLoad {
        let url = root.appendingPathComponent(".rokubi/permissions.json")
        guard let data = try? Data(contentsOf: url) else { return ProjectRulesLoad(rules: [], warnings: []) }
        guard let json = try? JSONSerialization.jsonObject(with: data) else {
            return ProjectRulesLoad(rules: [], warnings: ["The file isn't valid JSON, so no project rules apply."])
        }
        guard let entries = json as? [Any] else {
            return ProjectRulesLoad(rules: [], warnings: ["The file must be a JSON list of rules, so no project rules apply."])
        }
        let classNames = PermissionClass.allCases.map(\.rawValue).joined(separator: ", ")
        var rules: [PermissionRule] = []
        var warnings: [String] = []
        for (index, entry) in entries.enumerated() {
            let n = index + 1
            guard let object = entry as? [String: Any] else {
                warnings.append("Rule \(n) isn't an object; skipped."); continue
            }
            let unknownKeys = object.keys.filter { !["class", "match", "decision"].contains($0) }.sorted()
            if !unknownKeys.isEmpty {
                let names = unknownKeys.map { "\"\($0)\"" }.joined(separator: ", ")
                warnings.append("Rule \(n) has unknown key \(names); skipped. Keys are class, match, and decision."); continue
            }
            guard let className = object["class"] as? String else {
                warnings.append("Rule \(n) needs a \"class\" written as text; skipped."); continue
            }
            guard let permissionClass = PermissionClass(rawValue: className) else {
                warnings.append("Rule \(n) has unknown class \"\(className)\"; skipped. Use one of: \(classNames)."); continue
            }
            guard let decisionName = object["decision"] as? String else {
                warnings.append("Rule \(n) needs a \"decision\" written as text; skipped."); continue
            }
            guard let decision = PermissionRule.Decision(rawValue: decisionName) else {
                warnings.append("Rule \(n) has unknown decision \"\(decisionName)\"; skipped. Use allow, ask, or deny."); continue
            }
            var match: String? = nil
            if let raw = object["match"], !(raw is NSNull) {
                guard let text = raw as? String else {
                    warnings.append("Rule \(n) has a \"match\" that isn't text; skipped."); continue
                }
                match = text
            }
            if decision == .allow, match == nil, ![.read, .search, .gitRead].contains(permissionClass) {
                warnings.append("Rule \(n) allows every \"\(className)\" action with no \"match\"; skipped for safety. Add a match."); continue
            }
            rules.append(PermissionRule(permissionClass, match: match, decision))
        }
        return ProjectRulesLoad(rules: rules, warnings: warnings)
    }
}

/// What `.rokubi/permissions.json` produced: the rules that apply, and why any were skipped.
public struct ProjectRulesLoad: Sendable, Equatable {
    public var rules: [PermissionRule]
    public var warnings: [String]

    public init(rules: [PermissionRule], warnings: [String]) {
        self.rules = rules
        self.warnings = warnings
    }

    /// One line for the chat's warning strip; empty when nothing was skipped.
    public var summary: String {
        guard !warnings.isEmpty else { return "" }
        let shown = warnings.prefix(3).joined(separator: " ")
        let more = warnings.count > 3 ? " (+\(warnings.count - 3) more)" : ""
        return ".rokubi/permissions.json: \(shown)\(more)"
    }
}

/// `PermissionGate` that consults the policy and, for `ask`, defers to the UI.
public actor PermissionEngine: PermissionGate {
    public typealias Asker = @Sendable (PermissionRequest) async -> AskResponse

    public enum AskResponse: Sendable { case allowOnce, allowForSession, deny }

    private var policy: PermissionPolicy
    private let asker: Asker

    public init(policy: PermissionPolicy, asker: @escaping Asker) {
        self.policy = policy
        self.asker = asker
    }

    public func update(policy: PermissionPolicy) { self.policy = policy }

    public func decide(tool: any Tool, arguments: JSONValue, summary: String) async -> PermissionDecision {
        let subject = tool.subject(for: arguments)
        let (decision, source) = policy.evaluate(tool.permission, subject: subject)
        switch decision {
        case .allow:
            return .allow
        case .deny:
            return .deny(reason: source)
        case .ask:
            let request = PermissionRequest(id: UUID().uuidString, toolName: tool.name, summary: summary, detail: subject)
            switch await asker(request) {
            case .allowOnce:
                return .allow
            case .allowForSession:
                let match = subject.map { tool.permission.isCommand ? Self.sessionPattern($0) : $0 }
                policy.session.append(PermissionRule(tool.permission, match: match, .allow))
                return .allow
            case .deny:
                return .deny(reason: "the user declined")
            }
        }
    }

    /// "Always allow" remembers the command's first word (`npm test` → `npm *`) rather than the
    /// exact line. The space matters: `npm*` would also cover `npmx`.
    static func sessionPattern(_ subject: String) -> String {
        let first = subject.split(separator: " ").first.map(String.init) ?? subject
        return first.contains("/") ? subject : first + " *"
    }
}
