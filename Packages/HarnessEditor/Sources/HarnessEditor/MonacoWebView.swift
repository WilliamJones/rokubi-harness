import AppKit
import SwiftUI
import WebKit

/// NSView hosting the Monaco `WKWebView` and wiring the script message handler.
@MainActor
public final class MonacoWebView: NSView {
    public let controller: MonacoController
    let webView: WKWebView
    private let proxy: ScriptMessageProxy

    /// Location of the bundled `editor.html`. Defaults to `Monaco/editor.html` in the main bundle.
    public static var bundleURL: URL? = Bundle.main.url(forResource: "editor", withExtension: "html", subdirectory: "Monaco")

    public init(controller: MonacoController) {
        self.controller = controller
        self.proxy = ScriptMessageProxy()

        let config = WKWebViewConfiguration()
        config.userContentController.add(proxy, name: "harness")
        config.setValue(true, forKey: "allowUniversalAccessFromFileURLs")
        #if DEBUG
        config.preferences.setValue(true, forKey: "developerExtrasEnabled")
        #endif

        webView = WKWebView(frame: .zero, configuration: config)
        webView.setValue(false, forKey: "drawsBackground")
        webView.allowsMagnification = false

        super.init(frame: .zero)
        proxy.controller = controller
        controller.attach(webView)

        addSubview(webView)
        webView.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            webView.leadingAnchor.constraint(equalTo: leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: trailingAnchor),
            webView.topAnchor.constraint(equalTo: topAnchor),
            webView.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        load()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    deinit {
        MainActor.assumeIsolated {
            webView.configuration.userContentController.removeScriptMessageHandler(forName: "harness")
        }
    }

    private func load() {
        guard let url = Self.bundleURL else {
            NSLog("[Monaco] editor.html not found in bundle — run scripts/build-web.sh")
            webView.loadHTMLString("<body style='font:13px -apple-system;padding:2em;color:#888'>Monaco bundle missing. Run scripts/build-web.sh.</body>", baseURL: nil)
            return
        }
        controller.pageDidReload()
        webView.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())
    }

    public override var acceptsFirstResponder: Bool { true }

    public override func becomeFirstResponder() -> Bool {
        window?.makeFirstResponder(webView)
        return true
    }
}

/// Keeps `WKUserContentController` from retaining the controller/view (it holds handlers strongly).
@MainActor
private final class ScriptMessageProxy: NSObject, WKScriptMessageHandler {
    weak var controller: MonacoController?

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        controller?.handleScriptMessage(message.body)
    }
}

/// SwiftUI wrapper. Theme follows the environment color scheme.
public struct MonacoEditorView: NSViewRepresentable {
    public let controller: MonacoController
    @Environment(\.colorScheme) private var colorScheme

    public init(controller: MonacoController) {
        self.controller = controller
    }

    public func makeCoordinator() -> Coordinator { Coordinator() }

    public func makeNSView(context: Context) -> MonacoWebView {
        let view = MonacoWebView(controller: controller)
        applyTheme(context: context)
        return view
    }

    public func updateNSView(_ nsView: MonacoWebView, context: Context) {
        applyTheme(context: context)
    }

    /// Only talk to the web view when the scheme actually changed — `updateNSView` runs often.
    private func applyTheme(context: Context) {
        let dark = colorScheme == .dark
        guard context.coordinator.appliedDark != dark else { return }
        context.coordinator.appliedDark = dark
        controller.setTheme(dark: dark)
    }

    @MainActor
    public final class Coordinator {
        var appliedDark: Bool?
    }
}
