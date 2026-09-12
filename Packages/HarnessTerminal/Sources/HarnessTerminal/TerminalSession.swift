import Foundation
import Observation

/// One terminal tab: a PTY-backed shell or a single agent command, with its scrollback.
@MainActor
@Observable
public final class TerminalSession: Identifiable {
    public enum Origin: Sendable { case user, agent }
    public enum State: Sendable, Equatable { case running, exited(Int32), failed(String) }

    public let id = UUID()
    public let origin: Origin
    public let title: String
    public let cwd: URL
    public private(set) var buffer = ANSILineBuffer()
    public private(set) var state: State = .running
    public private(set) var startedAt = Date()
    /// Bumped on every output batch so views can scroll.
    public private(set) var version = 0

    @ObservationIgnored private var process: PTYProcess?
    @ObservationIgnored private var pump: Task<Void, Never>?

    public init(origin: Origin, title: String, cwd: URL) {
        self.origin = origin
        self.title = title
        self.cwd = cwd
    }

    /// Interactive login shell.
    public func startShell() {
        start(argv: [ShellEnvironment.loginShell, "-l"], environment: ShellEnvironment.make())
    }

    /// One command through the login shell (so PATH/nvm/etc. match the user's terminal).
    public func start(command: String, extraEnvironment: [String: String] = [:]) {
        buffer.feed(Data("$ \(command)\n".utf8))
        start(argv: [ShellEnvironment.loginShell, "-l", "-c", command], environment: ShellEnvironment.make(extra: extraEnvironment))
    }

    private func start(argv: [String], environment: [String: String]) {
        let p = PTYProcess()
        process = p
        do {
            try p.start(argv: argv, cwd: cwd, environment: environment)
        } catch {
            state = .failed(error.localizedDescription)
            buffer.feed(Data("\(error.localizedDescription)\n".utf8))
            return
        }
        pump = Task { [weak self] in
            for await chunk in p.output {
                guard let self else { return }
                self.buffer.feed(chunk)
                self.version += 1
            }
            let code = await p.waitForExit()
            self?.state = .exited(code)
            self?.version += 1
        }
    }

    public func send(_ text: String) { process?.write(text) }
    public func resize(rows: UInt16, cols: UInt16) { process?.resize(.init(rows: rows, cols: cols)) }

    /// SIGTERM the command's whole process group, SIGKILL after `grace` seconds if needed.
    public func terminate(grace: TimeInterval = 2) {
        process?.terminate(grace: grace)
    }

    public var isRunning: Bool { state == .running }

    /// Waits for exit, returning the exit code (or -1 on failure to start).
    public func waitForExit() async -> Int32 {
        guard let p = process else { return -1 }
        return await p.waitForExit()
    }
}

/// All terminal sessions for a project window. The drawer appears once this is non-empty.
@MainActor
@Observable
public final class TerminalManager {
    public private(set) var sessions: [TerminalSession] = []
    public var selectedID: UUID?
    public let cwd: URL

    public init(cwd: URL) { self.cwd = cwd }

    public var selected: TerminalSession? {
        sessions.first { $0.id == selectedID } ?? sessions.last
    }

    @discardableResult
    public func openShell() -> TerminalSession {
        let s = TerminalSession(origin: .user, title: "Terminal \(sessions.filter { $0.origin == .user }.count + 1)", cwd: cwd)
        sessions.append(s)
        selectedID = s.id
        s.startShell()
        return s
    }

    /// Runs one command for the agent in its own tab and returns the session.
    @discardableResult
    public func runForAgent(_ command: String, extraEnvironment: [String: String] = [:]) -> TerminalSession {
        let s = TerminalSession(origin: .agent, title: String(command.prefix(28)), cwd: cwd)
        sessions.append(s)
        selectedID = s.id
        s.start(command: command, extraEnvironment: extraEnvironment)
        return s
    }

    public func close(_ id: UUID) {
        guard let i = sessions.firstIndex(where: { $0.id == id }) else { return }
        sessions[i].terminate()
        sessions.remove(at: i)
        if selectedID == id { selectedID = sessions.last?.id }
    }

    public func closeAll() {
        sessions.forEach { $0.terminate() }
        sessions.removeAll()
        selectedID = nil
    }

    /// Recent output of the selected session — for `@terminal`.
    public var recentOutput: String? {
        selected?.buffer.tail(120)
    }
}
