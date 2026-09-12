import Foundation

/// Incremental Server-Sent Events parser. Feed it bytes; it yields complete events.
/// Works on UTF-8 bytes so `\r\n` is never mistaken for a single character.
struct SSEEvent: Sendable, Equatable {
    var event: String?
    var data: String
}

struct SSEParser: Sendable {
    private var buffer: [UInt8] = []
    private var currentEvent: String?
    private var currentData: [String] = []

    mutating func feed(_ chunk: String) -> [SSEEvent] {
        feed(Array(chunk.utf8))
    }

    mutating func feed(_ bytes: some Sequence<UInt8>) -> [SSEEvent] {
        buffer.append(contentsOf: bytes)
        var events: [SSEEvent] = []
        var start = 0
        var i = 0
        while i < buffer.count {
            if buffer[i] == UInt8(ascii: "\n") {
                var end = i
                if end > start, buffer[end - 1] == UInt8(ascii: "\r") { end -= 1 }
                let line = String(decoding: buffer[start..<end], as: UTF8.self)
                if let e = consume(line: line) { events.append(e) }
                start = i + 1
            }
            i += 1
        }
        buffer.removeFirst(start)
        return events
    }

    /// Call at end of stream to flush a trailing event with no blank line.
    mutating func finish() -> SSEEvent? {
        if !buffer.isEmpty {
            var bytes = buffer
            if bytes.last == UInt8(ascii: "\r") { bytes.removeLast() }
            buffer = []
            _ = consume(line: String(decoding: bytes, as: UTF8.self))
        }
        return flush()
    }

    private mutating func consume(line: String) -> SSEEvent? {
        if line.isEmpty { return flush() }
        if line.hasPrefix(":") { return nil }
        let field: String
        let value: String
        if let colon = line.firstIndex(of: ":") {
            field = String(line[line.startIndex..<colon])
            var v = String(line[line.index(after: colon)...])
            if v.hasPrefix(" ") { v.removeFirst() }
            value = v
        } else {
            field = line
            value = ""
        }
        switch field {
        case "event": currentEvent = value
        case "data": currentData.append(value)
        default: break
        }
        return nil
    }

    private mutating func flush() -> SSEEvent? {
        guard !currentData.isEmpty || currentEvent != nil else { return nil }
        let e = SSEEvent(event: currentEvent, data: currentData.joined(separator: "\n"))
        currentEvent = nil
        currentData = []
        return e
    }
}
