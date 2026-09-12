import HarnessAgent
import SwiftUI

/// PRD §25 — ⌘K palette, the escape hatch for capabilities that don't earn permanent UI.
public struct HarnessCommand: Identifiable, Sendable {
    public let id: String
    public let title: String
    public let subtitle: String?
    public let systemImage: String
    public let action: @MainActor () -> Void

    public init(id: String, title: String, subtitle: String? = nil, systemImage: String, action: @escaping @MainActor () -> Void) {
        self.id = id; self.title = title; self.subtitle = subtitle; self.systemImage = systemImage; self.action = action
    }
}

struct CommandPalette: View {
    let commands: [HarnessCommand]
    @Binding var isPresented: Bool
    @State private var query = ""
    @State private var selection = 0
    @FocusState private var focused: Bool

    private var filtered: [HarnessCommand] {
        guard !query.isEmpty else { return commands }
        let q = query.lowercased()
        return commands
            .compactMap { c -> (HarnessCommand, Int)? in
                guard let score = fuzzyScore(q, in: c.title.lowercased()) else { return nil }
                return (c, score)
            }
            .sorted { $0.1 > $1.1 }
            .map(\.0)
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Type a command…", text: $query)
                    .textFieldStyle(.plain).font(.title3).focused($focused)
                    .onSubmit(runSelected)
            }
            .padding(14)
            Divider()
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(Array(filtered.enumerated()), id: \.element.id) { index, command in
                            CommandRow(command: command, isSelected: index == selection)
                                .id(index)
                                .onTapGesture { selection = index; runSelected() }
                        }
                    }
                }
                .frame(maxHeight: 340)
                .onChange(of: selection) { _, s in withAnimation { proxy.scrollTo(s, anchor: .center) } }
            }
        }
        .frame(width: 560)
        .background(.regularMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(.quaternary))
        .onChange(of: query) { _, _ in selection = 0 }
        .onAppear { focused = true }
        .onKeyPress(.downArrow) { selection = min(selection + 1, max(0, filtered.count - 1)); return .handled }
        .onKeyPress(.upArrow) { selection = max(selection - 1, 0); return .handled }
        .onKeyPress(.escape) { isPresented = false; return .handled }
    }

    private func runSelected() {
        guard filtered.indices.contains(selection) else { return }
        let command = filtered[selection]
        isPresented = false
        command.action()
    }
}

private struct CommandRow: View {
    let command: HarnessCommand
    let isSelected: Bool

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: command.systemImage).frame(width: 20).foregroundStyle(isSelected ? .white : .secondary)
            VStack(alignment: .leading, spacing: 1) {
                Text(command.title).foregroundStyle(isSelected ? .white : .primary)
                if let subtitle = command.subtitle {
                    Text(subtitle).font(.caption).foregroundStyle(isSelected ? .white.opacity(0.8) : .secondary).lineLimit(1)
                }
            }
            Spacer()
        }
        .padding(.horizontal, 14).padding(.vertical, 8)
        .background(isSelected ? Color.accentColor : .clear)
        .contentShape(Rectangle())
    }
}
