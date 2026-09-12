import AppKit
import Foundation

/// A pragmatic terminal model: a scrollback of lines with SGR colours, handling `\n`,
/// `\r` (progress bars overwrite the current line), backspace, and stripping every other
/// CSI/OSC sequence. It is not a VT100 emulator — full-screen apps need SwiftTerm — but it
/// renders build/test/git output faithfully and is what the agent reads.
public struct ANSILineBuffer: Sendable {
    public struct Style: Sendable, Equatable, Hashable {
        public var foreground: Int? = nil   // 0–255 palette index, or nil for default
        public var background: Int? = nil
        public var bold = false
        public var dim = false
        public var italic = false
        public var underline = false
        public init() {}
    }

    public struct Run: Sendable, Equatable {
        public var text: String
        public var style: Style
    }

    public struct Line: Sendable, Equatable {
        public var runs: [Run] = []
        public var plain: String { runs.map(\.text).joined() }
    }

    public private(set) var lines: [Line] = [Line()]
    public var maxLines = 5000
    /// Total lines trimmed from the front of `lines` to honour `maxLines`. Lets a view that
    /// mirrors the scrollback drop the same head instead of re-rendering everything.
    public private(set) var droppedLines = 0
    private var style = Style()
    private var cursorColumn = 0        // within the current line, in characters
    private var pending: [UInt8] = []   // partial escape / UTF-8 sequence carried between feeds

    public init() {}

    public var plainText: String { lines.map(\.plain).joined(separator: "\n") }

    /// Last `n` lines as plain text — what the agent sees.
    public func tail(_ n: Int) -> String {
        lines.suffix(n).map(\.plain).joined(separator: "\n")
    }

    public mutating func clear() {
        lines = [Line()]
        cursorColumn = 0
    }

    public mutating func feed(_ data: Data) {
        var bytes = pending + Array(data)
        pending = []
        var i = 0
        var text: [UInt8] = []

        func flushText() {
            guard !text.isEmpty else { return }
            append(String(decoding: text, as: UTF8.self))
            text.removeAll()
        }

        while i < bytes.count {
            let b = bytes[i]
            switch b {
            case 0x1b: // ESC
                flushText()
                guard i + 1 < bytes.count else { pending = Array(bytes[i...]); bytes = []; i = 0; break }
                let next = bytes[i + 1]
                if next == UInt8(ascii: "[") {
                    // CSI: ESC [ params final(0x40–0x7e)
                    var j = i + 2
                    while j < bytes.count, !(0x40...0x7e).contains(bytes[j]) { j += 1 }
                    guard j < bytes.count else { pending = Array(bytes[i...]); return }
                    let params = String(decoding: bytes[(i + 2)..<j], as: UTF8.self)
                    handleCSI(params: params, final: bytes[j])
                    i = j + 1
                } else if next == UInt8(ascii: "]") {
                    // OSC: ESC ] ... BEL | ESC \
                    var j = i + 2
                    while j < bytes.count {
                        if bytes[j] == 0x07 { break }
                        if bytes[j] == 0x1b, j + 1 < bytes.count, bytes[j + 1] == UInt8(ascii: "\\") { j += 1; break }
                        j += 1
                    }
                    guard j < bytes.count else { pending = Array(bytes[i...]); return }
                    i = j + 1
                } else if Self.charsetDesignators.contains(next) {
                    // ESC ( B, ESC ) 0, … : intermediate + one designator byte (3 bytes total).
                    guard i + 2 < bytes.count else { pending = Array(bytes[i...]); return }
                    i += 3
                } else {
                    i += 2 // ESC + single char (e.g. ESC = / ESC >)
                }
            case 0x0a: flushText(); newline(); i += 1
            case 0x0d: flushText(); cursorColumn = 0; i += 1
            case 0x08: flushText(); cursorColumn = max(0, cursorColumn - 1); i += 1
            case 0x07: i += 1 // bell
            case 0x09: text.append(contentsOf: Array("    ".utf8)); i += 1
            case 0x00..<0x20 where b != 0x0a && b != 0x0d && b != 0x09: i += 1 // other control chars
            default:
                text.append(b); i += 1
            }
        }
        // Keep an incomplete trailing UTF-8 sequence for the next feed.
        if let cut = incompleteUTF8Suffix(text) {
            pending = Array(text[cut...]) + pending
            text.removeSubrange(cut...)
        }
        flushText()
    }

    // MARK: Private

    /// `ESC ( … ESC / …` select a character set and carry one more byte (`ESC ( B`).
    private static let charsetDesignators: Set<UInt8> = Set("()*+-./".utf8)

    private mutating func newline() {
        lines.append(Line())
        cursorColumn = 0
        let excess = lines.count - maxLines
        if excess > 0 {
            lines.removeFirst(excess)
            droppedLines += excess
        }
    }

    /// Writes text at the cursor, overwriting existing characters (for `\r` redraws).
    private mutating func append(_ s: String) {
        var line = lines[lines.count - 1]
        let existing = line.plain
        let count = existing.count
        if cursorColumn >= count {
            if cursorColumn > count { line.runs.append(Run(text: String(repeating: " ", count: cursorColumn - count), style: Style())) }
            line.runs.append(Run(text: s, style: style))
        } else {
            // Overwrite: rebuild runs from plain prefix + new text + remaining suffix.
            let chars = Array(existing)
            let prefix = String(chars[0..<cursorColumn])
            let end = min(chars.count, cursorColumn + s.count)
            let suffix = String(chars[end...])
            var runs: [Run] = []
            if !prefix.isEmpty { runs += sliced(line.runs, from: 0, to: cursorColumn) }
            runs.append(Run(text: s, style: style))
            if !suffix.isEmpty { runs += sliced(line.runs, from: end, to: chars.count) }
            line.runs = runs
        }
        cursorColumn += s.count
        lines[lines.count - 1] = line
    }

    private func sliced(_ runs: [Run], from: Int, to: Int) -> [Run] {
        var out: [Run] = []
        var pos = 0
        for run in runs {
            let len = run.text.count
            let start = max(from, pos), end = min(to, pos + len)
            if start < end {
                let chars = Array(run.text)
                out.append(Run(text: String(chars[(start - pos)..<(end - pos)]), style: run.style))
            }
            pos += len
            if pos >= to { break }
        }
        return out
    }

    private mutating func handleCSI(params: String, final: UInt8) {
        switch final {
        case UInt8(ascii: "m"):
            let codes = params.split(separator: ";").compactMap { Int($0) }
            applySGR(codes.isEmpty ? [0] : codes)
        case UInt8(ascii: "K"): // erase in line
            let mode = Int(params) ?? 0
            var line = lines[lines.count - 1]
            if mode == 0 { line.runs = sliced(line.runs, from: 0, to: cursorColumn) }
            else if mode == 2 { line.runs = []; cursorColumn = 0 }
            lines[lines.count - 1] = line
        case UInt8(ascii: "J"): // erase display: treat "2J"/"3J" as clear
            if (Int(params) ?? 0) >= 2 { clear() }
        case UInt8(ascii: "G"): // cursor horizontal absolute
            cursorColumn = max(0, (Int(params) ?? 1) - 1)
        case UInt8(ascii: "A"): // cursor up: progress UIs redraw previous lines; approximate by moving up
            let n = max(1, Int(params) ?? 1)
            if lines.count > n { lines.removeLast(n) }
            cursorColumn = 0
        default:
            break // ignore cursor moves, modes, etc.
        }
    }

    private mutating func applySGR(_ codes: [Int]) {
        var i = 0
        while i < codes.count {
            let c = codes[i]
            switch c {
            case 0: style = Style()
            case 1: style.bold = true
            case 2: style.dim = true
            case 3: style.italic = true
            case 4: style.underline = true
            case 22: style.bold = false; style.dim = false
            case 23: style.italic = false
            case 24: style.underline = false
            case 30...37: style.foreground = c - 30
            case 39: style.foreground = nil
            case 40...47: style.background = c - 40
            case 49: style.background = nil
            case 90...97: style.foreground = c - 90 + 8
            case 100...107: style.background = c - 100 + 8
            case 38, 48:
                // 38;5;n or 38;2;r;g;b
                if i + 1 < codes.count, codes[i + 1] == 5, i + 2 < codes.count {
                    if c == 38 { style.foreground = codes[i + 2] } else { style.background = codes[i + 2] }
                    i += 2
                } else if i + 1 < codes.count, codes[i + 1] == 2, i + 4 < codes.count {
                    let idx = Self.nearestPaletteIndex(r: codes[i + 2], g: codes[i + 3], b: codes[i + 4])
                    if c == 38 { style.foreground = idx } else { style.background = idx }
                    i += 4
                }
            default: break
            }
            i += 1
        }
    }

    private static func nearestPaletteIndex(r: Int, g: Int, b: Int) -> Int {
        // Map truecolor onto the 6x6x6 cube.
        func q(_ v: Int) -> Int { v < 48 ? 0 : v < 115 ? 1 : (v - 35) / 40 }
        return 16 + 36 * q(r) + 6 * q(g) + q(b)
    }

    private func incompleteUTF8Suffix(_ bytes: [UInt8]) -> Int? {
        guard let last = bytes.last else { return nil }
        if last < 0x80 { return nil }
        // Walk back to the start byte of the last sequence.
        var i = bytes.count - 1
        while i >= 0, bytes[i] & 0xC0 == 0x80 { i -= 1 }
        guard i >= 0 else { return nil }
        let lead = bytes[i]
        let needed = lead >= 0xF0 ? 4 : lead >= 0xE0 ? 3 : lead >= 0xC0 ? 2 : 1
        return bytes.count - i < needed ? i : nil
    }
}

extension ANSILineBuffer {
    /// Renders lines to an attributed string for display.
    @MainActor
    public func attributedString(font: NSFont, defaultColor: NSColor = .textColor) -> NSAttributedString {
        Self.attributedString(lines: lines[...], font: font, defaultColor: defaultColor)
    }

    /// Renders a slice of lines (joined with "\n", no trailing newline) — lets a view append
    /// only the lines that changed instead of re-rendering the whole scrollback.
    @MainActor
    public static func attributedString(lines: ArraySlice<Line>, font: NSFont, defaultColor: NSColor = .textColor) -> NSAttributedString {
        let result = NSMutableAttributedString()
        let bold = NSFontManager.shared.convert(font, toHaveTrait: .boldFontMask)
        let italic = NSFontManager.shared.convert(font, toHaveTrait: .italicFontMask)
        for (i, line) in lines.enumerated() {
            for run in line.runs {
                var attrs: [NSAttributedString.Key: Any] = [.font: run.style.bold ? bold : run.style.italic ? italic : font]
                var color = run.style.foreground.map(Self.color(index:)) ?? defaultColor
                if run.style.dim { color = color.withAlphaComponent(0.6) }
                attrs[.foregroundColor] = color
                if let bg = run.style.background { attrs[.backgroundColor] = Self.color(index: bg).withAlphaComponent(0.35) }
                if run.style.underline { attrs[.underlineStyle] = NSUnderlineStyle.single.rawValue }
                result.append(NSAttributedString(string: run.text, attributes: attrs))
            }
            if i < lines.count - 1 { result.append(NSAttributedString(string: "\n", attributes: [.font: font])) }
        }
        return result
    }

    public static func color(index: Int) -> NSColor {
        let base: [NSColor] = [
            .black, .systemRed, .systemGreen, .systemYellow, .systemBlue, .systemPurple, .systemTeal, .lightGray,
            .darkGray, .systemRed, .systemGreen, .systemYellow, .systemBlue, .systemPink, .systemCyan, .white,
        ]
        if index < 16 { return base[index] }
        if index < 232 {
            let v = index - 16
            let r = v / 36, g = (v / 6) % 6, b = v % 6
            func c(_ x: Int) -> CGFloat { x == 0 ? 0 : CGFloat(55 + x * 40) / 255 }
            return NSColor(red: c(r), green: c(g), blue: c(b), alpha: 1)
        }
        let gray = CGFloat(8 + (index - 232) * 10) / 255
        return NSColor(white: gray, alpha: 1)
    }
}
