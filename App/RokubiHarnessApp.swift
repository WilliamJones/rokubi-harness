import HarnessAgent
import HarnessCore
import HarnessUI
import SwiftUI

@main
struct RokubiHarnessApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    init() {
        #if DEBUG
        // Scripted tests set ROKUBI_STDERR to capture crash/precondition output under `open`.
        if let path = ProcessInfo.processInfo.environment["ROKUBI_STDERR"] {
            freopen(path, "a", stderr)
            setbuf(stderr, nil)
        }
        #endif
    }
    @State private var auth = AuthSession()
    @State private var models = ModelCatalog()

    var body: some Scene {
        Window("Welcome to ROKUBI Harness", id: "welcome") {
            WelcomeView()
                .environment(auth)
                .environment(models)
        }
        .windowResizability(.contentSize)
        .defaultPosition(.center)

        WindowGroup(for: ProjectRef.self) { $ref in
            Group {
                if let ref {
                    WorkspaceRoot(ref: ref)
                } else {
                    WelcomeView()
                }
            }
            .environment(auth)
            .environment(models)
        }
        .defaultSize(width: 1320, height: 840)
        .commands { HarnessCommands() }
    }
}

/// Owns the `ProjectWorkspace` for one window.
private struct WorkspaceRoot: View {
    @State private var workspace: ProjectWorkspace

    init(ref: ProjectRef) {
        _workspace = State(initialValue: ProjectWorkspace(ref: ref))
    }

    var body: some View {
        WorkspaceView(workspace: workspace)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        DebugSnapshot.scheduleIfRequested()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
}
