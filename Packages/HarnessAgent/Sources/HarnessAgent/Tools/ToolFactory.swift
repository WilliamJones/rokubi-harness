import Foundation
import HarnessCore

/// Assembles the default tool set. `run_command` needs an executor (HarnessTerminal); M6 adds `git_*`.
public enum ToolFactory {
    public static func defaultTools(executor: (any CommandExecutor)? = nil, extra: [any Tool] = []) -> ToolRegistry {
        var tools: [any Tool] = [
            ReadFileTool(), ListDirTool(), GlobTool(), GrepTool(),
            ApplyPatchTool(), WriteFileTool(), CreateFileTool(), RenamePathTool(), DeletePathTool(),
            UpdatePlanTool(), ReportCompletionTool(),
        ]
        if let executor { tools.append(RunCommandTool(executor: executor)) }
        return ToolRegistry(tools + extra)
    }
}
