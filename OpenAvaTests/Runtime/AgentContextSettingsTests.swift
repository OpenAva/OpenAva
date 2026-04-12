import Foundation
import XCTest
@testable import OpenAva

final class AgentContextSettingsTests: XCTestCase {
    func testEditableRootDirectoryFallsBackToApplicationSupport() throws {
        // Verify fallback to app support directory when no environment is configured.
        let rootURL = try AgentContextLoader.editableRootDirectory(environment: [:])
        XCTAssertTrue(rootURL.path.contains("OpenAva"))
        XCTAssertEqual(rootURL.lastPathComponent, "OpenAva")
    }

    func testEditableRootDirectoryFallsBackWhenPWDIsNotWritable() throws {
        // Simulate an unusable working directory and confirm fallback remains writable.
        let environment = ["PWD": "/dev/null/\(UUID().uuidString)"]
        let rootURL = try AgentContextLoader.editableRootDirectory(environment: environment)
        XCTAssertTrue(rootURL.path.contains("OpenAva"))
        XCTAssertEqual(rootURL.lastPathComponent, "OpenAva")
    }

    func testSaveEditableContentCreatesAndLoadsFile() throws {
        let tempRoot = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        let environment = ["OPENAVA_AGENT_CONTEXT_DIR": tempRoot.path]
        // Save and verify content persistence.
        try AgentContextLoader.saveEditableContent("# Identity", for: .identity, environment: environment)

        let loaded = try AgentContextLoader.loadEditableContent(for: .identity, environment: environment)
        XCTAssertEqual(loaded, "# Identity")
    }

    func testTemplateContentLoadsBuiltInAgentGuidance() {
        // Verify built-in templates are loaded correctly.
        let agentsTemplate = AgentContextLoader.templateContent(for: .agents)
        let toolsTemplate = AgentContextLoader.templateContent(for: .tools)
        let identityTemplate = AgentContextLoader.templateContent(for: .identity)

        XCTAssertEqual(agentsTemplate?.contains("# AGENTS.md - Your Workspace"), true)
        XCTAssertEqual(toolsTemplate?.contains("# TOOLS.md - Local Notes"), true)
        XCTAssertEqual(identityTemplate?.contains("# IDENTITY.md - Who Am I?"), true)
    }

    func testEditableContentIsolatedByRootOverride() throws {
        let tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let rootA = tempRoot.appendingPathComponent("identity-a", isDirectory: true)
        let rootB = tempRoot.appendingPathComponent("identity-b", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        // Separate roots should keep context documents fully isolated.
        try AgentContextLoader.saveEditableContent("A", for: .identity, workspaceRootURL: rootA)
        try AgentContextLoader.saveEditableContent("B", for: .identity, workspaceRootURL: rootB)

        let loadedA = try AgentContextLoader.loadEditableContent(for: .identity, workspaceRootURL: rootA)
        let loadedB = try AgentContextLoader.loadEditableContent(for: .identity, workspaceRootURL: rootB)

        XCTAssertEqual(loadedA, "A")
        XCTAssertEqual(loadedB, "B")
    }

    func testSkillsSummaryReportsMissingRequirements() throws {
        let rootURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let skillsURL = rootURL.appendingPathComponent("skills", isDirectory: true)
        let alphaURL = skillsURL.appendingPathComponent("alpha", isDirectory: true)

        try FileManager.default.createDirectory(at: alphaURL, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: rootURL) }

        let content = """
        ---
        description: Alpha skill
        metadata: {"openava":{"requires":{"env":["ALPHA_TOKEN"]}}}
        ---
        # Alpha

        Do alpha things.
        """
        try content.write(to: alphaURL.appendingPathComponent("SKILL.md"), atomically: true, encoding: .utf8)

        let summary = AgentSkillsLoader.buildSkillsSummary(
            environment: ["PWD": rootURL.path],
            fileManager: .default
        )

        XCTAssertTrue(summary.contains("<id>alpha</id>"))
        XCTAssertTrue(summary.contains("<display_name>Alpha</display_name>"))
        XCTAssertTrue(summary.contains("<skill available=\"false\">"))
        XCTAssertTrue(summary.contains("<requires>ENV: ALPHA_TOKEN</requires>"))
        XCTAssertTrue(summary.contains("</skill>"))
    }

    func testListSkillsUsesMetadataDisplayNameAndEmoji() throws {
        let rootURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let skillURL = rootURL
            .appendingPathComponent("skills", isDirectory: true)
            .appendingPathComponent("article-insights", isDirectory: true)
        try FileManager.default.createDirectory(at: skillURL, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: rootURL) }

        let content = """
        ---
        name: article-insights
        description: Analyze long-form content
        metadata:
          display_name: Article Insights
          emoji: 🔎
          author: example-org
          version: "1.0"
        ---
        # Article Insights
        """
        try content.write(to: skillURL.appendingPathComponent("SKILL.md"), atomically: true, encoding: .utf8)

        let skills = AgentSkillsLoader.listSkills(filterUnavailable: false, workspaceRootURL: rootURL)
        let article = try XCTUnwrap(skills.first(where: { $0.name == "article-insights" }))

        XCTAssertEqual(article.displayName, "Article Insights")
        XCTAssertEqual(article.emoji, "🔎")
    }

    func testComposeSystemPromptDoesNotInlineSkillsByDefault() throws {
        let rootURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let workspaceSkillURL = rootURL
            .appendingPathComponent("skills", isDirectory: true)
            .appendingPathComponent("alpha", isDirectory: true)
        try FileManager.default.createDirectory(at: workspaceSkillURL, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: rootURL) }

        let workspaceContent = """
        ---
        description: Workspace alpha
        metadata: {"openava":{"always":true}}
        ---
        # Workspace Alpha
        """
        try workspaceContent.write(to: workspaceSkillURL.appendingPathComponent("SKILL.md"), atomically: true, encoding: .utf8)

        let environment = ["PWD": rootURL.path]

        let prompt = AgentContextLoader.composeSystemPrompt(
            baseSystemPrompt: nil,
            memoryContext: nil,
            workspaceRootURL: rootURL,
            environment: environment,
            fileManager: .default
        )

        XCTAssertNotNil(prompt)
        XCTAssertTrue(prompt?.contains("Available skills (") == true)
        XCTAssertTrue(prompt?.contains("When the latest user message starts with an explicit slash skill invocation") == true)
        XCTAssertTrue(prompt?.contains("/skill-name task...") == true)
        XCTAssertTrue(prompt?.contains("BLOCKING REQUIREMENT: invoke `skill_invoke`") == true)
        XCTAssertTrue(prompt?.contains("<skill id=alpha source=workspace execution_context=inline>") == true)
        XCTAssertTrue(prompt?.contains("description: Workspace alpha") == true)
        XCTAssertFalse(prompt?.contains("Always-loaded skills:") == true)
        XCTAssertFalse(prompt?.contains("# Workspace Alpha") == true)
    }

    func testSkillLaunchServiceBuildsSlashSkillInvocationMessage() {
        let message = SkillLaunchService.makeInvocationMessage(
            skillName: "frontend-design",
            task: "Build landing page"
        )

        XCTAssertEqual(message, #"/frontend-design "Build landing page""#)
    }

    func testSkillLaunchServiceEscapesQuotedSlashArguments() {
        let message = SkillLaunchService.makeInvocationMessage(
            skillName: "expert-translator",
            task: #"Rewrite "Hello world" politely"#
        )

        XCTAssertEqual(message, #"/expert-translator "Rewrite \"Hello world\" politely""#)
    }

    func testSkillLaunchServiceLeavesSkillCommandBlankWhenTaskMissing() {
        let message = SkillLaunchService.makeInvocationMessage(
            skillName: "frontend-design",
            task: nil
        )

        XCTAssertEqual(message, "/frontend-design ")
    }

    func testBuiltInSkillsIncludeDefaultCatalogEntries() {
        // Ensure built-in skill files are discoverable in runtime skill listing.
        let names = Set(AgentSkillsLoader.listSkills(filterUnavailable: false).map(\.name))

        XCTAssertTrue(names.contains("arxiv-research"))
        XCTAssertTrue(names.contains("frontend-design"))
        XCTAssertTrue(names.contains("expert-translator"))
        XCTAssertTrue(names.contains("memory-maintenance"))
        XCTAssertTrue(names.contains("social-post-image"))
        XCTAssertTrue(names.contains("time-lock"))
    }

    func testBuiltInArxivResearchSkillMetadataIsReadable() {
        let skill = AgentSkillsLoader.resolveSkill(named: "arxiv-research", filterUnavailable: false)

        XCTAssertEqual(skill?.displayName, "arXiv Research")
        XCTAssertEqual(skill?.emoji, "📚")
        XCTAssertEqual(skill?.description, "Find, triage, and synthesize academic papers using `arxiv_search` plus OpenAva web reading tools.")
        XCTAssertEqual(skill?.whenToUse, "Use when the user wants to find papers, scan a research topic, compare recent work, or build a reading list from arXiv.")
    }

    func testBuiltInMemoryMaintenanceSkillRemainsDiscoverable() {
        // Built-in skills should remain discoverable even though none are auto-injected.
        let names = Set(AgentSkillsLoader.listSkills(filterUnavailable: false).map(\.name))

        XCTAssertTrue(names.contains("memory-maintenance"))
    }

    func testPromptBuilderFormatsSkillsCatalogWithSkillIDsOnly() {
        let catalog: [AgentSkillsLoader.SkillDefinition] = [
            .init(name: "alpha", displayName: "Alpha Skill", path: "/tmp/alpha/SKILL.md", source: "workspace", available: true, description: "Do alpha work.", requires: nil),
            .init(name: "beta", displayName: "Beta Skill", path: "/tmp/beta/SKILL.md", source: "workspace", available: false, description: "Do beta work", requires: "ENV: BETA_TOKEN"),
        ]

        let prompt = AgentPromptBuilder.composeSystemPrompt(
            baseSystemPrompt: nil,
            context: nil,
            skillCatalog: catalog,
            memoryContext: nil,
            rootDirectory: nil
        )

        XCTAssertTrue(prompt.contains("Available skills (1):"))
        XCTAssertTrue(prompt.contains("<skills>"))
        XCTAssertTrue(prompt.contains("<skill id=alpha source=workspace execution_context=inline>"))
        XCTAssertTrue(prompt.contains("name: Alpha Skill"))
        XCTAssertTrue(prompt.contains("description: Do alpha work."))
        XCTAssertFalse(prompt.contains("path: /tmp/alpha/SKILL.md"))
        XCTAssertFalse(prompt.contains("<skill id=beta"))
    }

    func testLoadSkillByIDUsesExactIdentifierMatch() throws {
        let rootURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let alphaURL = rootURL
            .appendingPathComponent("skills", isDirectory: true)
            .appendingPathComponent("alpha", isDirectory: true)
        try FileManager.default.createDirectory(at: alphaURL, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: rootURL) }

        let content = """
        ---
        name: Alpha Skill
        description: Workspace alpha
        ---
        # Alpha

        Exact-id loader.
        """
        try content.write(to: alphaURL.appendingPathComponent("SKILL.md"), atomically: true, encoding: .utf8)

        let loaded = AgentSkillsLoader.resolveSkill(named: "alpha", workspaceRootURL: rootURL)
        XCTAssertEqual(try AgentSkillsLoader.rawSkillContent(for: XCTUnwrap(loaded))?.contains("# Alpha"), true)

        let notFound = AgentSkillsLoader.resolveSkill(named: "Alpha Skill", workspaceRootURL: rootURL)
        XCTAssertNil(notFound)
    }

    func testPromptBuilderSeparatesRuntimeMemoryFromWorkspaceMemoryFiles() {
        let context = AgentContextLoader.LoadedContext(documents: [
            .init(fileName: "SOUL.md", content: "# Soul\nUse <calm> tone & stay direct."),
            .init(fileName: "USER.md", content: "# User\nPrefers Chinese."),
        ])

        let prompt = AgentPromptBuilder.composeSystemPrompt(
            baseSystemPrompt: nil,
            context: context,
            skillCatalog: [],
            memoryContext: "- Indexed durable memory",
            rootDirectory: nil
        )

        XCTAssertTrue(prompt.contains("Indexed durable memories:"))
        XCTAssertTrue(prompt.contains("<workspace-file name=\"SOUL.md\" purpose=\"Defines the agent&apos;s core personality and behavioral principles.\">"))
        XCTAssertTrue(prompt.contains("<workspace-file name=\"USER.md\" purpose=\"Defines user preferences, habits, and background information.\">"))
        XCTAssertTrue(prompt.contains("Use &lt;calm&gt; tone &amp; stay direct."))
        XCTAssertFalse(prompt.contains("### SOUL.md"))
        XCTAssertFalse(prompt.contains("### MEMORY.md"))
    }
}
