import Foundation
import XCTest
@testable import OpenAva

final class IdentityTemplateWriterTests: XCTestCase {
    func testRenderAgentTemplateCompatibilityProducesIdentityContent() {
        let template = "legacy-template-is-ignored"
        let rendered = AgentTemplateWriter.renderAgent(template: template, name: "Nova", emoji: "🦊")

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
}
