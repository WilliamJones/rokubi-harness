import CoreServices
import Foundation

/// A filesystem change reported by `FileWatcher`.
public struct FileEvent: Sendable, Hashable {
    public let url: URL
    public let isDirectory: Bool
    public let flags: FSEventStreamEventFlags
}

/// FSEvents wrapper that delivers coalesced change batches as an `AsyncStream`.
public final class FileWatcher: @unchecked Sendable {
    public let root: URL
    public let events: AsyncStream<[FileEvent]>

    private let continuation: AsyncStream<[FileEvent]>.Continuation
    private let queue = DispatchQueue(label: "com.rokubi.harness.filewatcher")
    private let latency: TimeInterval
    private var stream: FSEventStreamRef?
    private let lock = NSLock()

    public init(root: URL, latency: TimeInterval = 0.25) {
        self.root = root
        self.latency = latency
        (events, continuation) = AsyncStream.makeStream(bufferingPolicy: .bufferingNewest(64))
    }

    deinit { stop() }

    public func start() {
        lock.lock(); defer { lock.unlock() }
        guard stream == nil else { return }

        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil, release: nil, copyDescription: nil
        )
        let flags = FSEventStreamCreateFlags(
            kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagNoDefer
        )
        guard let created = FSEventStreamCreate(
            nil, FileWatcher.callback, &context, [root.path] as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow), latency, flags
        ) else { return }

        FSEventStreamSetDispatchQueue(created, queue)
        FSEventStreamStart(created)
        stream = created
    }

    public func stop() {
        lock.lock(); defer { lock.unlock() }
        guard let s = stream else { return }
        FSEventStreamStop(s)
        FSEventStreamInvalidate(s)
        FSEventStreamRelease(s)
        stream = nil
        continuation.finish()
    }

    private static let callback: FSEventStreamCallback = { _, info, count, paths, flags, _ in
        guard let info else { return }
        let watcher = Unmanaged<FileWatcher>.fromOpaque(info).takeUnretainedValue()
        guard let pathArray = unsafeBitCast(paths, to: NSArray.self) as? [String] else { return }
        var batch: [FileEvent] = []
        batch.reserveCapacity(count)
        for i in 0..<count {
            let f = flags[i]
            let isDir = f & FSEventStreamEventFlags(kFSEventStreamEventFlagItemIsDir) != 0
            batch.append(FileEvent(url: URL(fileURLWithPath: pathArray[i]), isDirectory: isDir, flags: f))
        }
        watcher.continuation.yield(batch)
    }
}
