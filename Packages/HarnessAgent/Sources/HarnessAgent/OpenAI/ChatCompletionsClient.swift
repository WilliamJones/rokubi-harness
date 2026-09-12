import Foundation

/// Speaks the OpenAI-compatible **Chat Completions** API (`POST {baseURL}/chat/completions`) —
/// the universal shape OpenRouter's whole catalog supports. It maps the harness's Responses-style
/// `input` items into `messages[]`, and translates streamed `choices[].delta` chunks back into the
/// same `ResponseStreamEvent`s the orchestrator already understands.
public struct ChatCompletionsClient: Sendable {
    public let auth: any AuthProvider
    public let session: URLSession

    public init(auth: any AuthProvider, session: URLSession = .shared) {
        self.auth = auth
        self.session = session
    }

    // MARK: Request mapping

    /// Responses `input` items → Chat Completions `messages`.
    static func messages(instructions: String, input: [ResponseItem]) -> [[String: Any]] {
        var messages: [[String: Any]] = [["role": "system", "content": instructions]]
        // A function_call and its assistant text share one assistant message with tool_calls.
        var pendingToolCalls: [[String: Any]] = []

        func flushToolCalls() {
            guard !pendingToolCalls.isEmpty else { return }
            messages.append(["role": "assistant", "content": NSNull(), "tool_calls": pendingToolCalls])
            pendingToolCalls = []
        }

        for item in input {
            switch item.type {
            case "message":
                flushToolCalls()
                messages.append(["role": item.role ?? "user", "content": item.text])
            case "function_call":
                pendingToolCalls.append([
                    "id": item.call_id ?? item.id ?? UUID().uuidString,
                    "type": "function",
                    "function": ["name": item.name ?? "", "arguments": item.arguments ?? "{}"],
                ])
            case "function_call_output":
                flushToolCalls()
                messages.append([
                    "role": "tool",
                    "tool_call_id": item.call_id ?? "",
                    "content": item.output ?? "",
                ])
            case "reasoning":
                // Chat Completions has no reasoning item; the summary (if any) isn't resent.
                continue
            default:
                continue
            }
        }
        flushToolCalls()
        return messages
    }

    /// Function tools nest one level deeper than in the Responses API.
    static func tools(_ defs: [FunctionToolDefinition]) -> [[String: Any]] {
        defs.map { def in
            [
                "type": "function",
                "function": [
                    "name": def.name,
                    "description": def.description,
                    "parameters": def.parameters.asFoundation,
                ],
            ]
        }
    }

    func makeRequest(model: String, instructions: String, input: [ResponseItem],
                     tools: [FunctionToolDefinition], reasoning: ReasoningConfig) async throws -> URLRequest {
        var body: [String: Any] = [
            "model": model,
            "messages": Self.messages(instructions: instructions, input: input),
            "stream": true,
            "stream_options": ["include_usage": true],
        ]
        if !tools.isEmpty {
            body["tools"] = Self.tools(tools)
            body["tool_choice"] = "auto"
            body["parallel_tool_calls"] = true
        }
        // Reasoning effort is honored only by models that support it; OpenRouter ignores it otherwise.
        body["reasoning"] = ["effort": reasoning.effort]

        var request = URLRequest(url: auth.baseURL.appendingPathComponent("chat/completions"))
        request.httpMethod = "POST"
        request.timeoutInterval = 600
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        request.setValue(OpenAIEndpoints.userAgent, forHTTPHeaderField: "User-Agent")
        for (k, v) in try await auth.authHeaders() { request.setValue(v, forHTTPHeaderField: k) }
        request.httpBody = try JSONSerialization.data(withJSONObject: body, options: [.withoutEscapingSlashes])
        return request
    }

    // MARK: Streaming

    public func streamTurn(model: String, instructions: String, input: [ResponseItem],
                           tools: [FunctionToolDefinition], reasoning: ReasoningConfig,
                           sessionID: String, promptCacheKey: String?) -> AsyncThrowingStream<ResponseStreamEvent, any Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    try await run(model: model, instructions: instructions, input: input, tools: tools,
                                  reasoning: reasoning, retryOn401: true, continuation: continuation)
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private func run(model: String, instructions: String, input: [ResponseItem], tools: [FunctionToolDefinition],
                     reasoning: ReasoningConfig, retryOn401: Bool,
                     continuation: AsyncThrowingStream<ResponseStreamEvent, any Error>.Continuation) async throws {
        let request = try await makeRequest(model: model, instructions: instructions, input: input, tools: tools, reasoning: reasoning)
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
                return try await run(model: model, instructions: instructions, input: input, tools: tools,
                                     reasoning: reasoning, retryOn401: false, continuation: continuation)
            }
            throw ResponsesClientError.http(status: status, body: String(data: collected, encoding: .utf8) ?? "", provider: auth.providerLabel)
        }

        var acc = Accumulator()
        var parser = SSEParser()
        var chunk: [UInt8] = []
        for try await byte in bytes {
            try Task.checkCancellation()
            chunk.append(byte)
            if byte == UInt8(ascii: "\n") {
                for sse in parser.feed(chunk) { acc.consume(sse, into: continuation) }
                chunk.removeAll(keepingCapacity: true)
            }
        }
        if !chunk.isEmpty { for sse in parser.feed(chunk) { acc.consume(sse, into: continuation) } }
        if let last = parser.finish() { acc.consume(last, into: continuation) }
        acc.finish(into: continuation)
    }

    /// Replays canned SSE events through the accumulator — for tests of the delta reassembly.
    static func replay(_ events: [SSEEvent]) -> [ResponseStreamEvent] {
        var collected: [ResponseStreamEvent] = []
        let stream = AsyncThrowingStream<ResponseStreamEvent, any Error> { continuation in
            var acc = Accumulator()
            for e in events { acc.consume(e, into: continuation) }
            acc.finish(into: continuation)
            continuation.finish()
        }
        // The stream is fully buffered synchronously above; drain it.
        let semaphore = DispatchSemaphore(value: 0)
        let box = EventBox()
        Task {
            for try await ev in stream { box.append(ev) }
            semaphore.signal()
        }
        semaphore.wait()
        collected = box.events
        return collected
    }

    private final class EventBox: @unchecked Sendable {
        private let lock = NSLock()
        private var _events: [ResponseStreamEvent] = []
        var events: [ResponseStreamEvent] { lock.lock(); defer { lock.unlock() }; return _events }
        func append(_ e: ResponseStreamEvent) { lock.lock(); _events.append(e); lock.unlock() }
    }

    // MARK: Delta accumulation → ResponseStreamEvent

    /// Chat Completions streams partial `choices[].delta`s; we reassemble the assistant text and any
    /// tool calls (whose arguments arrive in fragments), emitting normalized events.
    private struct Accumulator {
        private var textItemID = "msg-\(UUID().uuidString)"
        private var text = ""
        private var textStarted = false
        private var toolByIndex: [Int: (id: String, name: String, args: String)] = [:]
        private var usage: ResponseUsage?
        private var finished = false

        mutating func consume(_ sse: SSEEvent, into c: AsyncThrowingStream<ResponseStreamEvent, any Error>.Continuation) {
            let data = sse.data.trimmingCharacters(in: .whitespaces)
            guard data != "[DONE]", let raw = data.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: raw) as? [String: Any] else { return }

            if let u = obj["usage"] as? [String: Any] {
                usage = ResponseUsage(input_tokens: (u["prompt_tokens"] as? Int) ?? 0,
                                      output_tokens: (u["completion_tokens"] as? Int) ?? 0,
                                      total_tokens: u["total_tokens"] as? Int)
            }
            guard let choices = obj["choices"] as? [[String: Any]], let choice = choices.first else { return }
            if let delta = choice["delta"] as? [String: Any] {
                if let piece = delta["content"] as? String, !piece.isEmpty {
                    if !textStarted {
                        textStarted = true
                        c.yield(.outputItemAdded(index: 0, item: ResponseItem(type: "message", id: textItemID, role: "assistant")))
                    }
                    text += piece
                    c.yield(.outputTextDelta(itemID: textItemID, delta: piece))
                }
                if let calls = delta["tool_calls"] as? [[String: Any]] {
                    for call in calls {
                        let idx = (call["index"] as? Int) ?? 0
                        var entry = toolByIndex[idx] ?? (id: "", name: "", args: "")
                        if let id = call["id"] as? String, !id.isEmpty { entry.id = id }
                        if let fn = call["function"] as? [String: Any] {
                            if let name = fn["name"] as? String, !name.isEmpty { entry.name = name }
                            if let a = fn["arguments"] as? String { entry.args += a }
                        }
                        toolByIndex[idx] = entry
                    }
                }
            }
        }

        mutating func finish(into c: AsyncThrowingStream<ResponseStreamEvent, any Error>.Continuation) {
            guard !finished else { return }
            finished = true
            if textStarted {
                c.yield(.outputItemDone(index: 0, item: ResponseItem(
                    type: "message", id: textItemID, role: "assistant",
                    content: [.init(type: "output_text", text: text)], status: "completed")))
            }
            for idx in toolByIndex.keys.sorted() {
                let t = toolByIndex[idx]!
                let callID = t.id.isEmpty ? "call-\(idx)-\(UUID().uuidString)" : t.id
                c.yield(.outputItemDone(index: 1 + idx, item: ResponseItem(
                    type: "function_call", id: callID, call_id: callID,
                    name: t.name, arguments: t.args.isEmpty ? "{}" : t.args, status: "completed")))
            }
            c.yield(.completed(usage: usage))
        }
    }
}

extension ChatCompletionsClient: LLMClient {}

// Bridge JSONValue (tool schemas) to Foundation JSON for JSONSerialization request bodies.
extension JSONValue {
    var asFoundation: Any {
        switch self {
        case .string(let s): return s
        case .number(let n): return n
        case .bool(let b): return b
        case .null: return NSNull()
        case .array(let a): return a.map(\.asFoundation)
        case .object(let o): return o.mapValues(\.asFoundation)
        }
    }
}
