import Foundation

/// PRD §13 — the only persistent agent control is how much authority it has.
public enum AutonomyPreset: String, CaseIterable, Identifiable, Sendable, Codable {
    case readOnly, standard, askBeforeCommands, fullAutonomy

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .readOnly: "Read Only"
        case .standard: "Standard"
        case .askBeforeCommands: "Ask Before Commands"
        case .fullAutonomy: "Full Autonomy"
        }
    }

    public var summary: String {
        switch self {
        case .readOnly: "Can inspect but cannot modify."
        case .standard: "Can read, search and edit. Destructive or external actions require approval."
        case .askBeforeCommands: "File edits proceed; terminal commands require approval."
        case .fullAutonomy: "Edit → run → test → fix → verify without stopping, within hard security limits."
        }
    }
}
