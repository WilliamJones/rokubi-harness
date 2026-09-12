import Foundation
import Observation
import WebKit

/// Swift-side handle on one Monaco web view. Commands sent before the page is
/// ready are queued and flushed on `ready`.
@MainActor
@Observable
public final class MonacoController {
    public private(set) var isReady = false

    /// Receives editor events (content changes, selection, ⌘S, logs).
    public var onEvent: ((MonacoEvent) -> Void)?

    @ObservationIgnored weak var webView: WKWebView?
    // Plumbing, not UI state: must not invalidate SwiftUI views when mutated.
    @ObservationIgnored private var queued: [(js: String, onError: (@MainActor (any Error) -> Void)?)] = []
    @ObservationIgnored private var pending: [String: CheckedContinuation<MonacoResponse, any Error>] = [:]

    public init() {}

    // MARK: Models

    public func openModel(id: String, path: String, language: String? = nil, text: String) {
        send(["type": "openModel", "id": id, "path": path, "language": language as Any, "text": text])
    }

    public func closeModel(id: String) { send(["type": "closeModel", "id": id]) }
    public func activate(id: String) { send(["type": "activate", "id": id]) }
    public func setContent(id: String, text: String) { send(["type": "setContent", "id": id, "text": text]) }

    public func content(id: String) async throws -> String? {
        try await request(["type": "getContent", "id": id]).text
    }

    public func setMarkers(id: String, _ markers: [MonacoMarker]) {
        let encoded = markers.map { m -> [String: Any] in
            var d: [String: Any] = ["line": m.line, "column": m.column, "message": m.message, "severity": m.severity.rawValue]
            if let e = m.endLine { d["endLine"] = e }
            if let e = m.endColumn { d["endColumn"] = e }
            if let s = m.source { d["source"] = s }
            return d
        }
        send(["type": "setMarkers", "id": id, "markers": encoded])
    }

    public func revealLine(id: String, line: Int, column: Int = 1) {
        send(["type": "revealLine", "id": id, "line": line, "column": column])
    }

    // MARK: Diff

    public func showDiff(id: String, path: String, language: String? = nil, original: String, modified: String) {
        send(["type": "showDiff", "id": id, "path": path, "language": language as Any,
              "original": original, "modified": modified])
    }

    public func hideDiff() { send(["type": "hideDiff"]) }

    public func diffHunks() async throws -> [DiffHunk] {
        try await request(["type": "getDiffHunks"]).hunks
    }

    public enum HunkDirection: String, Sendable { case revert, accept }

    @discardableResult
    public func applyHunk(index: Int, direction: HunkDirection) async throws -> Bool {
        try await request(["type": "applyHunk", "index": index, "direction": direction.rawValue]).ok
    }

    // MARK: Editor

    public func runAction(_ action: String) { send(["type": "runAction", "action": action]) }
    public func setTheme(dark: Bool) { send(["type": "setTheme", "dark": dark]) }
    public func setOptions(_ options: [String: Any]) { send(["type": "setOptions", "options": options]) }
    public func focus() { send(["type": "focus"]) }

    // MARK: Plumbing

    func attach(_ webView: WKWebView) { self.webView = webView }

    func handleScriptMessage(_ body: Any) {
        let (event, response) = MonacoMessageParser.parse(body)
        if let (id, value) = response {
            pending.removeValue(forKey: id)?.resume(returning: value)
            return
        }
        guard let event else { return }
        if case .ready = event {
            isReady = true
            let flush = queued
            queued.removeAll()
            for item in flush { evaluate(item.js, onError: item.onError) }
        }
        onEvent?(event)
    }

    func pageDidReload() {
        isReady = false
        for (_, c) in pending { c.resume(throwing: MonacoError.pageReloaded) }
        pending.removeAll()
    }

    /// Builds the `window.harness.receive(...)` call for a payload, or nil if it cannot be encoded.
    private func script(for payload: [String: Any]) -> String? {
        let clean = payload.compactMapValues { $0 is NSNull ? nil : $0 }
        guard let data = try? JSONSerialization.data(withJSONObject: clean),
              let json = String(data: data, encoding: .utf8) else { return nil }
        // Pass the JSON as a string literal; JSONSerialization already escaped quotes/backslashes,
        // only the outer literal needs U+2028/2029 handled for JS string safety.
        let literal = json
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\u{2028}", with: "\\u2028")
            .replacingOccurrences(of: "\u{2029}", with: "\\u2029")
        return "window.harness.receive(\"\(literal)\");"
    }

    private func send(_ payload: [String: Any], onError: (@MainActor (any Error) -> Void)? = nil) {
        guard let js = script(for: payload) else {
            onError?(MonacoError.encodingFailed)
            return
        }
        if isReady { evaluate(js, onError: onError) } else { queued.append((js, onError)) }
    }

    /// Sends a request and waits for the page's `response`. The continuation is always resumed:
    /// with the reply, with the JS error when `evaluateJavaScript` fails, with `pageReloaded` on
    /// navigation, or with `timedOut` if the page never answers within `timeout`.
    private func request(_ payload: [String: Any], timeout: Duration = .seconds(5)) async throws -> MonacoResponse {
        let id = UUID().uuidString
        var p = payload
        p["requestId"] = id
        let watchdog = Task { [weak self] in
            do { try await Task.sleep(for: timeout) } catch { return }   // cancelled = answered
            self?.fail(requestID: id, with: MonacoError.timedOut)
        }
        defer { watchdog.cancel() }
        return try await withCheckedThrowingContinuation { continuation in
            pending[id] = continuation
            send(p) { [weak self] error in self?.fail(requestID: id, with: error) }
        }
    }

    private func fail(requestID id: String, with error: any Error) {
        pending.removeValue(forKey: id)?.resume(throwing: error)
    }

    private func evaluate(_ js: String, onError: (@MainActor (any Error) -> Void)? = nil) {
        guard let webView else {
            onError?(MonacoError.notAttached)
            return
        }
        webView.evaluateJavaScript(js) { _, error in
            guard let error else { return }
            NSLog("[Monaco] evaluateJavaScript failed: \(error)")
            // WKWebView invokes the completion on the main thread; hop explicitly for the compiler.
            MainActor.assumeIsolated { onError?(error) }
        }
    }
}

/// Failures of the Swift → Monaco request/response channel.
public enum MonacoError: Error, Sendable, Equatable {
    /// The page did not answer within the request timeout.
    case timedOut
    /// `evaluateJavaScript` could not run because no web view is attached.
    case notAttached
    /// The payload could not be serialized to JSON.
    case encodingFailed
    /// The page navigated/reloaded while the request was in flight.
    case pageReloaded
}
