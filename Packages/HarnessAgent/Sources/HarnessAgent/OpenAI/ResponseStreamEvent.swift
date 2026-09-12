import Foundation

/// Typed subset of Responses API streaming events.
public enum ResponseStreamEvent: Sendable, Equatable {
    case created(responseID: String)
    case outputItemAdded(index: Int, item: ResponseItem)
    case outputTextDelta(itemID: String, delta: String)
    case reasoningSummaryDelta(itemID: String, delta: String)
    case functionCallArgumentsDelta(itemID: String, delta: String)
    case functionCallArgumentsDone(itemID: String, arguments: String)
    case outputItemDone(index: Int, item: ResponseItem)
    case completed(usage: ResponseUsage?)
    case incomplete(reason: String?)
    case failed(message: String)
    case error(code: String?, message: String)
    case other(type: String)

    static func decode(_ sse: SSEEvent) -> ResponseStreamEvent? {
        guard sse.data != "[DONE]", let data = sse.data.data(using: .utf8),
              let raw = try? JSONDecoder().decode(RawEvent.self, from: data)
        else { return nil }
        let type = raw.type ?? sse.event ?? ""
        switch type {
        case "response.created":
            return .created(responseID: raw.response?.id ?? "")
        case "response.output_item.added":
            guard let item = raw.item else { return nil }
            return .outputItemAdded(index: raw.output_index ?? 0, item: item)
        case "response.output_text.delta":
            return .outputTextDelta(itemID: raw.item_id ?? "", delta: raw.delta ?? "")
        case "response.reasoning_summary_text.delta":
            return .reasoningSummaryDelta(itemID: raw.item_id ?? "", delta: raw.delta ?? "")
        case "response.function_call_arguments.delta":
            return .functionCallArgumentsDelta(itemID: raw.item_id ?? "", delta: raw.delta ?? "")
        case "response.function_call_arguments.done":
            return .functionCallArgumentsDone(itemID: raw.item_id ?? "", arguments: raw.arguments ?? "")
        case "response.output_item.done":
            guard let item = raw.item else { return nil }
            return .outputItemDone(index: raw.output_index ?? 0, item: item)
        case "response.completed":
            return .completed(usage: raw.response?.usage)
        case "response.incomplete":
            return .incomplete(reason: raw.response?.incomplete_details?.reason)
        case "response.failed":
            return .failed(message: raw.response?.error?.message ?? "Response failed")
        case "error":
            return .error(code: raw.code, message: raw.message ?? "Unknown error")
        default:
            return .other(type: type)
        }
    }

    private struct RawEvent: Decodable {
        struct Response: Decodable {
            struct Incomplete: Decodable { var reason: String? }
            struct APIError: Decodable { var message: String? }
            var id: String?
            var usage: ResponseUsage?
            var incomplete_details: Incomplete?
            var error: APIError?
        }
        var type: String?
        var response: Response?
        var item: ResponseItem?
        var item_id: String?
        var output_index: Int?
        var delta: String?
        var arguments: String?
        var code: String?
        var message: String?
    }
}
