import AppKit
import UniformTypeIdentifiers
import WebKit

/// Debug aid: `RokubiHarness --project <dir> --snapshot <png> [--snapshot-delay=4]` writes an
/// image of the workspace window shortly after launch, for scripted verification.
///
/// No Screen Recording permission is needed: AppKit/SwiftUI content is rendered with
/// `cacheDisplay`, and each `WKWebView` (out-of-process, so invisible to cacheDisplay) is
/// snapshotted separately and composited at its frame. Debug builds only.
enum DebugSnapshot {
    nonisolated(unsafe) private static var traceURL: URL?

    /// Appends a line to `<snapshot>.log` so scripted runs can see progress without a console.
    private static func trace(_ message: String) {
        NSLog("[snapshot] %@", message)
        guard let traceURL else { return }
        let line = "\(Date()) \(message)\n"
        if let handle = try? FileHandle(forWritingTo: traceURL) {
            handle.seekToEndOfFile()
            handle.write(line.data(using: .utf8)!)
            try? handle.close()
        } else {
            try? line.write(to: traceURL, atomically: true, encoding: .utf8)
        }
    }

    static func scheduleIfRequested() {
        #if DEBUG
        let args = CommandLine.arguments
        guard let i = args.firstIndex(of: "--snapshot"), i + 1 < args.count else { return }
        let destination = URL(fileURLWithPath: args[i + 1])
        traceURL = URL(fileURLWithPath: destination.path + ".log")
        let delay = Double(args.first(where: { $0.hasPrefix("--snapshot-delay=") })?
            .dropFirst("--snapshot-delay=".count) ?? "") ?? 4.0
        trace("scheduled in \(delay)s → \(destination.path)")

        Task { @MainActor in
            try? await Task.sleep(for: .seconds(delay))
            await capture(to: destination)
            // `--quit-after-snapshot` lets scripted runs (scripts/smoke.sh) end deterministically
            // without hunting for the pid that `open -n` launched.
            if args.contains("--quit-after-snapshot") {
                trace("quitting")
                exit(0)
            }
        }
        #endif
    }

    @MainActor
    private static func capture(to url: URL) async {
        let windows = NSApp.windows
        trace("windows: " + windows.map { "\($0.title.isEmpty ? "(untitled)" : $0.title) visible=\($0.isVisible) \(Int($0.frame.width))x\(Int($0.frame.height))" }.joined(separator: "; "))
        guard let window = windows
            .filter({ $0.isVisible })
            .max(by: { $0.frame.width * $0.frame.height < $1.frame.width * $1.frame.height }),
              let root = window.contentView?.superview ?? window.contentView   // theme frame incl. title bar
        else { trace("no visible window"); return }

        let bounds = root.bounds
        guard let rep = root.bitmapImageRepForCachingDisplay(in: bounds) else { trace("no bitmap rep"); return }
        root.cacheDisplay(in: bounds, to: rep)
        let image = NSImage(size: bounds.size)
        image.addRepresentation(rep)
        trace("cached display \(Int(bounds.width))x\(Int(bounds.height))")

        // Composite every web view.
        var webSnapshots: [(NSImage, NSRect)] = []
        for webView in webViews(in: root) where !webView.isHidden && webView.alphaValue > 0 {
            let frameInRoot = webView.convert(webView.bounds, to: root)
            trace("web view at \(frameInRoot) loading=\(webView.isLoading) url=\(webView.url?.lastPathComponent ?? "nil")")
            do {
                let shot = try await snapshot(webView, timeout: 5)
                webSnapshots.append((shot, frameInRoot))
                trace("web snapshot ok \(shot.size)")
            } catch {
                trace("web snapshot failed: \(error)")
            }
        }

        let isFlipped = root.isFlipped
        let composed = NSImage(size: bounds.size, flipped: false) { rect in
            image.draw(in: rect)
            for (shot, frame) in webSnapshots {
                // cacheDisplay output is in root's coordinate space (non-flipped: origin bottom-left).
                let target = isFlipped
                    ? NSRect(x: frame.minX, y: rect.height - frame.maxY, width: frame.width, height: frame.height)
                    : frame
                shot.draw(in: target)
            }
            return true
        }

        guard let tiff = composed.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff),
              let png = bitmap.representation(using: .png, properties: [:])
        else { return }
        do {
            try png.write(to: url)
            trace("wrote \(url.path) \(Int(bounds.width))x\(Int(bounds.height)) webviews=\(webSnapshots.count)")
        } catch {
            trace("write failed: \(error)")
        }
    }

    private struct TimeoutError: Error {}

    /// `takeSnapshot` with a deadline — WebKit can stall if the content process isn't ready.
    @MainActor
    private static func snapshot(_ webView: WKWebView, timeout: Double) async throws -> NSImage {
        try await withCheckedThrowingContinuation { continuation in
            let once = ResumeOnce(continuation)
            webView.takeSnapshot(with: nil) { image, error in
                if let image { once.resume(.success(image)) } else { once.resume(.failure(error ?? TimeoutError())) }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + timeout) { once.resume(.failure(TimeoutError())) }
        }
    }

    @MainActor
    private final class ResumeOnce {
        private var continuation: CheckedContinuation<NSImage, any Error>?
        init(_ c: CheckedContinuation<NSImage, any Error>) { continuation = c }
        func resume(_ result: Result<NSImage, any Error>) {
            continuation?.resume(with: result)
            continuation = nil
        }
    }

    @MainActor
    private static func webViews(in view: NSView) -> [WKWebView] {
        var result: [WKWebView] = []
        if let w = view as? WKWebView { result.append(w) }
        for sub in view.subviews { result += webViews(in: sub) }
        return result
    }
}
