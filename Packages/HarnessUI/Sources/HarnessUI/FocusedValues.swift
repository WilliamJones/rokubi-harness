import HarnessCore
import SwiftUI

/// Lets app-level menu commands reach the workspace of the frontmost window.
public struct WorkspaceFocusedKey: FocusedValueKey {
    public typealias Value = ProjectWorkspace
}

public struct EditorFocusedKey: FocusedValueKey {
    public typealias Value = EditorCoordinator
}

extension FocusedValues {
    public var workspace: ProjectWorkspace? {
        get { self[WorkspaceFocusedKey.self] }
        set { self[WorkspaceFocusedKey.self] = newValue }
    }

    public var editor: EditorCoordinator? {
        get { self[EditorFocusedKey.self] }
        set { self[EditorFocusedKey.self] = newValue }
    }
}
