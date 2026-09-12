import Foundation
import HarnessCore

/// Executes agent commands through the terminal manager so the user sees them in the
/// drawer, while capturing ANSI-stripped output for the model.
@MainActor
public final class CommandRunner {
    public struct Result: Sendable {
        public let exitCode: Int32
        public let output: String
        /// The deadline fired and the command was killed.
        public let timedOut: Bool
        /// The task awaiting `run` was cancelled and the command was killed.
        public let cancelled: Bool
        public let duration: TimeInterval
    }

    public let terminals: TerminalManager
    public var maxOutputLines = 400
    /// Seconds between SIGTERM and SIGKILL when a command is stopped by timeout or cancellation.
    public var killGrace: TimeInterval = 1

    public init(terminals: TerminalManager) {
        self.terminals = terminals
    }

    /// Runs `command` in a fresh agent tab and waits for it. Returns when the command exits,
    /// when `timeout` elapses (the process group is SIGTERMed, then SIGKILLed after
    /// `killGrace`), or when the calling task is cancelled (same signalling, and the result
    /// is marked `cancelled`).
    public func run(_ command: String, timeout: TimeInterval) async -> Result {
        let started = Date()
        let session = terminals.runForAgent(command)
        let state = RunState()
        let grace = killGrace

        // Deadline: kill the process group if it outlives `timeout`.
        let deadline = Task { @MainActor in
            try? await Task.sleep(for: .seconds(timeout))
            guard !Task.isCancelled, !state.stopped else { return }
            state.timedOut = true
            session.terminate(grace: grace)
        }
        let code = await withTaskCancellationHandler {
            await session.waitForExit()
        } onCancel: {
            // Synchronous and nonisolated: hop to the main actor to touch the session. The
            // awaiting `run` is suspended, so this runs promptly and the kill unblocks it.
            Task { @MainActor in
                guard !state.stopped else { return }
                state.cancelled = true
                session.terminate(grace: grace)
            }
        }
        state.stopped = true
        deadline.cancel()
        // Give the pump a moment to drain the last chunk (skipped if we're cancelled).
        try? await Task.sleep(for: .milliseconds(80))

        let lines = session.buffer.lines.map(\.plain)
        var body = lines.dropFirst().joined(separator: "\n") // drop the echoed "$ command"
        if lines.count - 1 > maxOutputLines {
            let kept = lines.suffix(maxOutputLines).joined(separator: "\n")
            body = "… (\(lines.count - 1 - maxOutputLines) earlier lines omitted)\n" + kept
        }
        return Result(exitCode: code, output: body.trimmingCharacters(in: .whitespacesAndNewlines),
                      timedOut: state.timedOut, cancelled: state.cancelled,
                      duration: Date().timeIntervalSince(started))
    }

    @MainActor
    private final class RunState {
        var timedOut = false
        var cancelled = false
        /// Set once `waitForExit` returns so a late deadline/cancel hop doesn't re-signal.
        var stopped = false
    }
}
