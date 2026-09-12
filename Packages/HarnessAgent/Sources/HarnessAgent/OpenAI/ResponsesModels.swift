import Foundation

// Wire types for the Responses API. Only what the harness uses.

/// A JSON value — used for tool schemas and tool-call arguments without a fixed shape.
public enum JSONValue: Codable, Sendable, Equatable, Hashable {
    case string(String), number(Double), bool(Bool), null
    case array([JSONValue]), object([String: JSONValue])

    public init(from decoder: any Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let b = try? c.decode(Bool.self) { self = .bool(b) }
        else if let n = try? c.decode(Double.self) { self = .number(n) }
        else if let s = try? c.decode(String.self) { self = .string(s) }
        else if let a = try? c.decode([JSONValue].self) { self = .array(a) }
        else if let o = try? c.decode([String: JSONValue].self) { self = .object(o) }
        else { throw DecodingError.dataCorruptedError(in: c, debugDescription: "Unsupported JSON") }
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .string(let s): try c.encode(s)
        case .number(let n): try c.encode(n)
        case .bool(let b): try c.encode(b)
        case .null: try c.encodeNil()
        case .array(let a): try c.encode(a)
        case .object(let o): try c.encode(o)
        }
    }

    public var stringValue: String? { if case .string(let s) = self { return s }; return nil }
    /// `Int(n)` traps on non-finite or out-of-range doubles, and tool arguments come from the model.
    public var intValue: Int? {
        guard case .number(let n) = self, n.isFinite, abs(n) < 9_007_199_254_740_992 else { return nil }
        return Int(n)
    }
    public var boolValue: Bool? { if case .bool(let b) = self { return b }; return nil }
    public var arrayValue: [JSONValue]? { if case .array(let a) = self { return a }; return nil }
    public var objectValue: [String: JSONValue]? { if case .object(let o) = self { return o }; return nil }

    public subscript(key: String) -> JSONValue? { objectValue?[key] }

    /// Parses a JSON document (tool-call `arguments` strings).
    public static func parse(_ text: String) -> JSONValue? {
        guard let data = text.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(JSONValue.self, from: data)
    }
}

/// Function tool definition sent in `tools`.
public struct FunctionToolDefinition: Codable, Sendable, Equatable {
    public var type = "function"
    public var name: String
    public var description: String
    public var parameters: JSONValue
    public var strict: Bool

    public init(name: String, description: String, parameters: JSONValue, strict: Bool = false) {
        self.name = name
        self.description = description
        self.parameters = parameters
        self.strict = strict
    }
}

/// One entry in `input` (also the shape of items returned in `output`).
public struct ResponseItem: Codable, Sendable, Equatable {
    public struct ContentPart: Codable, Sendable, Equatable {
        public var type: String     // input_text | output_text
        public var text: String?
        public init(type: String, text: String?) { self.type = type; self.text = text }
    }
    public struct SummaryPart: Codable, Sendable, Equatable {
        public var type: String     // summary_text
        public var text: String
    }

    public var type: String         // message | reasoning | function_call | function_call_output
    public var id: String?
    public var role: String?
    public var content: [ContentPart]?
    public var summary: [SummaryPart]?
    public var encrypted_content: String?
    public var call_id: String?
    public var name: String?
    public var arguments: String?
    public var output: String?
    public var status: String?

    public init(type: String, id: String? = nil, role: String? = nil, content: [ContentPart]? = nil,
                summary: [SummaryPart]? = nil, encrypted_content: String? = nil, call_id: String? = nil,
                name: String? = nil, arguments: String? = nil, output: String? = nil, status: String? = nil) {
        self.type = type; self.id = id; self.role = role; self.content = content; self.summary = summary
        self.encrypted_content = encrypted_content; self.call_id = call_id; self.name = name
        self.arguments = arguments; self.output = output; self.status = status
    }

    public static func userMessage(_ text: String) -> ResponseItem {
        ResponseItem(type: "message", role: "user", content: [.init(type: "input_text", text: text)])
    }

    public static func assistantMessage(_ text: String) -> ResponseItem {
        ResponseItem(type: "message", role: "assistant", content: [.init(type: "output_text", text: text)])
    }

    public static func functionCallOutput(callID: String, output: String) -> ResponseItem {
        ResponseItem(type: "function_call_output", call_id: callID, output: output)
    }

    public var text: String { (content ?? []).compactMap(\.text).joined() }
}

public struct ReasoningConfig: Codable, Sendable, Equatable {
    public var effort: String
    public var summary: String
    public init(effort: String = "medium", summary: String = "auto") { self.effort = effort; self.summary = summary }
}

public struct ResponsesRequest: Codable, Sendable {
    public var model: String
    public var instructions: String
    public var input: [ResponseItem]
    public var tools: [FunctionToolDefinition]
    public var tool_choice = "auto"
    public var parallel_tool_calls = true
    public var reasoning: ReasoningConfig
    public var store = false
    public var stream = true
    public var include = ["reasoning.encrypted_content"]
    public var prompt_cache_key: String?

    public init(model: String, instructions: String, input: [ResponseItem], tools: [FunctionToolDefinition],
                reasoning: ReasoningConfig = ReasoningConfig(), promptCacheKey: String? = nil) {
        self.model = model
        self.instructions = instructions
        self.input = input
        self.tools = tools
        self.reasoning = reasoning
        self.prompt_cache_key = promptCacheKey
    }
}

public struct ResponseUsage: Codable, Sendable, Equatable {
    public var input_tokens: Int
    public var output_tokens: Int
    public var total_tokens: Int?
    public struct Details: Codable, Sendable, Equatable { public var cached_tokens: Int? }
    public var input_tokens_details: Details?

    public init(input_tokens: Int, output_tokens: Int, total_tokens: Int? = nil, cached: Int? = nil) {
        self.input_tokens = input_tokens
        self.output_tokens = output_tokens
        self.total_tokens = total_tokens
        self.input_tokens_details = cached.map { Details(cached_tokens: $0) }
    }
}
