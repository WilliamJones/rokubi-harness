import HarnessCore
import SwiftUI

/// Commit from the completion card or the palette. Shows the message and exactly which of the task's
/// files go in; only the ticked files are staged and committed, and nothing else is touched.
struct CommitSheet: View {
    let session: AgentSession
    @Environment(\.dismiss) private var dismiss
    @State private var message = ""
    @State private var candidates: [String] = []
    @State private var included: Set<String> = []
    @State private var loading = true
    @State private var committing = false
    @State private var failure: String?

    private var canCommit: Bool {
        !committing && !included.isEmpty && !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Commit Changes").font(.headline)

            Text("Message").font(.caption).foregroundStyle(.secondary)
            TextEditor(text: $message)
                .font(.body)
                .frame(height: 64)
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(.quaternary))

            HStack {
                Text("Files from this task").font(.caption).foregroundStyle(.secondary)
                Spacer()
                if !candidates.isEmpty {
                    Text("\(included.count) of \(candidates.count) selected").font(.caption).foregroundStyle(.secondary)
                }
            }
            Group {
                if loading {
                    ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if candidates.isEmpty {
                    Text("Nothing from this task is left to commit.")
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    List(candidates, id: \.self) { path in
                        Toggle(isOn: Binding(get: { included.contains(path) },
                                             set: { on in if on { included.insert(path) } else { included.remove(path) } })) {
                            Text(path).font(.system(.callout, design: .monospaced)).lineLimit(1).truncationMode(.middle)
                        }
                    }
                    .listStyle(.bordered)
                }
            }
            .frame(height: 150)

            Text("Only the ticked files are staged and committed. Your other changes, staged or not, stay as they are.")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if let failure {
                Text(failure).font(.caption).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Commit") { commit() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canCommit)
            }
        }
        .padding(18)
        .frame(width: 460)
        .task {
            message = session.completion?.summary.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
            candidates = await session.commitCandidates()
            included = Set(candidates)
            loading = false
        }
    }

    private func commit() {
        committing = true
        failure = nil
        let paths = candidates.filter(included.contains)
        Task {
            let ok = await session.commit(message: message, paths: paths)
            committing = false
            if ok { dismiss() } else { failure = session.lastError ?? "Commit failed." }
        }
    }
}
