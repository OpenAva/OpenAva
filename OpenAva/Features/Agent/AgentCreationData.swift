import Foundation

/// Data collected during local agent creation wizard.
struct AgentCreationData {
    // MARK: - USER.md fields

    /// What to call the user.
    var userCallName: String = ""

    /// Context about the user.
    var userContext: String = ""

    // MARK: - IDENTITY.md fields

    /// Agent name.
    var agentName: String = ""

    /// Agent emoji signature.
    var agentEmoji: String = "🦞"

    /// Optional uploaded avatar image data.
    var agentAvatarData: Data?

    /// Agent vibe description.
    var agentVibe: String = ""

    // MARK: - SOUL.md fields

    /// Core truths for the AI assistant.
    var soulCoreTruths: String = ""

    // MARK: - Advanced fields

    /// Rules and boundaries for AGENTS.md
    var agentsRules: String = ""

    /// Environment and tool notes for TOOLS.md
    var toolsConfig: String = ""
}
