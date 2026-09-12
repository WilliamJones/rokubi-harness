import HarnessAgent
import SwiftUI

/// One user message.
struct UserMessageView: View {
    let text: String
    let attachments: [ContextAttachment]

    var body: some View {
        VStack(alignment: .trailing, spacing: 4) {
            Text(text)
                .textSelection(.enabled)
                .padding(.horizontal, 12).padding(.vertical, 8)
                .background(RoundedRectangle(cornerRadius: 12).fill(Color.accentColor.opacity(0.14)))
            if !attachments.isEmpty {
                HStack(spacing: 4) {
                    ForEach(attachments, id: \.self) { a in
                        Text(a.label).font(.caption2).padding(.horizontal, 6).padding(.vertical, 2)
                            .background(Capsule().fill(.quaternary))
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .trailing)
    }
}

/// Assistant prose (streaming or final).
struct AssistantMessageView: View {
    let text: String
    let isStreaming: Bool

    var body: some View {
        HStack(alignment: .bottom, spacing: 4) {
            MarkdownText(text: text)
            if isStreaming { StreamingCursor() }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct StreamingCursor: View {
    @State private var on = true
    var body: some View {
        Rectangle().fill(.secondary).frame(width: 7, height: 14).opacity(on ? 1 : 0.2)
            .onAppear { withAnimation(.easeInOut(duration: 0.6).repeatForever()) { on.toggle() } }
    }
}

/// PRD §11 — agent activity, collapsed by default: `✓ Read 6 files`.
struct ActivityRow: View {
    let activity: ActivityRecord
    let isLive: Bool
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                icon.frame(width: 14)
                Text(activity.title).font(.callout).foregroundStyle(activity.succeeded ? .secondary : .primary)
                    .lineLimit(expanded ? nil : 1)
                if activity.detail != nil {
                    Image(systemName: "chevron.right").font(.caption2).foregroundStyle(.tertiary)
                        .rotationEffect(.degrees(expanded ? 90 : 0))
                }
                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
            .onTapGesture { if activity.detail != nil { withAnimation(.easeOut(duration: 0.15)) { expanded.toggle() } } }
            if expanded, let detail = activity.detail {
                Text(detail)
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: 6).fill(.quaternary.opacity(0.4)))
                    .padding(.leading, 20)
            }
        }
    }

    @ViewBuilder private var icon: some View {
        if isLive {
            ProgressView().controlSize(.mini)
        } else if activity.succeeded {
            Image(systemName: "checkmark").font(.caption).foregroundStyle(.green)
        } else {
            Image(systemName: "xmark").font(.caption).foregroundStyle(.red)
        }
    }
}

/// Faint reasoning summary while the model thinks.
struct ReasoningPreview: View {
    let text: String
    var body: some View {
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: "sparkles").font(.caption).foregroundStyle(.tertiary)
            Text(text).font(.callout).foregroundStyle(.tertiary).lineLimit(3)
        }
    }
}

struct NoteRow: View {
    let text: String
    var body: some View {
        Text(text).font(.caption).foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .center)
            .padding(.vertical, 2)
    }
}
