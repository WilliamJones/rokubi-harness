import Darwin
import Foundation

/// A child process attached to a pseudo-terminal. Spawned with `posix_spawn` (no `fork`
/// in a Swift process) — the child opens the pty slave itself as session leader, which
/// makes it the controlling terminal so shells and tools behave normally.
///
/// Thread-safety: `start` runs on the caller's thread, the read source fires on `queue`,
/// and `terminate`/`write`/`resize` may be called from anywhere. Every piece of mutable
/// state (`master`, `reader`, `pid`, `exitStatus`, `exitContinuations`) is only touched
/// under `lock`, which is what justifies `@unchecked Sendable`.
public final class PTYProcess: @unchecked Sendable {
    public struct Size: Sendable, Equatable {
        public var rows: UInt16
        public var cols: UInt16
        public init(rows: UInt16 = 40, cols: UInt16 = 120) { self.rows = rows; self.cols = cols }
    }

    public let output: AsyncStream<Data>
    /// The shell's pid. Because the child is spawned with `POSIX_SPAWN_SETSID`, this is also
    /// its process-group id, so signals go to `-pid` and reach every descendant.
    public var pid: pid_t { lock.withLock { _pid } }

    private let continuation: AsyncStream<Data>.Continuation
    private let queue = DispatchQueue(label: "com.rokubi.harness.pty", qos: .userInitiated)
    private let lock = NSLock()
    // All of the following are guarded by `lock`.
    private var _pid: pid_t = 0
    private var master: Int32 = -1
    private var reader: (any DispatchSourceRead)?
    private var exitContinuations: [CheckedContinuation<Int32, Never>] = []
    private var exitStatus: Int32?

    public init() {
        (output, continuation) = AsyncStream.makeStream(bufferingPolicy: .unbounded)
    }

    /// Launches `argv[0]` with `argv` in `cwd`. `environment` replaces the parent environment.
    public func start(argv: [String], cwd: URL, environment: [String: String], size: Size = Size()) throws {
        var m: Int32 = -1, s: Int32 = -1
        var win = winsize(ws_row: size.rows, ws_col: size.cols, ws_xpixel: 0, ws_ypixel: 0)
        guard openpty(&m, &s, nil, nil, &win) == 0 else { throw PTYError.openpty(errno) }
        guard let slavePath = ptsname(m).map({ String(cString: $0) }) else {
            let e = errno
            close(s); close(m)
            throw PTYError.openpty(e)
        }

        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        // Opening the slave as the new session leader makes it the controlling tty.
        posix_spawn_file_actions_addopen(&actions, 0, slavePath, O_RDWR, 0)
        posix_spawn_file_actions_adddup2(&actions, 0, 1)
        posix_spawn_file_actions_adddup2(&actions, 0, 2)
        posix_spawn_file_actions_addchdir_np(&actions, cwd.path)

        var attr: posix_spawnattr_t?
        posix_spawnattr_init(&attr)
        defer { posix_spawnattr_destroy(&attr) }
        posix_spawnattr_setflags(&attr, Int16(POSIX_SPAWN_SETSID | POSIX_SPAWN_CLOEXEC_DEFAULT))

        let cArgs = argv.map { strdup($0) } + [nil]
        let cEnv = environment.map { strdup("\($0.key)=\($0.value)") } + [nil]
        defer { cArgs.forEach { free($0) }; cEnv.forEach { free($0) } }

        var child: pid_t = 0
        let rc = posix_spawnp(&child, argv[0], &actions, &attr, cArgs, cEnv)
        close(s)
        guard rc == 0 else { close(m); throw PTYError.spawn(rc) }

        let source = DispatchSource.makeReadSource(fileDescriptor: m, queue: queue)
        source.setEventHandler { [weak self] in
            guard let self else { return }
            var buffer = [UInt8](repeating: 0, count: 64 * 1024)
            let n = read(m, &buffer, buffer.count)
            if n > 0 {
                self.continuation.yield(Data(buffer[0..<n]))
            } else if n == 0 || (n < 0 && errno != EAGAIN && errno != EINTR) {
                self.finish()
            }
        }
        source.setCancelHandler { close(m) }
        lock.withLock {
            master = m
            _pid = child
            reader = source
        }
        source.resume()
    }

    public func write(_ data: Data) {
        let fd = lock.withLock { master }
        guard fd >= 0 else { return }
        data.withUnsafeBytes { raw in
            var offset = 0
            while offset < raw.count {
                let n = Darwin.write(fd, raw.baseAddress!.advanced(by: offset), raw.count - offset)
                if n <= 0 { break }
                offset += n
            }
        }
    }

    public func write(_ text: String) { write(Data(text.utf8)) }

    public func resize(_ size: Size) {
        let fd = lock.withLock { master }
        guard fd >= 0 else { return }
        var win = winsize(ws_row: size.rows, ws_col: size.cols, ws_xpixel: 0, ws_ypixel: 0)
        _ = ioctl(fd, TIOCSWINSZ, &win)
    }

    /// True once the shell has been reaped and its exit code recorded.
    public var hasExited: Bool { lock.withLock { exitStatus != nil } }

    /// SIGTERM to the whole process group, then SIGKILL after `grace` seconds if the group is
    /// still alive. Signalling only the shell would leave `zsh -c "npm test"`'s children
    /// running with the pty slave open, so the master never EOFs and nobody ever reaps.
    public func terminate(grace: TimeInterval = 2) {
        let p = pid
        guard p > 0 else { return }
        Self.signalGroup(p, SIGTERM)
        scheduleKill(p, after: grace)
    }

    /// Waits for the process to exit and returns its exit code (128+signal if signalled).
    public func waitForExit() async -> Int32 {
        await withCheckedContinuation { c in
            // Synchronous closure: safe to lock here.
            lock.lock()
            if let status = exitStatus {
                lock.unlock()
                c.resume(returning: status)
            } else {
                exitContinuations.append(c)
                lock.unlock()
            }
        }
    }

    // MARK: Private

    /// Sends `sig` to the process group led by `pid`, falling back to the pid alone.
    private static func signalGroup(_ pid: pid_t, _ sig: Int32) {
        if kill(-pid, sig) != 0 { kill(pid, sig) }
    }

    /// SIGKILL the group after `grace` seconds unless the shell has been reaped by then.
    /// Uses a global queue: the reader queue may be blocked in `waitpid` inside `finish()`.
    private func scheduleKill(_ p: pid_t, after grace: TimeInterval) {
        DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + grace) { [weak self] in
            guard let self, !self.hasExited else { return }
            Self.signalGroup(p, SIGKILL)
        }
    }

    /// Runs on `queue` once the master hits EOF (every holder of the slave is gone).
    private func finish() {
        let (source, p) = lock.withLock { () -> ((any DispatchSourceRead)?, pid_t) in
            let s = reader
            reader = nil
            master = -1
            return (s, _pid)
        }
        source?.cancel()
        var status: Int32 = 0
        var code: Int32 = -1
        if p > 0 {
            // EOF usually means the shell is gone, but a child may have closed its stdio and
            // kept running. Poll first; if the shell is still alive, ask the whole group to
            // stop (with a SIGKILL backstop) before blocking on waitpid.
            var reaped = waitpid(p, &status, WNOHANG)
            if reaped == 0 {
                Self.signalGroup(p, SIGTERM)
                scheduleKill(p, after: 2)
                repeat { reaped = waitpid(p, &status, 0) } while reaped < 0 && errno == EINTR
            }
            if reaped == p {
                if (status & 0x7f) == 0 { code = (status >> 8) & 0xff }            // WIFEXITED → WEXITSTATUS
                else { code = 128 + (status & 0x7f) }                                // signalled
            }
        }
        let waiters = lock.withLock { () -> [CheckedContinuation<Int32, Never>] in
            exitStatus = code
            let w = exitContinuations
            exitContinuations.removeAll()
            return w
        }
        continuation.finish()
        for w in waiters { w.resume(returning: code) }
    }
}

public enum PTYError: LocalizedError {
    case openpty(Int32)
    case spawn(Int32)
    public var errorDescription: String? {
        switch self {
        case .openpty(let e): "Could not allocate a terminal (errno \(e))"
        case .spawn(let e): "Could not start the shell (\(String(cString: strerror(e))))"
        }
    }
}

/// Environment for child shells: the user's login environment plus terminal basics.
public enum ShellEnvironment {
    public static var loginShell: String {
        ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
    }

    public static func make(extra: [String: String] = [:]) -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        env["TERM"] = "xterm-256color"
        env["COLORTERM"] = "truecolor"
        env["LANG"] = env["LANG"] ?? "en_US.UTF-8"
        env["ROKUBI_HARNESS"] = "1"
        // Keep tools from paging or prompting.
        env["PAGER"] = "cat"
        env["GIT_PAGER"] = "cat"
        env["CI"] = env["CI"] ?? "1"
        for (k, v) in extra { env[k] = v }
        return env
    }
}
