import HarnessCore
import SwiftUI

/// PRD §24 — `⚠ N Problems` chip; the list opens on demand.
struct ProblemsChip: View {
    let problems: [Problem]
    @Binding var expanded: Bool

    var body: some View {
        let errors = problems.filter { $0.severity == .error }.count
        let warnings = problems.count - errors
        Button { withAnimation(.easeOut(duration: 0.15)) { expanded.toggle() } } label: {
            HStack(spacing: 6) {
                Image(systemName: errors > 0 ? "xmark.octagon.fill" : "exclamationmark.triangle.fill")
                    .foregroundStyle(errors > 0 ? .red : .orange)
                Text("\(problems.count) Problem\(problems.count == 1 ? "" : "s")")
                if warnings > 0 && errors > 0 { Text("(\(errors) errors, \(warnings) warnings)").foregroundStyle(.secondary) }
                Image(systemName: "chevron.up").font(.caption2).rotationEffect(.degrees(expanded ? 180 : 0))
            }
            .font(.caption)
        }
        .buttonStyle(.plain)
    }
}

struct ProblemsPanel: View {
    let problems: [Problem]
    let onOpen: (Problem) -> Void
    let onFix: ([Problem]) -> Void
    let onClear: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Problems").font(.caption).fontWeight(.semibold)
                Spacer()
                Button("Fix with AI") { onFix(problems) }.controlSize(.small)
                Button { onClear() } label: { Image(systemName: "xmark") }.buttonStyle(.plain).help("Clear")
            }
            .padding(.horizontal, 10).frame(height: 28).background(.bar)
            Divider()
            List(problems) { p in
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: p.severity == .error ? "xmark.octagon.fill" : p.severity == .warning ? "exclamationmark.triangle.fill" : "info.circle")
                        .foregroundStyle(p.severity == .error ? .red : p.severity == .warning ? .orange : .blue)
                        .font(.caption)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(p.message).font(.callout).lineLimit(2)
                        Text("\(p.path):\(p.line)\(p.column.map { ":\($0)" } ?? "") · \(p.source)")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                }
                .contentShape(Rectangle())
                .onTapGesture { onOpen(p) }
                .contextMenu { Button("Fix with AI") { onFix([p]) } }
            }
            .listStyle(.plain)
            .frame(maxHeight: .infinity)
        }
    }
}
