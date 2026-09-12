import AppKit
import HarnessTerminal
import SwiftUI

/// PRD §15 — hidden until a command runs. Agent tabs are badged and read-only; user tabs are shells.
struct TerminalDrawerView: View {
    @Bindable var terminals: TerminalManager
    let onOpenPath: (String, Int) -> Void
    @Binding var collapsed: Bool
    @State private var input = ""

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                Button { withAnimation(.easeOut(duration: 0.15)) { collapsed.toggle() } } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "chevron.down").font(.caption2).rotationEffect(.degrees(collapsed ? -90 : 0))
                        Text("Terminal").font(.caption).fontWeight(.semibold)
                    }
                }
                .buttonStyle(.plain).padding(.horizontal, 10)

                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 2) {
                        ForEach(terminals.sessions) { s in
                            TerminalTab(session: s, isSelected: s.id == terminals.selected?.id,
                                        select: { terminals.selectedID = s.id }, close: { terminals.close(s.id) })
                        }
                    }
                }
                Spacer(minLength: 8)
                Button { terminals.openShell() } label: { Image(systemName: "plus") }
                    .buttonStyle(.plain).help("New shell (⌃`)").padding(.trailing, 6)
                Button { terminals.closeAll() } label: { Image(systemName: "xmark") }
                    .buttonStyle(.plain).help("Close terminal").padding(.trailing, 10)
            }
            .frame(height: 28)
            .background(.bar)

            if !collapsed, let session = terminals.selected {
                Divider()
                TerminalOutputView(session: session, onOpenPath: onOpenPath)
                    .frame(maxHeight: .infinity)
                if session.origin == .user && session.isRunning {
                    Divider()
                    HStack(spacing: 6) {
                        Text("❯").font(.system(.body, design: .monospaced)).foregroundStyle(.secondary)
                        TextField("Type a command…", text: $input)
                            .textFieldStyle(.plain)
                            .font(.system(.body, design: .monospaced))
                            .onSubmit {
                                session.send(input + "\n")
                                input = ""
                            }
                    }
                    .padding(.horizontal, 10).padding(.vertical, 5)
                }
            }
        }
    }
}

private struct TerminalTab: View {
    let session: TerminalSession
    let isSelected: Bool
    let select: () -> Void
    let close: () -> Void

    var body: some View {
        HStack(spacing: 5) {
            if session.origin == .agent {
                Image(systemName: "bolt.fill").font(.system(size: 8)).foregroundStyle(Color.accentColor)
                    .help("Run by the agent")
            }
            Text(session.title).font(.caption).lineLimit(1)
            if session.isRunning {
                ProgressView().controlSize(.mini)
            } else if case .exited(let code) = session.state, code != 0 {
                Text("\(code)").font(.caption2).foregroundStyle(.red)
            }
            Button(action: close) { Image(systemName: "xmark").font(.system(size: 8)) }.buttonStyle(.plain).foregroundStyle(.secondary)
        }
        .padding(.horizontal, 8).padding(.vertical, 3)
        .background(RoundedRectangle(cornerRadius: 5).fill(isSelected ? Color(nsColor: .textBackgroundColor) : .clear))
        .contentShape(Rectangle())
        .onTapGesture(perform: select)
    }
}

/// Scrollback rendered with an `NSTextView`. The text view is updated *outside* the SwiftUI
/// layout pass via `withObservationTracking` — reading the observable `session.version` during
/// `updateNSView` created an AttributeGraph cycle as the pump mutated it mid-layout.
private struct TerminalOutputView: NSViewRepresentable {
    let session: TerminalSession
    let onOpenPath: (String, Int) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onOpenPath: onOpenPath) }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSTextView.scrollableTextView()
        let tv = scroll.documentView as! NSTextView
        tv.isEditable = false
        tv.isRichText = true
        tv.drawsBackground = true
        tv.backgroundColor = .textBackgroundColor
        tv.textContainerInset = NSSize(width: 8, height: 6)
        tv.font = Coordinator.font
        tv.delegate = context.coordinator
        tv.isAutomaticLinkDetectionEnabled = false
        context.coordinator.bind(session: session, textView: tv)
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        // Rebind only when the selected session changes; never read observable state here.
        guard let tv = scroll.documentView as? NSTextView else { return }
        if context.coordinator.sessionID != session.id {
            context.coordinator.bind(session: session, textView: tv)
        }
    }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        static var font: NSFont { .monospacedSystemFont(ofSize: 12, weight: .regular) }
        private static let pathRegex = try! NSRegularExpression(pattern: #"(?<![\w/])((?:[\w.-]+/)*[\w.-]+\.[A-Za-z]{1,6}):(\d+)(?::\d+)?"#)
        let onOpenPath: (String, Int) -> Void
        private(set) var sessionID: UUID?
        private weak var textView: NSTextView?
        private weak var session: TerminalSession?
        /// The lines currently in the text view, and the UTF-16 offset where the last of
        /// them starts. Only the last line can change in place (`\r`, backspace, `ESC[K`),
        /// so a chunk normally means "re-render from there" rather than the whole scrollback.
        private var renderedLines: [ANSILineBuffer.Line] = []
        private var renderedLastLineStart = 0
        private var renderedDroppedLines = 0

        init(onOpenPath: @escaping (String, Int) -> Void) { self.onOpenPath = onOpenPath }

        func bind(session: TerminalSession, textView: NSTextView) {
            self.session = session
            self.textView = textView
            self.sessionID = session.id
            renderedLines = []
            renderedLastLineStart = 0
            renderedDroppedLines = 0
            render()
        }

        /// Renders current scrollback, then re-arms observation of `version` for the next change.
        private func render() {
            guard let session, session.id == sessionID, let tv = textView else { return }
            _ = withObservationTracking {
                session.version   // establish the dependency
            } onChange: {
                Task { @MainActor [weak self] in self?.render() }
            }
            guard let storage = tv.textStorage else { return }
            let buffer = session.buffer
            let lines = buffer.lines
            let keep = renderedLines.count - 1                          // rendered lines before the last one
            let dropped = buffer.droppedLines - renderedDroppedLines    // trimmed from the front since last render
            // Incremental path: apart from `dropped` lines gone from the head, every line before
            // the previously-last one is unchanged. Verifying that prefix is cheap — unchanged
            // `Line`s share storage with the copy we kept, so `==` short-circuits on identity.
            // Anything else (`ESC[A` shrinking the buffer, `2J` clearing it) falls through to a
            // full rebuild, which is what every render did before.
            if keep >= 0, dropped >= 0, dropped <= keep, lines.count > keep - dropped,
               storage.length >= renderedLastLineStart,
               renderedLines[dropped..<keep] == lines[..<(keep - dropped)] {
                if dropped > 0 {
                    let head = renderedLines[..<dropped].reduce(0) { $0 + $1.plain.utf16.count + 1 } // +1 per "\n"
                    storage.deleteCharacters(in: NSRange(location: 0, length: head))
                    renderedLastLineStart -= head
                }
                let tail = NSMutableAttributedString(attributedString:
                    ANSILineBuffer.attributedString(lines: lines[(keep - dropped)...], font: Coordinator.font))
                Self.linkify(tail)  // path links never span a newline, so linking the tail alone is exact
                storage.replaceCharacters(in: NSRange(location: renderedLastLineStart,
                                                      length: storage.length - renderedLastLineStart), with: tail)
            } else {
                let text = NSMutableAttributedString(attributedString: buffer.attributedString(font: Coordinator.font))
                Self.linkify(text)
                storage.setAttributedString(text)
            }
            renderedLines = lines
            renderedDroppedLines = buffer.droppedLines
            renderedLastLineStart = storage.length - (lines.last?.plain.utf16.count ?? 0)
            tv.scrollToEndOfDocument(nil)
        }

        static func linkify(_ text: NSMutableAttributedString) {
            let s = text.string as NSString
            for m in pathRegex.matches(in: text.string, range: NSRange(location: 0, length: s.length)) {
                let path = s.substring(with: m.range(at: 1))
                let line = s.substring(with: m.range(at: 2))
                text.addAttributes([.link: "harness-open://\(path)#\(line)", .underlineStyle: NSUnderlineStyle.single.rawValue,
                                    .cursor: NSCursor.pointingHand], range: m.range)
            }
        }

        func textView(_ textView: NSTextView, clickedOnLink link: Any, at charIndex: Int) -> Bool {
            guard let s = link as? String, s.hasPrefix("harness-open://") else { return false }
            let body = s.dropFirst("harness-open://".count)
            let parts = body.split(separator: "#")
            guard parts.count == 2, let line = Int(parts[1]) else { return false }
            onOpenPath(String(parts[0]), line)
            return true
        }
    }
}
