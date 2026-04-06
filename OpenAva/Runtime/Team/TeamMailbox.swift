import Foundation

struct TeamMailboxMessage: Codable, Equatable, Identifiable {
    let id: String
    let from: String
    let text: String
    let timestamp: Date
    var read: Bool
    let color: String?
    let summary: String?
    let messageType: String
}

enum TeamMailbox {
    static func readMessages(teamDirectoryURL: URL, recipientName: String) -> [TeamMailboxMessage] {
        let url = mailboxURL(teamDirectoryURL: teamDirectoryURL, recipientName: recipientName)
        guard let data = try? Data(contentsOf: url),
              let messages = try? JSONDecoder().decode([TeamMailboxMessage].self, from: data)
        else {
            return []
        }
        return messages.sorted { $0.timestamp < $1.timestamp }
    }

    @discardableResult
    static func append(
        teamDirectoryURL: URL,
        recipientName: String,
        message: TeamMailboxMessage
    ) throws -> [TeamMailboxMessage] {
        var messages = readMessages(teamDirectoryURL: teamDirectoryURL, recipientName: recipientName)
        messages.append(message)
        try write(messages: messages, teamDirectoryURL: teamDirectoryURL, recipientName: recipientName)
        return messages
    }

    static func unreadMessages(teamDirectoryURL: URL, recipientName: String) -> [TeamMailboxMessage] {
        readMessages(teamDirectoryURL: teamDirectoryURL, recipientName: recipientName).filter { !$0.read }
    }

    static func markRead(
        teamDirectoryURL: URL,
        recipientName: String,
        messageIDs: Set<String>
    ) throws {
        guard !messageIDs.isEmpty else { return }
        var messages = readMessages(teamDirectoryURL: teamDirectoryURL, recipientName: recipientName)
        var didChange = false
        for index in messages.indices where messageIDs.contains(messages[index].id) {
            if !messages[index].read {
                messages[index].read = true
                didChange = true
            }
        }
        if didChange {
            try write(messages: messages, teamDirectoryURL: teamDirectoryURL, recipientName: recipientName)
        }
    }

    static func unreadCount(teamDirectoryURL: URL, recipientName: String) -> Int {
        unreadMessages(teamDirectoryURL: teamDirectoryURL, recipientName: recipientName).count
    }

    static func lastPreview(teamDirectoryURL: URL, recipientName: String) -> String? {
        let messages = readMessages(teamDirectoryURL: teamDirectoryURL, recipientName: recipientName)
        return messages.last?.summary ?? messages.last?.text
    }

    static func deleteAllMailboxes(teamDirectoryURL: URL) {
        let directory = mailboxesDirectoryURL(teamDirectoryURL: teamDirectoryURL)
        try? FileManager.default.removeItem(at: directory)
    }

    private static func write(
        messages: [TeamMailboxMessage],
        teamDirectoryURL: URL,
        recipientName: String
    ) throws {
        let directory = mailboxesDirectoryURL(teamDirectoryURL: teamDirectoryURL)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let data = try JSONEncoder().encode(messages)
        try data.write(to: mailboxURL(teamDirectoryURL: teamDirectoryURL, recipientName: recipientName), options: [.atomic])
    }

    private static func mailboxURL(teamDirectoryURL: URL, recipientName: String) -> URL {
        mailboxesDirectoryURL(teamDirectoryURL: teamDirectoryURL)
            .appendingPathComponent("\(sanitizedFileComponent(recipientName)).json", isDirectory: false)
    }

    private static func mailboxesDirectoryURL(teamDirectoryURL: URL) -> URL {
        teamDirectoryURL.appendingPathComponent("mailboxes", isDirectory: true)
    }

    private static func sanitizedFileComponent(_ value: String) -> String {
        value
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: "\\", with: "-")
            .replacingOccurrences(of: ":", with: "-")
    }
}
