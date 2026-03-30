import Foundation
import XCTest
@testable import OpenAva

final class AgentTemplateWriterTests: XCTestCase {
    func testRenderAssemblesNameAndEmojiFields() {
        let rendered = AgentTemplateWriter.renderAgent(name: "Nova", emoji: "🦊")
        XCTAssertTrue(rendered.contains("- **Name:**\n  Nova"))
        XCTAssertTrue(rendered.contains("- **Emoji:**\n  🦊"))
    }

    func testWriteAgentFileCreatesIdentityMarkdown() throws {
        let workspaceURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: workspaceURL) }

        try AgentTemplateWriter.writeAgentFile(at: workspaceURL, name: "Atlas", emoji: "🤖")

        let identityURL = workspaceURL.appendingPathComponent("IDENTITY.md", isDirectory: false)
        let content = try String(contentsOf: identityURL, encoding: .utf8)
        XCTAssertTrue(content.contains("- **Name:**\n  Atlas"))
        XCTAssertTrue(content.contains("- **Emoji:**\n  🤖"))
    }

    func testRenderUserDefaultsTimezoneToCurrentEnvironment() {
        let rendered = AgentTemplateWriter.renderUser(callName: "Yuan")
        let expectedTimeZone = TimeZone.autoupdatingCurrent.identifier

        XCTAssertTrue(rendered.contains("- **Timezone:**\n  \(expectedTimeZone)"))
    }

    func testRenderUserUsesProvidedTimezoneWhenAvailable() {
        let rendered = AgentTemplateWriter.renderUser(
            callName: "Yuan",
            timeZone: "Asia/Shanghai"
        )

        XCTAssertTrue(rendered.contains("- **Timezone:**\n  Asia/Shanghai"))
    }

    func testRenderAgentUsesLocaleBasedDefaultNameWhenPlaceholderProvided() {
        let rendered = AgentTemplateWriter.renderAgent(name: "Agent", emoji: "🤖")
        let language = (Locale.preferredLanguages.first ?? "").lowercased()
        let expectedName = language.hasPrefix("zh") ? "助手" : "Agent"

        XCTAssertTrue(rendered.contains("- **Name:**\n  \(expectedName)"))
    }

    func testRenderUserPrefillsEnvironmentNotes() {
        let rendered = AgentTemplateWriter.renderUser(callName: "Yuan")

        XCTAssertTrue(rendered.contains("- **Notes:**\n  - Language: "))
        XCTAssertTrue(rendered.contains("\n  - Device: "))
        XCTAssertTrue(rendered.contains("\n  - Region: "))
    }

    func testRenderUserUsesProvidedNotesWhenAvailable() {
        let rendered = AgentTemplateWriter.renderUser(
            callName: "Yuan",
            notes: "Prefers concise answers"
        )

        XCTAssertTrue(rendered.contains("- **Notes:**\n  Prefers concise answers"))
    }

    func testSyncIdentityNameOnlyReplacesNameField() throws {
        let workspaceURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: workspaceURL) }

        let initial = """
        # IDENTITY.md - Who Am I?

        - **Name:**
          Atlas
        - **Emoji:**
          🤖
        - **Vibe:**
          Calm
        """

        try FileManager.default.createDirectory(at: workspaceURL, withIntermediateDirectories: true)
        let identityURL = workspaceURL.appendingPathComponent("IDENTITY.md", isDirectory: false)
        try initial.write(to: identityURL, atomically: true, encoding: .utf8)

        try AgentTemplateWriter.syncIdentityName(at: workspaceURL, name: "Nova")

        let content = try String(contentsOf: identityURL, encoding: .utf8)
        XCTAssertTrue(content.contains("- **Name:**\n  Nova"))
        XCTAssertTrue(content.contains("- **Emoji:**\n  🤖"))
        XCTAssertTrue(content.contains("- **Vibe:**\n  Calm"))
    }

    func testSyncIdentityNameCreatesIdentityWhenMissing() throws {
        let workspaceURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: workspaceURL) }

        try AgentTemplateWriter.syncIdentityName(at: workspaceURL, name: "Luna")

        let identityURL = workspaceURL.appendingPathComponent("IDENTITY.md", isDirectory: false)
        let content = try String(contentsOf: identityURL, encoding: .utf8)
        XCTAssertTrue(content.contains("- **Name:**\n  Luna"))
    }
}
