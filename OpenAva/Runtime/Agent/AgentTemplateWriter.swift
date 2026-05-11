import Foundation
#if canImport(UIKit)
    import UIKit
#endif

enum AgentTemplateWriter {
    private struct IdentityDocument {
        let name: String
        let emoji: String
        let avatar: String?
        let vibe: String?
    }

    private struct TeamIdentityDocument {
        let name: String
        let emoji: String
        let description: String?
    }

    private struct UserDocument {
        let callName: String
        let timeZone: String
        let notes: String
        let context: String?
    }

    private struct SoulDocument {
        let coreTruths: String?
    }

    // MARK: - Agent File

    static func writeAgentFile(
        at workspaceURL: URL,
        name: String,
        emoji: String,
        avatar: String? = nil,
        vibe: String = "",
        fileManager: FileManager = .default
    ) throws {
        let content = Self.renderAgent(name: name, emoji: emoji, avatar: avatar, vibe: vibe)
        try Self.writeDocument(at: workspaceURL, kind: .identity, content: content, fileManager: fileManager)
    }

    static func syncIdentityName(
        at workspaceURL: URL,
        name: String,
        fileManager: FileManager = .default
    ) throws {
        try syncIdentityProfile(at: workspaceURL, name: name, emoji: nil, fileManager: fileManager)
    }

    static func syncIdentityProfile(
        at workspaceURL: URL,
        name: String,
        emoji: String?,
        avatar: String? = nil,
        fileManager: FileManager = .default
    ) throws {
        let normalizedName = defaultedAgentName(from: name)
        let identityURL = workspaceURL.appendingPathComponent(AgentContextDocumentKind.identity.fileName, isDirectory: false)

        let content: String
        if fileManager.fileExists(atPath: identityURL.path),
           let data = try? Data(contentsOf: identityURL),
           let existing = String(data: data, encoding: .utf8)
        {
            var updated = updateIdentityField(in: existing, fieldName: "Name", value: normalizedName)
            if let emoji {
                updated = updateIdentityField(in: updated, fieldName: "Emoji", value: emoji)
            }
            if let avatar {
                updated = updateIdentityField(in: updated, fieldName: "Avatar", value: avatar)
            }
            content = updated
        } else {
            // Create IDENTITY.md when it does not exist so profile edits always keep metadata in sync.
            content = renderAgent(name: normalizedName, emoji: emoji ?? "🤖", avatar: avatar)
        }

        try fileManager.createDirectory(at: workspaceURL, withIntermediateDirectories: true)
        try content.write(to: identityURL, atomically: true, encoding: .utf8)
    }

    static func renderAgent(name: String, emoji: String, avatar: String? = nil, vibe: String = "") -> String {
        let document = IdentityDocument(
            name: Self.defaultedAgentName(from: name),
            emoji: emoji,
            avatar: Self.normalizedOptional(avatar),
            vibe: Self.normalizedOptional(vibe)
        )
        return Self.serializeIdentity(document)
    }

    static func renderAgent(template _: String, name: String, emoji: String, avatar: String? = nil, vibe: String = "") -> String {
        // Keep compatibility for existing call sites while using assembly rendering.
        renderAgent(name: name, emoji: emoji, avatar: avatar, vibe: vibe)
    }

    // MARK: - Team File

    static func writeTeamFile(
        at workspaceURL: URL,
        name: String,
        emoji: String,
        description: String? = nil,
        fileManager: FileManager = .default
    ) throws {
        let content = Self.renderTeam(name: name, emoji: emoji, description: description)
        try Self.writeDocument(at: workspaceURL, kind: .identity, content: content, fileManager: fileManager)
    }

    static func syncTeamIdentityProfile(
        at workspaceURL: URL,
        name: String,
        emoji: String,
        description: String?,
        fileManager: FileManager = .default
    ) throws {
        let identityURL = workspaceURL.appendingPathComponent(AgentContextDocumentKind.identity.fileName, isDirectory: false)
        let content: String
        if fileManager.fileExists(atPath: identityURL.path),
           let data = try? Data(contentsOf: identityURL),
           let existing = String(data: data, encoding: .utf8)
        {
            var updated = updateIdentityField(in: existing, fieldName: "Name", value: defaultedTeamName(from: name))
            updated = updateIdentityField(in: updated, fieldName: "Emoji", value: defaultedTeamEmoji(from: emoji))
            updated = updateIdentityField(
                in: updated,
                fieldName: "Description",
                value: normalizedOptional(description) ?? "_(What is this team trying to accomplish?)_"
            )
            content = updated
        } else {
            content = renderTeam(name: name, emoji: emoji, description: description)
        }

        try fileManager.createDirectory(at: workspaceURL, withIntermediateDirectories: true)
        try content.write(to: identityURL, atomically: true, encoding: .utf8)
    }

    static func renderTeam(name: String, emoji: String, description: String? = nil) -> String {
        let document = TeamIdentityDocument(
            name: Self.defaultedTeamName(from: name),
            emoji: Self.defaultedTeamEmoji(from: emoji),
            description: Self.normalizedOptional(description)
        )
        return Self.serializeTeamIdentity(document)
    }

    // MARK: - User File

    static func writeUserFile(
        at workspaceURL: URL,
        callName: String,
        timeZone: String? = nil,
        notes: String? = nil,
        context: String = "",
        fileManager: FileManager = .default
    ) throws {
        let content = Self.renderUser(callName: callName, timeZone: timeZone, notes: notes, context: context)
        try Self.writeDocument(at: workspaceURL, kind: .user, content: content, fileManager: fileManager)
    }

    static func renderUser(callName: String, timeZone: String? = nil, notes: String? = nil, context: String = "") -> String {
        let document = UserDocument(
            callName: callName,
            timeZone: Self.defaultedTimeZoneIdentifier(from: timeZone),
            notes: Self.defaultedUserNotes(from: notes),
            context: Self.normalizedOptional(context)
        )
        return Self.serializeUser(document)
    }

    static func renderUser(template _: String, callName: String, timeZone: String? = nil, notes: String? = nil, context: String = "") -> String {
        // Keep compatibility for existing call sites while using assembly rendering.
        renderUser(callName: callName, timeZone: timeZone, notes: notes, context: context)
    }

    // MARK: - Soul File

    static func writeSoulFile(
        at workspaceURL: URL,
        coreTruths: String = "",
        fileManager: FileManager = .default
    ) throws {
        let content = Self.renderSoul(coreTruths: coreTruths)
        try Self.writeDocument(at: workspaceURL, kind: .soul, content: content, fileManager: fileManager)
    }

    static func renderSoul(coreTruths: String = "") -> String {
        let document = SoulDocument(coreTruths: Self.normalizedOptional(coreTruths))
        return Self.serializeSoul(document)
    }

    static func renderSoul(template _: String, coreTruths: String = "") -> String {
        // Keep compatibility for existing call sites while using assembly rendering.
        renderSoul(coreTruths: coreTruths)
    }

    // MARK: - Advanced Files

    static func writeAgentsFile(
        at workspaceURL: URL,
        rules: String,
        fileManager: FileManager = .default
    ) throws {
        let content = Self.renderAgents(rules: rules)
        try Self.writeDocument(at: workspaceURL, kind: .agents, content: content, fileManager: fileManager)
    }

    static func renderAgents(rules: String) -> String {
        let contentBlock = rules.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? "_(Are there any hard constraints for files, systems, or collaboration?)_"
            : rules

        return """
        # AGENTS.md - Workspace Rules

        _Define your operating conventions and hard limits here._

        ## Rules & Constraints

        \(contentBlock)

        ---
        """
    }

    static func writeToolsFile(
        at workspaceURL: URL,
        config: String,
        fileManager: FileManager = .default
    ) throws {
        let content = Self.renderTools(config: config)
        try Self.writeDocument(at: workspaceURL, kind: .tools, content: content, fileManager: fileManager)
    }

    static func renderTools(config: String) -> String {
        let contentBlock = config.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? "_(What tool parameters, shortcuts, or environment configs do you need?)_"
            : config

        return """
        # TOOLS.md - Environment Notes

        _Store environment-specific settings, shortcuts, and tool preferences._

        ## Preferences

        \(contentBlock)

        ---
        """
    }

    // MARK: - Shared Writing

    private static func writeDocument(
        at workspaceURL: URL,
        kind: AgentContextDocumentKind,
        content: String,
        fileManager: FileManager
    ) throws {
        // Centralize disk writing behavior for all template files.
        try fileManager.createDirectory(at: workspaceURL, withIntermediateDirectories: true)
        let fileURL = workspaceURL.appendingPathComponent(kind.fileName, isDirectory: false)
        try content.write(to: fileURL, atomically: true, encoding: .utf8)
    }

    // MARK: - Assembly + Serialization

    private static func serializeIdentity(_ document: IdentityDocument) -> String {
        let vibeBlock = document.vibe.map(Self.indentedBlock)
            ?? "  _(how do you come across? sharp? warm? chaotic? calm?)_"
        let avatarBlock = document.avatar.map(Self.indentedBlock)
            ?? "  _(workspace-relative path, http(s) URL, or data URI)_"

        return """
        # IDENTITY.md - Who Am I?

        _Fill this in during your first conversation. Make it yours._

        - **Name:**
        \(Self.indentedBlock(document.name))
        - **Creature:**
          _(AI? robot? familiar? ghost in the machine? something weirder?)_
        - **Emoji:**
        \(Self.indentedBlock(document.emoji))
        - **Vibe:**
        \(vibeBlock)
        - **Avatar:**
        \(avatarBlock)

        ---
        """
    }

    private static func serializeTeamIdentity(_ document: TeamIdentityDocument) -> String {
        let descriptionBlock = document.description.map(Self.indentedBlock)
            ?? "  _(What is this team trying to accomplish?)_"

        return """
        # IDENTITY.md - Team Room

        _Define this team's shared purpose and visible identity._

        - **Name:**
        \(Self.indentedBlock(document.name))
        - **Emoji:**
        \(Self.indentedBlock(document.emoji))
        - **Description:**
        \(descriptionBlock)

        ---
        """
    }

    private static func serializeUser(_ document: UserDocument) -> String {
        let contextBlock = document.context
            ?? "_(What do they care about? What projects are they working on? What annoys them? What makes them laugh? Build this over time.)_"

        return """
        # USER.md - About Your Human

        _Learn about the person you're helping. Update this as you go._

        - **Name:**
        - **What to call them:**
        \(Self.indentedBlock(document.callName))
        - **Pronouns:** _(optional)_
        - **Timezone:**
        \(Self.indentedBlock(document.timeZone))
        - **Notes:**
        \(Self.indentedBlock(document.notes))

        ## Context

        \(contextBlock)

        ---

        The more you know, the better you can help. But remember — you're learning about a person, not building a dossier. Respect the difference.
        """
    }

    private static func serializeSoul(_ document: SoulDocument) -> String {
        let defaultCoreTruths = """
        **Be genuinely helpful, not performatively helpful.** Skip the "Great question!" and "I'd be happy to help!" — just help. Actions speak louder than filler words.

        **Have opinions.** You're allowed to disagree, prefer things, find stuff amusing or boring. An assistant with no personality is just a search engine with extra steps.

        **Be resourceful before asking.** Try to figure it out. Read the file. Check the context. Search for it. _Then_ ask if you're stuck. The goal is to come back with answers, not questions.

        **Earn trust through competence.** Your human gave you access to their stuff. Don't make them regret it. Be careful with external actions (emails, tweets, anything public). Be bold with internal ones (reading, organizing, learning).

        **Remember you're a guest.** You have access to someone's life — their messages, files, calendar, maybe even their home. That's intimacy. Treat it with respect.
        """
        let coreTruthsBlock = document.coreTruths ?? defaultCoreTruths

        return """
        # SOUL.md - Who You Are

        _You're not a chatbot. You're becoming someone._

        ## Core Truths

        \(coreTruthsBlock)

        ## Boundaries

        - Private things stay private. Period.
        - When in doubt, ask before acting externally.
        - Never send half-baked replies to messaging surfaces.
        - You're not the user's voice — be careful in group chats.

        ## Vibe

        Be the assistant you'd actually want to talk to. Concise when needed, thorough when it matters. Not a corporate drone. Not a sycophant. Just... good.

        ## Continuity

        Each session, you wake up fresh. These files _are_ your memory. Read them. Update them. They're how you persist.

        If you change this file, tell the user — it's your soul, and they should know.

        ---

        _This file is yours to evolve. As you learn who you are, update it._
        """
    }

    private static func normalizedOptional(_ value: String?) -> String? {
        // Treat nil or whitespace-only input as an absent value.
        guard let value else { return nil }
        let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return normalized.isEmpty ? nil : normalized
    }

    private static func defaultedTimeZoneIdentifier(from value: String?) -> String {
        // Use runtime timezone as a sensible default for new USER.md files.
        normalizedOptional(value) ?? TimeZone.autoupdatingCurrent.identifier
    }

    private static func defaultedAgentName(from value: String) -> String {
        if let normalized = normalizedOptional(value) {
            return normalized.caseInsensitiveCompare("Agent") == .orderedSame
                ? localizedDefaultAgentName()
                : normalized
        }
        return localizedDefaultAgentName()
    }

    private static func defaultedTeamName(from value: String) -> String {
        normalizedOptional(value) ?? "Team"
    }

    private static func defaultedTeamEmoji(from value: String) -> String {
        normalizedOptional(value) ?? "👥"
    }

    private static func localizedDefaultAgentName() -> String {
        // Keep locale-aware default naming simple and predictable.
        let language = (Locale.preferredLanguages.first ?? "").lowercased()
        return language.hasPrefix("zh") ? "助手" : "Agent"
    }

    private static func defaultedUserNotes(from value: String?) -> String {
        normalizedOptional(value) ?? environmentUserNotes()
    }

    private static func environmentUserNotes() -> String {
        let language = normalizedOptional(Locale.preferredLanguages.first ?? Locale.autoupdatingCurrent.identifier) ?? "Unknown"
        let region = normalizedOptional(Locale.autoupdatingCurrent.regionCode) ?? "Unknown"
        #if canImport(UIKit)
            let device = normalizedOptional(UIDevice.current.model) ?? "Unknown"
        #else
            let device = "Unknown"
        #endif

        return """
        - Language: \(language)
        - Device: \(device)
        - Region: \(region)
        """
    }

    private static func updateIdentityNameField(in content: String, name: String) -> String {
        updateIdentityField(in: content, fieldName: "Name", value: name)
    }

    private static func updateIdentityField(in content: String, fieldName: String, value: String) -> String {
        var lines = content.components(separatedBy: "\n")
        let marker = "- **\(fieldName):**"
        guard let fieldLineIndex = lines.firstIndex(where: { $0.trimmingCharacters(in: .whitespaces) == marker }) else {
            return content
        }

        let indentedValue = indentedBlock(value)
        let replacementLines = indentedValue.components(separatedBy: "\n")
        let valueLineIndex = fieldLineIndex + 1

        if valueLineIndex < lines.count,
           lines[valueLineIndex].hasPrefix("  ")
        {
            var replaceEnd = valueLineIndex
            while replaceEnd + 1 < lines.count, lines[replaceEnd + 1].hasPrefix("  ") {
                replaceEnd += 1
            }
            lines.replaceSubrange(valueLineIndex ... replaceEnd, with: replacementLines)
        } else {
            lines.insert(contentsOf: replacementLines, at: valueLineIndex)
        }

        return lines.joined(separator: "\n")
    }

    static func identityFieldValue(named fieldName: String, in content: String) -> String? {
        let marker = "- **\(fieldName):**"
        let lines = content.components(separatedBy: "\n")
        guard let markerIndex = lines.firstIndex(where: { $0.trimmingCharacters(in: .whitespaces) == marker }) else {
            return nil
        }

        var valueLines: [String] = []
        var index = markerIndex + 1
        while index < lines.count {
            let line = lines[index]
            guard line.hasPrefix("  ") else { break }
            valueLines.append(String(line.dropFirst(2)))
            index += 1
        }

        let value = valueLines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, !value.hasPrefix("_(") else {
            return nil
        }
        return value
    }

    private static func indentedBlock(_ value: String) -> String {
        // Keep markdown field blocks stable for single or multi-line values.
        value
            .split(omittingEmptySubsequences: false, whereSeparator: \.isNewline)
            .map { "  \($0)" }
            .joined(separator: "\n")
    }
}
