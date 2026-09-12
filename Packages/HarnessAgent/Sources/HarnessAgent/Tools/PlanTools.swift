import Foundation
import HarnessCore

/// PRD §19 — a contextual plan that only appears when the model chooses to use it.
struct UpdatePlanTool: Tool {
    let name = "update_plan"
    let description = "Show or update a short step list for multi-step work. Call again as steps progress. Skip for trivial tasks."
    let permission = PermissionClass.read
    var parameters: JSONValue {
        Schema.object([
            "steps": Schema.array("Ordered steps", items: Schema.object([
                "title": Schema.string("Short imperative step, e.g. 'Update middleware'"),
                "status": Schema.string("Step status", enumValues: ["pending", "in_progress", "done", "skipped"]),
            ], required: ["title", "status"])),
        ], required: ["steps"])
    }

    func summary(for a: JSONValue) -> String { "Updated plan" }

    func execute(_ a: JSONValue, context: ToolContext) async throws -> ToolOutput {
        let steps: [PlanStep] = (a["steps"]?.arrayValue ?? []).compactMap { s in
            guard let title = s.string("title") else { return nil }
            return PlanStep(title: title, status: PlanStep.Status(rawValue: s.string("status") ?? "pending") ?? .pending)
        }
        guard !steps.isEmpty else { throw ToolError("`steps` must not be empty") }
        await context.sink.planUpdated(steps)
        let done = steps.filter { $0.status == .done }.count
        return ToolOutput("Plan updated (\(done)/\(steps.count) done)",
                          activity: ActivityRecord(kind: .plan, title: "Plan: \(done)/\(steps.count) steps done"))
    }
}

/// PRD §31 — the completion experience is structured evidence, not prose.
struct ReportCompletionTool: Tool {
    let name = "report_completion"
    let description = """
    Call once when the task is finished (or when you must stop). Lists what changed and exactly what was verified. \
    Only mark a verification 'passed' if you ran it in this task and saw it pass.
    """
    let permission = PermissionClass.read
    var parameters: JSONValue {
        Schema.object([
            "summary": Schema.string("One or two sentences: what was accomplished"),
            "changed_files": Schema.array("Project-relative paths that were modified or created", items: Schema.string("path")),
            "verifications": Schema.array("Checks performed", items: Schema.object([
                "name": Schema.string("e.g. 'TypeScript', 'Lint', 'Tests (48)', 'Build'"),
                "status": Schema.string("Result", enumValues: ["passed", "failed", "skipped", "not_run"]),
                "detail": Schema.string("Optional short detail (e.g. failing test name)"),
            ], required: ["name", "status"])),
            "notes": Schema.string("Optional caveats or suggested next steps"),
        ], required: ["summary", "changed_files", "verifications"])
    }

    func summary(for a: JSONValue) -> String { "Reported completion" }

    func execute(_ a: JSONValue, context: ToolContext) async throws -> ToolOutput {
        let summary = try a.requiredString("summary")
        let files = (a["changed_files"]?.arrayValue ?? []).compactMap(\.stringValue)
        let verifications: [CompletionReport.Verification] = (a["verifications"]?.arrayValue ?? []).compactMap { v in
            guard let name = v.string("name") else { return nil }
            return .init(name: name, status: .init(rawValue: v.string("status") ?? "not_run") ?? .notRun, detail: v.string("detail"))
        }
        let report = CompletionReport(summary: summary, changedFiles: files, verifications: verifications, notes: a.string("notes"))
        await context.sink.completionReported(report)
        return ToolOutput("Completion recorded. Reply to the user with a brief closing message.",
                          activity: ActivityRecord(kind: .verify, title: "Task complete"))
    }
}
