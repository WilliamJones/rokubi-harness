import HarnessAgent
import SwiftUI

/// Searchable model picker. Fuzzy-filters the catalog (hundreds of models on OpenRouter) and
/// shows each model's name, id, context length, and price.
struct ModelSearchView: View {
    @Environment(ModelCatalog.self) private var models
    @Environment(AuthSession.self) private var auth
    @Binding var isPresented: Bool
    @State private var query = ""
    @FocusState private var focused: Bool

    private var results: [ModelInfo] { models.search(query) }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Search \(models.models.count) models…", text: $query)
                    .textFieldStyle(.plain).focused($focused)
                if models.isLoading { ProgressView().controlSize(.mini) }
            }
            .padding(12)
            Divider()

            if results.isEmpty {
                ContentUnavailableView("No models match", systemImage: "questionmark.circle")
                    .frame(maxHeight: .infinity)
            } else {
                ScrollViewReader { proxy in
                    List(results) { model in
                        Button {
                            models.select(model.id)
                            isPresented = false
                        } label: {
                            HStack(spacing: 10) {
                                Image(systemName: model.id == models.selected ? "checkmark.circle.fill" : "circle")
                                    .foregroundStyle(model.id == models.selected ? Color.accentColor : Color.secondary)
                                    .font(.system(size: 13))
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(model.name).lineLimit(1)
                                    Text(model.subtitle ?? model.id)
                                        .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                                }
                                Spacer(minLength: 0)
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .listRowInsets(EdgeInsets(top: 4, leading: 10, bottom: 4, trailing: 10))
                        .id(model.id)
                    }
                    .listStyle(.plain)
                    .onAppear { if let selected = models.selected { proxy.scrollTo(selected, anchor: .center) } }
                }
            }

            Divider()
            HStack {
                Text(providerLabel).font(.caption).foregroundStyle(.tertiary)
                Spacer()
                Button {
                    if let provider = auth.provider { Task { await models.refresh(using: provider) } }
                } label: { Label("Refresh", systemImage: "arrow.clockwise").font(.caption) }
                .buttonStyle(.plain).foregroundStyle(.secondary)
                .disabled(!auth.isSignedIn)
            }
            .padding(.horizontal, 12).padding(.vertical, 8)
        }
        .onAppear { focused = true }
    }

    private var providerLabel: String {
        switch auth.account?.mode {
        case .openRouter: "OpenRouter · any model"
        case .chatGPT: "ChatGPT models"
        case .apiKey: "OpenAI models"
        case nil: "Sign in to load models"
        }
    }
}
