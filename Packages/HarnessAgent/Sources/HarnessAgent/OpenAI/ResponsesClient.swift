import Foundation

public enum ResponsesClientError: LocalizedError, Sendable {
    case http(status: Int, body: String, provider: String)
    case transport(String)

    public var errorDescription: String? {
        switch self {
        case .http(let status, let body, let provider):
            switch status {
            case 401: "\(provider) rejected the credentials — please sign in again."
            case 429: "Rate limited by \(provider). \(Self.detail(body))"
            default: "\(provider) returned HTTP \(status). \(Self.detail(body))"
            }
        case .transport(let m): m
        }
    }

    private static func detail(_ body: String) -> String {
        if let data = body.data(using: .utf8),
           let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let err = obj["error"] as? [String: Any], let msg = err["message"] as? String { return msg }
        if let data = body.data(using: .utf8),
           let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let detail = obj["detail"] as? String { return detail }
        return String(body.prefix(300))
    }
}

/// Streams `POST /responses` as typed events. Works against both the ChatGPT backend
/// and the platform API — the `AuthProvider` decides base URL and credentials.
public struct ResponsesClient: Sendable {
    public let auth: any AuthProvider
    public let session: URLSession

    public init(auth: any AuthProvider, session: URLSession = .shared) {
        self.auth = auth
        self.session = session
    }

    public func stream(_ body: ResponsesRequest, sessionID: String) -> AsyncThrowingStream<ResponseStreamEvent, any Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    try await run(body, sessionID: sessionID, retryOn401: true, continuation: continuation)
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private func run(_ body: ResponsesRequest, sessionID: String, retryOn401: Bool,
                     continuation: AsyncThrowingStream<ResponseStreamEvent, any Error>.Continuation) async throws {
        let request = try await makeRequest(body, sessionID: sessionID)
        let (bytes, response): (URLSession.AsyncBytes, URLResponse)
        do {
            (bytes, response) = try await session.bytes(for: request)
        } catch {
            throw ResponsesClientError.transport(error.localizedDescription)
        }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            var collected = Data()
            for try await b in bytes { collected.append(b); if collected.count > 64_000 { break } }
            if status == 401, retryOn401 {
                await auth.invalidate()
                return try await run(body, sessionID: sessionID, retryOn401: false, continuation: continuation)
            }
            throw ResponsesClientError.http(status: status, body: String(data: collected, encoding: .utf8) ?? "", provider: auth.providerLabel)
        }

        var parser = SSEParser()
        var chunk: [UInt8] = []
        chunk.reserveCapacity(4096)
        for try await byte in bytes {
            try Task.checkCancellation()
            chunk.append(byte)
            if byte == UInt8(ascii: "\n") {
                for sse in parser.feed(chunk) {
                    if let event = ResponseStreamEvent.decode(sse) { continuation.yield(event) }
                }
                chunk.removeAll(keepingCapacity: true)
            }
        }
        if !chunk.isEmpty {
            for sse in parser.feed(chunk) {
                if let event = ResponseStreamEvent.decode(sse) { continuation.yield(event) }
            }
        }
        if let last = parser.finish(), let event = ResponseStreamEvent.decode(last) { continuation.yield(event) }
    }

    func makeRequest(_ body: ResponsesRequest, sessionID: String) async throws -> URLRequest {
        var request = URLRequest(url: auth.baseURL.appendingPathComponent("responses"))
        request.httpMethod = "POST"
        request.timeoutInterval = 600
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        request.setValue(OpenAIEndpoints.userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue(OpenAIEndpoints.originator, forHTTPHeaderField: "originator")
        request.setValue(OpenAIEndpoints.betaHeader, forHTTPHeaderField: "OpenAI-Beta")
        request.setValue(sessionID, forHTTPHeaderField: "session_id")
        for (k, v) in try await auth.authHeaders() { request.setValue(v, forHTTPHeaderField: k) }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes]
        request.httpBody = try encoder.encode(body)
        return request
    }
}
