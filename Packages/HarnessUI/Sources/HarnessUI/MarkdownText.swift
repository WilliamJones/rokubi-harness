import SwiftUI

/// Lightweight markdown: fenced code blocks get a monospaced box, everything else goes
/// through `AttributedString(markdown:)` paragraph by paragraph.
struct MarkdownText: View {
    let text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                switch block {
                case .code(let lang, let code):
                    CodeBlock(language: lang, code: code)
                case .paragraph(let p):
                    Text(attributed(p))
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private enum Block { case code(String?, String), paragraph(String) }

    private var blocks: [Block] {
        var result: [Block] = []
        var paragraph: [String] = []
        var code: [String]? = nil
        var lang: String? = nil

        func flushParagraph() {
            let joined = paragraph.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            if !joined.isEmpty { result.append(.paragraph(joined)) }
            paragraph.removeAll()
        }

        for line in text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init) {
            if line.hasPrefix("```") {
                if let c = code {
                    result.append(.code(lang, c.joined(separator: "\n")))
                    code = nil; lang = nil
                } else {
                    flushParagraph()
                    code = []
                    let l = line.dropFirst(3).trimmingCharacters(in: .whitespaces)
                    lang = l.isEmpty ? nil : l
                }
                continue
            }
            if code != nil { code!.append(line); continue }
            if line.trimmingCharacters(in: .whitespaces).isEmpty { flushParagraph() } else { paragraph.append(line) }
        }
        if let c = code { result.append(.code(lang, c.joined(separator: "\n"))) }
        flushParagraph()
        return result
    }

    private func attributed(_ s: String) -> AttributedString {
        // Headings and list bullets aren't handled by the inline parser; give them a light touch.
        var source = s
        var isHeading = false
        if let match = source.firstMatch(of: /^#{1,6}\s+/) {
            source.removeSubrange(match.range)
            isHeading = true
        }
        source = source.replacingOccurrences(of: "\n- ", with: "\n• ")
        if source.hasPrefix("- ") { source = "• " + source.dropFirst(2) }
        var attr = (try? AttributedString(markdown: source, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
            ?? AttributedString(source)
        if isHeading { attr.font = .headline }
        return attr
    }
}

struct CodeBlock: View {
    let language: String?
    let code: String

    var body: some View {
        ScrollView(.horizontal) {
            Text(code)
                .font(.system(.callout, design: .monospaced))
                .textSelection(.enabled)
                .padding(10)
        }
        .background(Color(nsColor: .textBackgroundColor))
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(.quaternary))
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .overlay(alignment: .topTrailing) {
            if let language {
                Text(language).font(.caption2).foregroundStyle(.tertiary).padding(6)
            }
        }
    }
}
