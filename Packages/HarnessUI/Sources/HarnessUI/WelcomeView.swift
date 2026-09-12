import AppKit
import HarnessCore
import SwiftUI

/// First window: open a folder or pick a recent project.
public struct WelcomeView: View {
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismiss) private var dismiss
    @State private var recents = RecentProjects.shared

    public init() {}

    public var body: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 14) {
                Text("ROKUBI Harness").font(.system(size: 28, weight: .semibold))
                Text("Project + Editor + Agent").foregroundStyle(.secondary)
                Spacer()
                Button {
                    if let url = ProjectPicker.chooseFolder() { open(ProjectRef(url: url)) }
                } label: {
                    Label("Open Folder…", systemImage: "folder")
                }
                .keyboardShortcut("o")
                Text("Or drop a folder here").font(.caption).foregroundStyle(.tertiary)
            }
            .padding(28)
            .frame(width: 300, alignment: .leading)

            Divider()

            List {
                Section("Recent") {
                    if recents.projects.isEmpty {
                        Text("No recent projects").foregroundStyle(.tertiary)
                    }
                    ForEach(recents.projects) { ref in
                        Button { open(ref) } label: {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(ref.name)
                                Text(ref.url.deletingLastPathComponent().path.replacingOccurrences(of: NSHomeDirectory(), with: "~"))
                                    .font(.caption).foregroundStyle(.tertiary).lineLimit(1)
                            }
                        }
                        .buttonStyle(.plain)
                        .contextMenu { Button("Remove from Recents") { recents.remove(ref) } }
                    }
                }
            }
            .frame(width: 320)
        }
        .frame(height: 360)
        .dropDestination(for: URL.self) { urls, _ in
            guard let url = urls.first(where: { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true })
            else { return false }
            open(ProjectRef(url: url))
            return true
        }
        .task {
            // `RokubiHarness.app/Contents/MacOS/RokubiHarness --project /path` opens straight into a project
            // (used by scripts/run.sh and UI smoke tests).
            if let url = LaunchArguments.projectURL, !LaunchArguments.consumed {
                LaunchArguments.consumed = true
                open(ProjectRef(url: url))
            }
        }
    }

    private func open(_ ref: ProjectRef) {
        recents.touch(ref)
        openWindow(value: ref)
        dismiss()
    }
}

/// CLI flags for scripted runs: `--project <dir>` opens a project window, `--open <file>` opens a file in it.
@MainActor
public enum LaunchArguments {
    static var consumed = false
    static var openConsumed = false

    static var projectURL: URL? {
        guard let url = value(for: "--project") else { return nil }
        var isDir: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) && isDir.boolValue ? url : nil
    }

    /// Absolute or project-relative file to open once the workspace appears.
    static func fileToOpen(in root: URL) -> URL? {
        guard !openConsumed, let raw = rawValue(for: "--open") else { return nil }
        openConsumed = true
        let url = raw.hasPrefix("/") ? URL(fileURLWithPath: raw) : root.appendingPathComponent(raw)
        return FileManager.default.fileExists(atPath: url.path) ? url.standardizedFileURL : nil
    }

    static var promptConsumed = false

    /// `--prompt "text"` — auto-send once (Debug smoke tests).
    static func promptToSend() -> String? {
        #if DEBUG
        guard !promptConsumed, let p = rawValue(for: "--prompt") else { return nil }
        promptConsumed = true
        return p
        #else
        return nil
        #endif
    }

    private static func rawValue(for flag: String) -> String? {
        let args = CommandLine.arguments
        guard let i = args.firstIndex(of: flag), i + 1 < args.count else { return nil }
        return args[i + 1]
    }

    private static func value(for flag: String) -> URL? {
        rawValue(for: flag).map { URL(fileURLWithPath: $0).standardizedFileURL }
    }
}

public enum ProjectPicker {
    @MainActor
    public static func chooseFolder() -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        panel.prompt = "Open Project"
        panel.message = "Choose a project folder"
        return panel.runModal() == .OK ? panel.url : nil
    }
}
