import Foundation
#if canImport(UIKit)
    import UIKit
#endif

enum AgentTemplateWriter {
    private struct IdentityDocument {
        let name: String
        let emoji: String
        let vibe: String?
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
        vibe: String = "",
        fileManager: FileManager = .default
    ) throws {
        let content = Self.renderAgent(name: name, emoji: emoji, vibe: vibe)
        try Self.writeDocument(at: workspaceURL, kind: .identity, content: content, fileManager: fileManager)
    }

    static func syncIdentityName(
        at workspaceURL: URL,
        name: String,
        fileManager: FileManager = .default
    ) throws {
        let normalizedName = defaultedAgentName(from: name)
        let identityURL = workspaceURL.appendingPathComponent(AgentContextDocumentKind.identity.fileName, isDirectory: false)

        let content: String
        if fileManager.fileExists(atPath: identityURL.path),
           let data = try? Data(contentsOf: identityURL),
           let existing = String(data: data, encoding: .utf8)
        {
            content = updateIdentityNameField(in: existing, name: normalizedName)
        } else {
            // Create IDENTITY.md when it does not exist so rename always keeps name in sync.
            content = renderAgent(name: normalizedName, emoji: "🤖")
        }

        try fileManager.createDirectory(at: workspaceURL, withIntermediateDirectories: true)
        try content.write(to: identityURL, atomically: true, encoding: .utf8)
    }

    static func renderAgent(name: String, emoji: String, vibe: String = "") -> String {
        let document = IdentityDocument(
            name: Self.defaultedAgentName(from: name),
            emoji: emoji,
            vibe: Self.normalizedOptional(vibe)
        )
        return Self.serializeIdentity(document)
    }

    static func renderAgent(template _: String, name: String, emoji: String, vibe: String = "") -> String {
        // Keep compatibility for existing call sites while using assembly rendering.
        renderAgent(name: name, emoji: emoji, vibe: vibe)
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
          _(workspace-relative path, http(s) URL, or data URI)_

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
        var lines = content.components(separatedBy: "\n")
        guard let nameLineIndex = lines.firstIndex(where: { $0.trimmingCharacters(in: .whitespaces) == "- **Name:**" }) else {
            // Fallback to append a minimal Name field when template markers are missing.
            let suffix = content.isEmpty ? "" : "\n"
            return content + "\(suffix)- **Name:**\n\(indentedBlock(name))"
        }

        let indentedName = indentedBlock(name)
        let replacementLines = indentedName.components(separatedBy: "\n")
        let valueLineIndex = nameLineIndex + 1

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

    private static func indentedBlock(_ value: String) -> String {
        // Keep markdown field blocks stable for single or multi-line values.
        value
            .split(omittingEmptySubsequences: false, whereSeparator: \.isNewline)
            .map { "  \($0)" }
            .joined(separator: "\n")
    }
}
