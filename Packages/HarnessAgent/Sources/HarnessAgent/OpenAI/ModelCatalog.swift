import Foundation
import Observation

/// One selectable model, with enough metadata for a search-and-pick UI.
public struct ModelInfo: Identifiable, Sendable, Equatable, Hashable {
    public let id: String            // the slug sent as `model`
    public let name: String          // human label
    public let subtitle: String?     // context length + price, or provider note
    public init(id: String, name: String, subtitle: String? = nil) {
        self.id = id; self.name = name; self.subtitle = subtitle
    }
}

/// Which models the signed-in account may use. Fetched from the provider's `/models` when
/// possible; otherwise a small static list the user can override. Supports fuzzy search so the
/// OpenRouter catalog (hundreds of models) is navigable.
@MainActor
@Observable
public final class ModelCatalog {
    public static let fallbackModels = ["gpt-5.4", "gpt-5.4-mini", "gpt-5.3-codex", "gpt-5.2"]

    /// Where the user's choice for one account type is saved. Each account type keeps its own choice,
    /// because model ids differ between providers. The older app-wide keys (`model.selected`,
    /// `model.userSelected`) are ignored; the first could hold a model the app picked on its own.
    nonisolated public static func selectionKey(for mode: AccountInfo.Mode) -> String {
        "model.userSelected.\(mode.rawValue)"
    }

    public private(set) var models: [ModelInfo] = ModelCatalog.fallbackModels.map { ModelInfo(id: $0, name: $0) }

    /// The model the user picked for the current account type, or nil until they pick one. The app
    /// never chooses a model by itself, and a refresh that doesn't list the choice keeps it.
    /// Change it with `select(_:)`; follow the signed-in account with `setAccount(_:)`.
    public private(set) var selected: String? = nil
    /// The account type whose choice `selected` shows. Nil while signed out.
    public private(set) var accountMode: AccountInfo.Mode? = nil
    public private(set) var isLoading = false

    private let defaults: UserDefaults
    /// Debug-only `--model <id>` (or ROKUBI_MODEL): used for every account during that run, never saved.
    private let launchOverride: String?

    public convenience init(defaults: UserDefaults = .standard) {
        self.init(defaults: defaults, launchOverride: OpenAIEndpoints.testOverride(env: "ROKUBI_MODEL", flag: "--model"))
    }

    init(defaults: UserDefaults, launchOverride: String?) {
        let override = (launchOverride?.isEmpty ?? true) ? nil : launchOverride
        self.defaults = defaults
        self.launchOverride = override
        selected = override
    }

    public var selectedInfo: ModelInfo? { models.first { $0.id == selected } }

    /// Switches to the saved choice for this account type, or nil if the user never picked one for it.
    /// Restoring never writes anything. The model list goes back to the fallback until the next
    /// refresh, so one provider's models are never offered for another.
    public func setAccount(_ mode: AccountInfo.Mode?) {
        guard mode != accountMode else { return }
        accountMode = mode
        models = Self.fallbackModels.map { ModelInfo(id: $0, name: $0) }
        if let launchOverride { selected = launchOverride; return }
        selected = mode.flatMap { defaults.string(forKey: Self.selectionKey(for: $0)) }
    }

    /// Records the user's choice for the current account type and saves it so it survives restarts.
    /// Only user actions call this. With no account signed in there's nowhere to save it, so it lasts
    /// for this run only. (A `didSet` would also fire for the assignment in `init` under `@Observable`.)
    public func select(_ id: String?) {
        selected = id
        guard let accountMode else { return }
        let key = Self.selectionKey(for: accountMode)
        if let id { defaults.set(id, forKey: key) } else { defaults.removeObject(forKey: key) }
    }

    /// Fuzzy search over id, name, and subtitle. Empty query returns the full list.
    public func search(_ query: String, limit: Int = 60) -> [ModelInfo] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return Array(models.prefix(limit)) }
        return models
            .compactMap { m -> (ModelInfo, Int)? in
                let hay = "\(m.id) \(m.name)".lowercased()
                guard let s = fuzzyScore(q, in: hay) else { return nil }
                return (m, s)
            }
            .sorted { $0.1 > $1.1 }
            .prefix(limit)
            .map(\.0)
    }

    /// Best-effort refresh; keeps the current list on any failure.
    public func refresh(using auth: any AuthProvider, session: URLSession = .shared) async {
        isLoading = true
        defer { isLoading = false }
        var request = URLRequest(url: auth.baseURL.appendingPathComponent("models"))
        request.timeoutInterval = 20
        request.setValue(OpenAIEndpoints.userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue(OpenAIEndpoints.originator, forHTTPHeaderField: "originator")
        guard let headers = try? await auth.authHeaders() else { return }
        for (k, v) in headers { request.setValue(v, forHTTPHeaderField: k) }

        guard let (data, response) = try? await session.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }

        let entries = (json["data"] ?? json["models"]) as? [[String: Any]] ?? []
        let parsed: [ModelInfo] = entries.compactMap { e in
            guard let id = (e["id"] ?? e["slug"] ?? e["name"]) as? String else { return nil }
            let name = (e["name"] as? String) ?? id
            return ModelInfo(id: id, name: name, subtitle: Self.subtitle(for: e))
        }
        let deduped = Self.dedupe(parsed)
        guard !deduped.isEmpty else { return }
        models = deduped   // never touches `selected`: only the user chooses a model
    }

    // MARK: Helpers

    private static func dedupe(_ list: [ModelInfo]) -> [ModelInfo] {
        var seen = Set<String>()
        return list.filter { seen.insert($0.id).inserted }
    }

    /// "128K ctx · $3.00/$15.00 per 1M" from OpenRouter fields, when present.
    private static func subtitle(for e: [String: Any]) -> String? {
        var parts: [String] = []
        if let ctx = (e["context_length"] as? Int) ?? (e["context_length"] as? NSNumber)?.intValue, ctx > 0 {
            parts.append(ctx >= 1000 ? "\(ctx / 1000)K ctx" : "\(ctx) ctx")
        }
        if let pricing = e["pricing"] as? [String: Any] {
            let inTok = perMillion(pricing["prompt"])
            let outTok = perMillion(pricing["completion"])
            if let inTok, let outTok {
                parts.append(inTok == "0" && outTok == "0" ? "free" : "$\(inTok)/$\(outTok) per 1M")
            }
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    /// OpenRouter prices are per-token USD strings; show per-million with sensible precision.
    private static func perMillion(_ raw: Any?) -> String? {
        let value: Double?
        if let s = raw as? String { value = Double(s) }
        else if let n = raw as? NSNumber { value = n.doubleValue }
        else { value = nil }
        guard let v = value else { return nil }
        let m = v * 1_000_000
        if m == 0 { return "0" }
        return m >= 10 ? String(format: "%.0f", m) : String(format: "%.2f", m)
    }
}

/// Subsequence fuzzy match: all query chars appear in order; contiguous runs score higher.
/// Shared by the model search and the command palette.
public func fuzzyScore(_ query: String, in text: String) -> Int? {
    var score = 0, streak = 0
    var ti = text.startIndex
    for qc in query {
        var matched = false
        while ti < text.endIndex {
            let tc = text[ti]
            ti = text.index(after: ti)
            if tc == qc { matched = true; streak += 1; score += 1 + streak; break }
            streak = 0
        }
        if !matched { return nil }
    }
    return score
}
