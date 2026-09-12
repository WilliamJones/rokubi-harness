import CryptoKit
import Foundation
import Observation

/// Persists conversations per project under Application Support (never inside the repo).
@MainActor
@Observable
public final class ConversationStore {
    public struct Summary: Identifiable, Sendable, Equatable {
        public let id: String
        public let title: String
        public let updatedAt: Date
    }

    public let directory: URL
    public private(set) var summaries: [Summary] = []

    public init(projectRoot: URL) {
        let hash = SHA256.hash(data: Data(projectRoot.standardizedFileURL.path.utf8))
            .prefix(8).map { String(format: "%02x", $0) }.joined()
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ROKUBI Harness/projects/\(hash)/conversations", isDirectory: true)
        directory = base
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        reload()
    }

    public func reload() {
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        summaries = files.filter { $0.pathExtension == "json" }
            .compactMap { load(id: $0.deletingPathExtension().lastPathComponent) }
            .map { Summary(id: $0.id, title: $0.title, updatedAt: $0.updatedAt) }
            .sorted { $0.updatedAt > $1.updatedAt }
    }

    public func load(id: String) -> Conversation? {
        guard let data = try? Data(contentsOf: directory.appendingPathComponent("\(id).json")) else { return nil }
        return try? Self.decoder.decode(Conversation.self, from: data)
    }

    public func save(_ conversation: Conversation) {
        guard !conversation.isEmpty else { return }
        let url = directory.appendingPathComponent("\(conversation.id).json")
        if let data = try? Self.encoder.encode(conversation) {
            try? data.write(to: url, options: .atomic)
        }
        if let i = summaries.firstIndex(where: { $0.id == conversation.id }) { summaries.remove(at: i) }
        summaries.insert(Summary(id: conversation.id, title: conversation.title, updatedAt: conversation.updatedAt), at: 0)
    }

    public func delete(id: String) {
        try? FileManager.default.removeItem(at: directory.appendingPathComponent("\(id).json"))
        summaries.removeAll { $0.id == id }
    }

    private static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        return e
    }()

    private static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()
}
