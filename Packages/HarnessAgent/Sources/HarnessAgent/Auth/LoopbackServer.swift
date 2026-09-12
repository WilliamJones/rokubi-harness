import Foundation
import Network

/// One-shot HTTP listener for the OAuth redirect (`http://localhost:1455/auth/callback`).
/// Accepts a single request, hands back its query parameters, and replies with a
/// small "you can close this tab" page.
final class LoopbackServer: @unchecked Sendable {
    struct Callback: Sendable {
        let code: String
        let state: String
    }

    enum Failure: LocalizedError {
        case portInUse(UInt16)
        case badRequest(String)
        case cancelled

        var errorDescription: String? {
            switch self {
            case .portInUse(let p): "Port \(p) is already in use. Close other sign-in windows and try again."
            case .badRequest(let m): "Sign-in callback was malformed: \(m)"
            case .cancelled: "Sign-in was cancelled."
            }
        }
    }

    private let port: UInt16
    private let path: String
    private var listener: NWListener?
    private let queue = DispatchQueue(label: "com.rokubi.harness.oauth-loopback")
    private var continuation: CheckedContinuation<Callback, any Error>?
    private let lock = NSLock()

    init(port: UInt16, path: String) {
        self.port = port
        self.path = path
    }

    /// Starts listening and resolves when the browser hits the callback URL.
    func waitForCallback() async throws -> Callback {
        try await withCheckedThrowingContinuation { continuation in
            lock.lock(); self.continuation = continuation; lock.unlock()
            do {
                let params = NWParameters.tcp
                params.allowLocalEndpointReuse = true
                params.requiredInterfaceType = .loopback
                let listener = try NWListener(using: params, on: NWEndpoint.Port(rawValue: port)!)
                lock.lock(); self.listener = listener; lock.unlock()
                listener.stateUpdateHandler = { [weak self] state in
                    if case .failed = state { self?.finish(.failure(Failure.portInUse(self?.port ?? 0))) }
                }
                listener.newConnectionHandler = { [weak self] connection in
                    self?.handle(connection)
                }
                listener.start(queue: queue)
            } catch {
                finish(.failure(error))
            }
        }
    }

    func cancel() {
        finish(.failure(Failure.cancelled))
    }

    private func handle(_ connection: NWConnection) {
        connection.start(queue: queue)
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, _, _ in
            guard let self, let data, let request = String(data: data, encoding: .utf8) else {
                connection.cancel(); return
            }
            let result = self.parse(request)
            let body: String
            switch result {
            case .success: body = Self.successPage
            case .failure(let error): body = Self.errorPage(error.localizedDescription)
            }
            let response = "HTTP/1.1 200 OK\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n\(body)"
            connection.send(content: Data(response.utf8), completion: .contentProcessed { _ in
                connection.cancel()
                // Ignore favicon or unrelated hits; only finish on the callback path.
                if case .failure(let e as Failure) = result, case .badRequest(let m) = e, m == "ignored" { return }
                self.finish(result)
            })
        }
    }

    private func parse(_ request: String) -> Result<Callback, any Error> {
        guard let requestLine = request.split(separator: "\r\n").first,
              let target = requestLine.split(separator: " ").dropFirst().first,
              let components = URLComponents(string: "http://localhost\(target)")
        else { return .failure(Failure.badRequest("no request line")) }
        guard components.path == path else { return .failure(Failure.badRequest("ignored")) }
        let items = components.queryItems ?? []
        if let error = items.first(where: { $0.name == "error" })?.value {
            let description = items.first(where: { $0.name == "error_description" })?.value ?? error
            return .failure(Failure.badRequest(description))
        }
        guard let code = items.first(where: { $0.name == "code" })?.value,
              let state = items.first(where: { $0.name == "state" })?.value
        else { return .failure(Failure.badRequest("missing code/state")) }
        return .success(Callback(code: code, state: state))
    }

    private func finish(_ result: Result<Callback, any Error>) {
        lock.lock()
        let c = continuation
        continuation = nil
        let l = listener
        listener = nil
        lock.unlock()
        l?.cancel()
        c?.resume(with: result)
    }

    private static let successPage = """
    <!doctype html><meta charset=utf-8><title>ROKUBI Harness</title>
    <body style="font:15px -apple-system,system-ui;display:grid;place-items:center;height:100vh;margin:0;color:#333;background:#fafafa">
    <div style="text-align:center"><h2 style="font-weight:600">Signed in to ROKUBI Harness</h2><p>You can close this tab and return to the app.</p></div>
    """

    private static func errorPage(_ message: String) -> String {
        """
        <!doctype html><meta charset=utf-8><title>ROKUBI Harness</title>
        <body style="font:15px -apple-system,system-ui;display:grid;place-items:center;height:100vh;margin:0;color:#333;background:#fafafa">
        <div style="text-align:center"><h2 style="font-weight:600">Sign-in failed</h2><p>\(message)</p></div>
        """
    }
}
