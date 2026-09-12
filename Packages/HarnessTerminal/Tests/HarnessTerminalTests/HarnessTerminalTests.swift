import AppKit
import Foundation
import Testing
@testable import HarnessTerminal

@Suite struct ANSILineBufferTests {
    @Test func stripsSGRAndKeepsStyles() {
        var b = ANSILineBuffer()
        b.feed(Data("\u{1b}[31mred\u{1b}[0m plain\n".utf8))
        #expect(b.lines.count == 2)
        #expect(b.lines[0].plain == "red plain")
        #expect(b.lines[0].runs[0].style.foreground == 1)
        #expect(b.lines[0].runs[1].style.foreground == nil)
    }

    @Test func carriageReturnOverwritesLine() {
        var b = ANSILineBuffer()
        b.feed(Data("progress 10%\rprogress 20%\rdone\n".utf8))
        #expect(b.lines[0].plain == "doneress 20%")
        b.feed(Data("x\u{1b}[2Ky\n".utf8))
        #expect(b.lines[1].plain == "y")
    }

    @Test func splitEscapeSequencesAcrossFeeds() {
        var b = ANSILineBuffer()
        b.feed(Data("a\u{1b}[3".utf8))
        b.feed(Data("2mb\n".utf8))
        #expect(b.lines[0].plain == "ab")
        #expect(b.lines[0].runs.last?.style.foreground == 2)
    }

    @Test func oscSequencesAreDropped() {
        var b = ANSILineBuffer()
        b.feed(Data("\u{1b}]0;title\u{07}hello\n".utf8))
        #expect(b.lines[0].plain == "hello")
    }

    @Test func tailReturnsLastLines() {
        var b = ANSILineBuffer()
        b.feed(Data("1\n2\n3\n4".utf8))
        #expect(b.tail(2) == "3\n4")
    }

    /// Contract the terminal drawer relies on: a mirror that drops `droppedLines` from its head
    /// and re-renders from its previously-last line stays equal to the buffer, through front
    /// trimming, `\r` overwrites, `ESC[K`, and (via full rebuild) `ESC[A`.
    @Test @MainActor func droppedLinesLetsAMirrorStayIncremental() {
        var b = ANSILineBuffer()
        b.maxLines = 20
        let font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        let storage = NSTextStorage()
        var rendered: [ANSILineBuffer.Line] = []
        var lastStart = 0, renderedDropped = 0
        var incremental = 0, full = 0

        let chunks = ["one\n", "two\nthr", "ee\n", "progress 1%\rprogress 50%", "\rdone\n", "x\u{1b}[2Ky\n"]
            + (0..<40).map { "line \($0) \u{1b}[31mred\u{1b}[0m\n" } + ["up\u{1b}[2Aafter\n", "tail"]
        for chunk in chunks {
            b.feed(Data(chunk.utf8))
            let lines = b.lines
            let keep = rendered.count - 1
            let dropped = b.droppedLines - renderedDropped
            if keep >= 0, dropped >= 0, dropped <= keep, lines.count > keep - dropped,
               rendered[dropped..<keep] == lines[..<(keep - dropped)] {
                if dropped > 0 {
                    let head = rendered[..<dropped].reduce(0) { $0 + $1.plain.utf16.count + 1 }
                    storage.deleteCharacters(in: NSRange(location: 0, length: head))
                    lastStart -= head
                }
                let tail = ANSILineBuffer.attributedString(lines: lines[(keep - dropped)...], font: font)
                storage.replaceCharacters(in: NSRange(location: lastStart, length: storage.length - lastStart), with: tail)
                incremental += 1
            } else {
                storage.setAttributedString(b.attributedString(font: font))
                full += 1
            }
            rendered = lines
            renderedDropped = b.droppedLines
            lastStart = storage.length - (lines.last?.plain.utf16.count ?? 0)
            #expect(storage.string == b.plainText, "mirror diverged after \(chunk.debugDescription)")
        }
        #expect(b.lines.count == 19) // capped at 20, then ESC[2A removed two and "after" added one
        #expect(b.droppedLines > 0)
        #expect(full == 2, "only the first render and the ESC[A shrink should rebuild, got \(full)")
        #expect(incremental == chunks.count - full)
    }

    @Test func charsetDesignatorsConsumeThreeBytes() {
        var b = ANSILineBuffer()
        b.feed(Data("\u{1b}(Bhello\u{1b})0 world\n".utf8))
        #expect(b.lines[0].plain == "hello world")
        // Two-byte escapes are still two bytes.
        b.feed(Data("\u{1b}=x\u{1b}>y\n".utf8))
        #expect(b.lines[1].plain == "xy")
        // Split across feeds: the designator byte arrives later.
        b.feed(Data("a\u{1b}(".utf8))
        b.feed(Data("Bb\n".utf8))
        #expect(b.lines[2].plain == "ab")
    }
}

@Suite struct PTYProcessTests {
    @Test func runsCommandAndCapturesOutput() async throws {
        let p = PTYProcess()
        try p.start(argv: ["/bin/sh", "-c", "echo hi; exit 3"], cwd: URL(fileURLWithPath: "/tmp"),
                    environment: ["PATH": "/usr/bin:/bin", "TERM": "dumb"])
        var collected = Data()
        for await chunk in p.output { collected.append(chunk) }
        let code = await p.waitForExit()
        #expect(String(decoding: collected, as: UTF8.self).contains("hi"))
        #expect(code == 3)
    }

    @Test @MainActor func commandRunnerCapturesStrippedOutputAndTimesOut() async {
        let manager = TerminalManager(cwd: URL(fileURLWithPath: "/tmp"))
        let runner = CommandRunner(terminals: manager)
        let ok = await runner.run("printf '\\033[32mgreen\\033[0m\\n'; exit 0", timeout: 10)
        #expect(ok.exitCode == 0)
        #expect(ok.output.contains("green"))
        #expect(!ok.output.contains("\u{1b}"))

        let slow = await runner.run("sleep 5", timeout: 0.5)
        #expect(slow.timedOut)
        #expect(!slow.cancelled)
        #expect(manager.sessions.count == 2)
    }

    /// The shell's background child holds the pty slave open; killing only the shell would
    /// leave `run` hanging past its timeout and the child running.
    @Test @MainActor func timeoutKillsWholeProcessGroup() async throws {
        let manager = TerminalManager(cwd: URL(fileURLWithPath: "/tmp"))
        let runner = CommandRunner(terminals: manager)
        let started = Date()
        // `$!` is single-quoted for the login shell, so `sh` expands it to the sleeper's pid.
        let r = await runner.run("sh -c 'sleep 30 & echo child=$!; wait'", timeout: 1)
        let elapsed = Date().timeIntervalSince(started)
        #expect(r.timedOut)
        #expect(elapsed < 3, "run returned after \(elapsed)s")

        let childPID = try #require(Self.pid(after: "child=", in: r.output))
        #expect(await Self.waitUntilGone(childPID, within: 2), "sleep 30 (pid \(childPID)) survived the timeout")
    }

    @Test @MainActor func cancellingTheAwaitingTaskTerminatesTheCommand() async throws {
        let manager = TerminalManager(cwd: URL(fileURLWithPath: "/tmp"))
        let runner = CommandRunner(terminals: manager)
        let started = Date()
        let task = Task { @MainActor in
            await runner.run("sh -c 'sleep 30 & echo child=$!; wait'", timeout: 60)
        }
        // Let the shell start and print the child's pid before cancelling.
        // (The echoed command line also contains "child=", so require a digit after it.)
        for _ in 0..<40 {
            let text = manager.sessions.first?.buffer.plainText ?? ""
            if text.range(of: "child=[0-9]", options: .regularExpression) != nil { break }
            try await Task.sleep(for: .milliseconds(50))
        }
        task.cancel()
        let r = await task.value
        let elapsed = Date().timeIntervalSince(started)
        #expect(r.cancelled)
        #expect(!r.timedOut)
        #expect(elapsed < 4, "cancelled run returned after \(elapsed)s")
        #expect(manager.sessions.first?.isRunning == false)

        let childPID = try #require(Self.pid(after: "child=", in: r.output))
        #expect(await Self.waitUntilGone(childPID, within: 2), "sleep 30 (pid \(childPID)) survived cancellation")
    }

    // MARK: Helpers

    private static func pid(after marker: String, in text: String) -> pid_t? {
        guard let range = text.range(of: marker) else { return nil }
        let digits = text[range.upperBound...].prefix { $0.isNumber }
        return pid_t(digits)
    }

    /// True once `pid` no longer exists (a zombie still answers `kill(pid, 0)`, so poll briefly
    /// for launchd to reap the orphan).
    private static func waitUntilGone(_ pid: pid_t, within seconds: TimeInterval) async -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if kill(pid, 0) != 0 && errno == ESRCH { return true }
            try? await Task.sleep(for: .milliseconds(50))
        }
        return kill(pid, 0) != 0 && errno == ESRCH
    }
}
