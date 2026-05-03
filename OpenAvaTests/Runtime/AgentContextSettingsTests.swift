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

    func testAgentSettingsDocumentKindsExcludeWorkspaceAgentsFile() {
        XCTAssertFalse(AgentContextDocumentKind.agentSettingsCases.contains(.agents))
        XCTAssertEqual(
            AgentContextDocumentKind.agentSettingsCases.map(\.fileName),
            ["HEARTBEAT.md", "SOUL.md", "TOOLS.md", "IDENTITY.md", "USER.md"]
        )
    }

    @MainActor
    func testContextSettingsViewModelDoesNotExposeWorkspaceAgentsFile() {
        let viewModel = ContextSettingsViewModel()

        XCTAssertNil(viewModel.document(for: .agents))
        XCTAssertFalse(viewModel.documents.contains(where: { $0.kind == .agents }))
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

    func testWorkspaceAgentsLoaderDiscoversGlobalAncestorProjectLocalRulesAndIncludes() throws {
        let tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("WorkspaceAgentsLoaderTests-\(UUID().uuidString)", isDirectory: true)
        let homeRoot = tempRoot.appendingPathComponent("home", isDirectory: true)
        let parentRoot = tempRoot.appendingPathComponent("parent", isDirectory: true)
        let projectRoot = parentRoot.appendingPathComponent("project", isDirectory: true)
        let sourceRoot = projectRoot.appendingPathComponent("Sources", isDirectory: true)
        let rulesRoot = projectRoot.appendingPathComponent(".rules", isDirectory: true)
        let hiddenAgentsRoot = projectRoot.appendingPathComponent(".agents", isDirectory: true)

        try FileManager.default.createDirectory(at: homeRoot.appendingPathComponent(".agents", isDirectory: true), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: sourceRoot, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: rulesRoot, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: hiddenAgentsRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        try "User global rule".write(
            to: homeRoot.appendingPathComponent(".agents/AGENTS.md"),
            atomically: true,
            encoding: .utf8
        )
        try "Parent rule".write(
            to: parentRoot.appendingPathComponent("AGENTS.md"),
            atomically: true,
            encoding: .utf8
        )
        try "Project rule\n@./included.md".write(
            to: projectRoot.appendingPathComponent("AGENTS.md"),
            atomically: true,
            encoding: .utf8
        )
        try "Included project rule".write(
            to: projectRoot.appendingPathComponent("included.md"),
            atomically: true,
            encoding: .utf8
        )
        try "Hidden project rule".write(
            to: hiddenAgentsRoot.appendingPathComponent("AGENTS.md"),
            atomically: true,
            encoding: .utf8
        )
        try "Local project rule".write(
            to: projectRoot.appendingPathComponent("AGENTS.local.md"),
            atomically: true,
            encoding: .utf8
        )
        try "public struct App {}".write(
            to: sourceRoot.appendingPathComponent("App.swift"),
            atomically: true,
            encoding: .utf8
        )
        try """
        ---
        paths:
          - Sources/**/*.swift
        ---
        Swift-specific rule
        """.write(
            to: rulesRoot.appendingPathComponent("swift.md"),
            atomically: true,
            encoding: .utf8
        )
        try """
        ---
        paths: Tests/**/*.swift
        ---
        Test-only rule
        """.write(
            to: rulesRoot.appendingPathComponent("tests.md"),
            atomically: true,
            encoding: .utf8
        )

        AgentContextLoader.clearWorkspaceAgentsCache()
        let context = try XCTUnwrap(
            AgentContextLoader.load(
                from: projectRoot,
                environment: ["HOME": homeRoot.path],
                fileManager: .default
            )
        )
        let loadedText = context.documents.map(\.content).joined(separator: "\n")

        XCTAssertTrue(loadedText.contains("User global rule"))
        XCTAssertTrue(loadedText.contains("Parent rule"))
        XCTAssertTrue(loadedText.contains("Project rule"))
        XCTAssertTrue(loadedText.contains("Included project rule"))
        XCTAssertTrue(loadedText.contains("Hidden project rule"))
        XCTAssertTrue(loadedText.contains("Local project rule"))
        XCTAssertTrue(loadedText.contains("Swift-specific rule"))
        XCTAssertFalse(loadedText.contains("Test-only rule"))
    }

    func testNestedWorkspaceAgentsLoaderIncludesTargetDirectoryButNotSiblings() throws {
        let tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("WorkspaceAgentsNestedTests-\(UUID().uuidString)", isDirectory: true)
        let workspaceRoot = tempRoot.appendingPathComponent("workspace", isDirectory: true)
        let featureRoot = workspaceRoot.appendingPathComponent("Sources/Feature", isDirectory: true)
        let siblingRoot = workspaceRoot.appendingPathComponent("Sources/Other", isDirectory: true)
        let targetURL = featureRoot.appendingPathComponent("View.swift", isDirectory: false)

        try FileManager.default.createDirectory(at: featureRoot, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: siblingRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        try "Workspace root rule".write(
            to: workspaceRoot.appendingPathComponent("AGENTS.md"),
            atomically: true,
            encoding: .utf8
        )
        try "Feature subdirectory rule".write(
            to: featureRoot.appendingPathComponent("AGENTS.md"),
            atomically: true,
            encoding: .utf8
        )
        try "Sibling subdirectory rule".write(
            to: siblingRoot.appendingPathComponent("AGENTS.md"),
            atomically: true,
            encoding: .utf8
        )
        try "struct View {}".write(to: targetURL, atomically: true, encoding: .utf8)

        let documents = AgentContextLoader.loadNestedWorkspaceAgentsDocuments(
            for: targetURL,
            workspaceRootURL: workspaceRoot,
            alreadyLoadedSourcePaths: [workspaceRoot.appendingPathComponent("AGENTS.md").standardizedFileURL.path],
            environment: [:],
            fileManager: .default
        )
        let loadedText = documents.map(\.content).joined(separator: "\n")

        XCTAssertFalse(loadedText.contains("Workspace root rule"))
        XCTAssertTrue(loadedText.contains("Feature subdirectory rule"))
        XCTAssertFalse(loadedText.contains("Sibling subdirectory rule"))
    }

    func testWorkspaceAgentsLoaderStripsBlockCommentsAndFrontmatter() throws {
        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("WorkspaceAgentsCommentTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: rootURL) }

        try """
        ---
        paths: **/*.swift
        ---
        <!-- hidden block comment -->
        Keep this rule <!-- keep inline comment text -->
        """.write(
            to: rootURL.appendingPathComponent("AGENTS.md"),
            atomically: true,
            encoding: .utf8
        )
        try "struct Example {}".write(
            to: rootURL.appendingPathComponent("Example.swift"),
            atomically: true,
            encoding: .utf8
        )

        AgentContextLoader.clearWorkspaceAgentsCache()
        let context = try XCTUnwrap(AgentContextLoader.load(from: rootURL, environment: [:], fileManager: .default))
        let agentsDocument = try XCTUnwrap(context.documents.first(where: { $0.fileName == "AGENTS.md" }))

        XCTAssertFalse(agentsDocument.content.contains("paths:"))
        XCTAssertFalse(agentsDocument.content.contains("hidden block comment"))
        XCTAssertTrue(agentsDocument.content.contains("Keep this rule <!-- keep inline comment text -->"))
    }

    func testWorkspaceAgentsLoaderPreventsRecursiveIncludeCycles() throws {
        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("WorkspaceAgentsCycleTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: rootURL) }

        try "Root rule\n@./a.md".write(to: rootURL.appendingPathComponent("AGENTS.md"), atomically: true, encoding: .utf8)
        try "A rule\n@./b.md".write(to: rootURL.appendingPathComponent("a.md"), atomically: true, encoding: .utf8)
        try "B rule\n@./a.md".write(to: rootURL.appendingPathComponent("b.md"), atomically: true, encoding: .utf8)

        AgentContextLoader.clearWorkspaceAgentsCache()
        let context = try XCTUnwrap(AgentContextLoader.load(from: rootURL, environment: [:], fileManager: .default))
        let contents = context.documents.map(\.content)

        XCTAssertEqual(contents.filter { $0.contains("A rule") }.count, 1)
        XCTAssertEqual(contents.filter { $0.contains("B rule") }.count, 1)
    }

    func testWorkspaceAgentsDocumentsAreInjectedIntoComposedSystemPrompt() throws {
        let tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("WorkspaceAgentsPromptTests-\(UUID().uuidString)", isDirectory: true)
        let workspaceRoot = tempRoot.appendingPathComponent("workspace", isDirectory: true)
        let homeRoot = tempRoot.appendingPathComponent("home", isDirectory: true)

        try FileManager.default.createDirectory(at: workspaceRoot, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: homeRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        try "Use workspace AGENTS rule & stay focused.\n@./extra.md".write(
            to: workspaceRoot.appendingPathComponent("AGENTS.md"),
            atomically: true,
            encoding: .utf8
        )
        try "Included prompt rule with <xml> safety.".write(
            to: workspaceRoot.appendingPathComponent("extra.md"),
            atomically: true,
            encoding: .utf8
        )

        AgentContextLoader.clearWorkspaceAgentsCache()
        let prompt = try XCTUnwrap(
            AgentContextLoader.composeSystemPrompt(
                baseSystemPrompt: nil,
                workspaceRootURL: workspaceRoot,
                environment: ["HOME": homeRoot.path],
                fileManager: .default
            )
        )

        XCTAssertTrue(prompt.contains("## Workspace Files (injected)"))
        XCTAssertTrue(prompt.contains("<workspace-file name=\"AGENTS.md\" purpose=\"Defines workspace rules, guardrails, and operating conventions.\">"))
        XCTAssertTrue(prompt.contains("Use workspace AGENTS rule &amp; stay focused."))
        XCTAssertTrue(prompt.contains("<workspace-file name=\"extra.md\" purpose=\"Provides workspace-specific instructions or reference material.\">"))
        XCTAssertTrue(prompt.contains("Included prompt rule with &lt;xml&gt; safety."))
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

    func testListSkillsIgnoresOpenAvaSupportSkills() throws {
        let workspaceRoot = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let skillName = "support-\(UUID().uuidString.lowercased())"
        let supportSkillURL = workspaceRoot
            .appendingPathComponent(AgentStore.openAvaDirectoryName, isDirectory: true)
            .appendingPathComponent("skills", isDirectory: true)
            .appendingPathComponent(skillName, isDirectory: true)

        try FileManager.default.createDirectory(at: workspaceRoot, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: supportSkillURL, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: workspaceRoot)
        }

        let content = """
        ---
        description: Support directory skill
        ---
        # Support Skill
        """
        try content.write(to: supportSkillURL.appendingPathComponent("SKILL.md"), atomically: true, encoding: .utf8)

        let skills = AgentSkillsLoader.listSkills(filterUnavailable: false, workspaceRootURL: workspaceRoot)

        XCTAssertNil(skills.first(where: { $0.name == skillName }))
    }

    func testListSkillsIncludesUserGlobalSkillsFromHomeAgentsDirectory() throws {
        let workspaceRoot = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let homeRoot = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let skillName = "global-\(UUID().uuidString.lowercased())"
        let globalSkillURL = homeRoot
            .appendingPathComponent(".agents", isDirectory: true)
            .appendingPathComponent("skills", isDirectory: true)
            .appendingPathComponent(skillName, isDirectory: true)

        try FileManager.default.createDirectory(at: workspaceRoot, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: globalSkillURL, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: workspaceRoot)
            try? FileManager.default.removeItem(at: homeRoot)
        }

        let content = """
        ---
        description: User global skill
        ---
        # Global Skill
        """
        try content.write(to: globalSkillURL.appendingPathComponent("SKILL.md"), atomically: true, encoding: .utf8)

        let skills = AgentSkillsLoader.listSkills(
            filterUnavailable: false,
            workspaceRootURL: workspaceRoot,
            environment: ["HOME": homeRoot.path]
        )
        let globalSkill = try XCTUnwrap(skills.first(where: { $0.name == skillName }))

        XCTAssertEqual(globalSkill.source, "global")
        XCTAssertEqual(globalSkill.description, "User global skill")
    }

    func testWorkspaceSkillsOverrideGlobalSkillsWithSameIdentifier() throws {
        let workspaceRoot = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let homeRoot = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let skillName = "global-collision-\(UUID().uuidString.lowercased())"
        let workspaceSkillURL = workspaceRoot
            .appendingPathComponent("skills", isDirectory: true)
            .appendingPathComponent(skillName, isDirectory: true)
        let globalSkillURL = homeRoot
            .appendingPathComponent(".agents", isDirectory: true)
            .appendingPathComponent("skills", isDirectory: true)
            .appendingPathComponent(skillName, isDirectory: true)

        try FileManager.default.createDirectory(at: workspaceSkillURL, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: globalSkillURL, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: workspaceRoot)
            try? FileManager.default.removeItem(at: homeRoot)
        }

        let workspaceContent = """
        ---
        description: Workspace wins global collision
        ---
        # Workspace Skill
        """
        let globalContent = """
        ---
        description: Global fallback
        ---
        # Global Skill
        """

        try workspaceContent.write(to: workspaceSkillURL.appendingPathComponent("SKILL.md"), atomically: true, encoding: .utf8)
        try globalContent.write(to: globalSkillURL.appendingPathComponent("SKILL.md"), atomically: true, encoding: .utf8)

        let skill = try XCTUnwrap(
            AgentSkillsLoader.resolveSkill(
                named: skillName,
                filterUnavailable: false,
                workspaceRootURL: workspaceRoot,
                environment: ["HOME": homeRoot.path]
            )
        )

        XCTAssertEqual(skill.source, "workspace")
        XCTAssertEqual(skill.description, "Workspace wins global collision")
    }

    func testWorkspaceSkillPathResolvesUnderProjectSkillsDirectory() throws {
        let workspaceRoot = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let skillName = "workspace-path-\(UUID().uuidString.lowercased())"
        let workspaceSkillURL = workspaceRoot
            .appendingPathComponent("skills", isDirectory: true)
            .appendingPathComponent(skillName, isDirectory: true)

        try FileManager.default.createDirectory(at: workspaceSkillURL, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: workspaceRoot)
        }

        let workspaceContent = """
        ---
        description: Workspace skill path
        ---
        # Workspace Skill
        """

        try workspaceContent.write(to: workspaceSkillURL.appendingPathComponent("SKILL.md"), atomically: true, encoding: .utf8)

        let skill = try XCTUnwrap(
            AgentSkillsLoader.resolveSkill(
                named: skillName,
                filterUnavailable: false,
                workspaceRootURL: workspaceRoot
            )
        )

        XCTAssertEqual(skill.source, "workspace")
        XCTAssertEqual(skill.description, "Workspace skill path")

        let resolvedSkillPath = URL(fileURLWithPath: skill.path).resolvingSymlinksInPath()
        let expectedSkillPath = workspaceSkillURL
            .appendingPathComponent("SKILL.md", isDirectory: false)
            .resolvingSymlinksInPath()

        XCTAssertEqual(resolvedSkillPath, expectedSkillPath)
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

        // The loader now correctly maps folder name "alpha" to its identifier,
        // while looking up by "name" metadata remains a separate search operation.
        let loaded = AgentSkillsLoader.resolveSkill(named: "alpha", workspaceRootURL: rootURL)
        XCTAssertNotNil(loaded)
    }

    func testPromptBuilderKeepsMemoryGuidanceSeparateFromWorkspaceFiles() {
        let context = AgentContextLoader.LoadedContext(documents: [
            .init(fileName: "SOUL.md", content: "# Soul\nUse <calm> tone & stay direct."),
            .init(fileName: "USER.md", content: "# User\nPrefers Chinese."),
        ])

        let prompt = AgentPromptBuilder.composeSystemPrompt(
            baseSystemPrompt: nil,
            context: context,
            skillCatalog: [],
            rootDirectory: nil
        )

        XCTAssertTrue(prompt.contains("Relevant memories may be recalled dynamically for the current request or fetched with memory tools when needed."))
        XCTAssertTrue(prompt.contains("When the task is primarily a summary, research synthesis, report, plan, or other deliverable that benefits from a reusable artifact, prefer creating a markdown file in the workspace instead of keeping the full deliverable only in chat."))
        XCTAssertTrue(prompt.contains("Decide whether to write a file based on usefulness for the current task; do not write files for every response by default."))
        XCTAssertTrue(prompt.contains("<workspace-file name=\"SOUL.md\" purpose=\"Defines the agent&apos;s core personality and behavioral principles.\">"))
        XCTAssertTrue(prompt.contains("<workspace-file name=\"USER.md\" purpose=\"Defines user preferences, habits, and background information.\">"))
        XCTAssertTrue(prompt.contains("Use &lt;calm&gt; tone &amp; stay direct."))
        XCTAssertFalse(prompt.contains("### SOUL.md"))
        XCTAssertFalse(prompt.contains("Indexed durable memories:"))
        XCTAssertFalse(prompt.contains("### MEMORY.md"))
    }
}
