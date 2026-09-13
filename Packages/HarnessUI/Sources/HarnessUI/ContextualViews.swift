import HarnessAgent
import SwiftUI

/// PRD §18 — an approval request rendered inline in the conversation, never as a modal.
struct PermissionCard: View {
    let request: PermissionRequest
    var assistantName = "The agent"
    let respond: (PermissionEngine.AskResponse) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "hand.raised").foregroundStyle(.orange)
                Text("\(assistantName) wants to \(request.summary.prefix(1).lowercased() + request.summary.dropFirst())")
                    .font(.callout).fontWeight(.medium)
            }
            if let detail = request.detail, detail != request.summary {
                Text(detail).font(.system(.caption, design: .monospaced)).foregroundStyle(.secondary)
                    .textSelection(.enabled).lineLimit(6)
            }
            HStack {
                Button("Allow") { respond(.allowOnce) }.keyboardShortcut(.return, modifiers: [])
                Button("Always Allow") { respond(.allowForSession) }
                Spacer()
                Button("Deny", role: .destructive) { respond(.deny) }.keyboardShortcut(.escape, modifiers: [])
            }
            .controlSize(.small)
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 8).fill(.orange.opacity(0.08)))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(.orange.opacity(0.35)))
    }
}

/// PRD §19 — implementation plan, shown only while the agent maintains one.
struct PlanPanel: View {
    let steps: [PlanStep]
    @State private var expanded = true

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Button { withAnimation(.easeOut(duration: 0.15)) { expanded.toggle() } } label: {
                HStack(spacing: 6) {
                    Image(systemName: "chevron.down").font(.caption2).rotationEffect(.degrees(expanded ? 0 : -90))
                    Text("Implementation Plan").font(.caption).fontWeight(.semibold)
                    Spacer()
                    Text("\(steps.filter { $0.status == .done }.count)/\(steps.count)").font(.caption).foregroundStyle(.secondary)
                }
            }
            .buttonStyle(.plain)
            if expanded {
                ForEach(steps) { step in
                    HStack(spacing: 6) {
                        icon(step.status).frame(width: 12)
                        Text(step.title).font(.callout)
                            .foregroundStyle(step.status == .done || step.status == .skipped ? .secondary : .primary)
                            .strikethrough(step.status == .skipped)
                    }
                }
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .background(.bar)
    }

    @ViewBuilder private func icon(_ status: PlanStep.Status) -> some View {
        switch status {
        case .done: Image(systemName: "checkmark").font(.caption).foregroundStyle(.green)
        case .inProgress: Image(systemName: "circle.fill").font(.system(size: 7)).foregroundStyle(Color.accentColor)
        case .pending: Image(systemName: "circle").font(.system(size: 7)).foregroundStyle(.tertiary)
        case .skipped: Image(systemName: "minus").font(.caption).foregroundStyle(.tertiary)
        }
    }
}

/// PRD §31 — the completion experience: what changed, what was verified, what you can do.
struct CompletionCard: View {
    let report: CompletionReport
    let changedCount: Int
    let onReview: () -> Void
    let onCommit: () -> Void
    let onUndo: () -> Void
    var canReview = false
    var canCommit = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("TASK COMPLETE").font(.caption).fontWeight(.bold).tracking(1).foregroundStyle(.secondary)
            Text(report.summary).font(.callout)

            HStack(alignment: .top, spacing: 24) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Changes").font(.caption).fontWeight(.semibold).foregroundStyle(.secondary)
                    Text("\(changedCount) file\(changedCount == 1 ? "" : "s") changed").font(.callout)
                }
                VStack(alignment: .leading, spacing: 3) {
                    Text("Verified").font(.caption).fontWeight(.semibold).foregroundStyle(.secondary)
                    if report.verifications.isEmpty {
                        Text("Nothing verified").font(.callout).foregroundStyle(.orange)
                    }
                    ForEach(report.verifications) { v in
                        HStack(spacing: 5) {
                            verificationIcon(v.status)
                            Text(v.name).font(.callout)
                            if let d = v.detail { Text(d).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
                        }
                    }
                }
            }
            if let notes = report.notes, !notes.isEmpty {
                Text(notes).font(.caption).foregroundStyle(.secondary)
            }
            HStack {
                Button("Review Changes", action: onReview).disabled(!canReview || changedCount == 0)
                Button("Commit…", action: onCommit).disabled(!canCommit)
                Spacer()
                Button("Undo Task", role: .destructive, action: onUndo).disabled(changedCount == 0)
            }
            .controlSize(.small)
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color(nsColor: .textBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(.quaternary))
    }

    @ViewBuilder private func verificationIcon(_ s: CompletionReport.Verification.Status) -> some View {
        switch s {
        case .passed: Image(systemName: "checkmark").font(.caption).foregroundStyle(.green)
        case .failed: Image(systemName: "xmark").font(.caption).foregroundStyle(.red)
        case .skipped: Image(systemName: "minus").font(.caption).foregroundStyle(.tertiary)
        case .notRun: Image(systemName: "questionmark").font(.caption).foregroundStyle(.orange)
        }
    }
}

/// PRD §16 — `4 files changed   Review`.
struct ChangesChip: View {
    let count: Int
    let onReview: () -> Void
    var canReview = false

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "pencil.line").font(.caption)
            Text("\(count) file\(count == 1 ? "" : "s") changed").font(.caption)
            Spacer()
            Button("Review", action: onReview).controlSize(.small).disabled(!canReview)
        }
        .padding(.horizontal, 12).padding(.vertical, 6)
        .background(.bar)
    }
}
