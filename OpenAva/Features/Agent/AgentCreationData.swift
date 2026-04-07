import Foundation

/// Data collected during local agent creation wizard.
struct AgentCreationData {
    // MARK: - USER.md fields

    /// What to call the user.
    var userCallName: String = ""

    /// Context about the user.
    var userContext: String = ""

    // MARK: - TEAM fields

    /// Team name.
    var teamName: String = ""

    /// Team emoji signature.
    var teamEmoji: String = "👥"

    /// Team description.
    var teamDescription: String = ""

    // MARK: - IDENTITY.md fields

    /// Agent name.
    var agentName: String = "Agent"

    /// Agent emoji signature.
    var agentEmoji: String = "🦞"

    /// Agent vibe description.
    var agentVibe: String = ""

    // MARK: - SOUL.md fields

    /// Core truths for the AI assistant.
    var soulCoreTruths: String = ""
}
