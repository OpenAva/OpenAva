import ChatClient
import Foundation

actor AgentMemoryContextBuilder {
    struct SelectedContext: Equatable {
        let query: String
        let entries: [AgentMemoryStore.Entry]
        let usedModelSelection: Bool
    }

    typealias Selector = @Sendable (_ query: String, _ manifest: String, _ recentTools: [String]) async -> [String]?

    private enum Config {
        static let maxQueryCharacters = 320
        static let maxSelectedMemories = 5
        static let maxFallbackHits = 3
        static let maxContentCharacters = 280
        static let maxManifestContentCharacters = 120
        static let maxRecentTools = 8
        static let selectionMaxCompletionTokens = 256
    }

    private struct SelectionResponse: Decodable {
        let selected_memories: [String]
    }

    private let supportRootURL: URL
    private let modelConfig: AppConfig.LLMModel?
    private let selector: Selector?

    init(
        supportRootURL: URL,
        modelConfig: AppConfig.LLMModel? = nil,
        selector: Selector? = nil
    ) {
        self.supportRootURL = supportRootURL.standardizedFileURL
        self.modelConfig = modelConfig
        self.selector = selector
    }

    func selectedContext(
        query: String,
        recentTools: [String] = [],
        alreadySurfacedSlugs: Set<String> = []
    ) async -> SelectedContext? {
        let normalizedQuery = Self.normalizedQuery(query)
        guard !normalizedQuery.isEmpty else { return nil }

        let store = AgentMemoryStore(supportRootURL: supportRootURL)
        let candidates = ((try? await store.listEntries()) ?? []).filter {
            !alreadySurfacedSlugs.contains($0.slug)
        }
        guard !candidates.isEmpty else { return nil }

        let normalizedRecentTools = Self.normalizedRecentTools(recentTools)
        if let selectedEntries = await selectedEntriesUsingModel(
            query: normalizedQuery,
            candidates: candidates,
            recentTools: normalizedRecentTools
        ) {
            guard !selectedEntries.isEmpty else { return nil }
            return SelectedContext(
                query: normalizedQuery,
                entries: selectedEntries,
                usedModelSelection: true
            )
        }

        let fallbackEntries = ((try? await store.recall(query: normalizedQuery, limit: Config.maxFallbackHits * 3)) ?? [])
            .filter { !alreadySurfacedSlugs.contains($0.slug) }
            .prefix(Config.maxFallbackHits)
            .map { $0 }
        guard !fallbackEntries.isEmpty else { return nil }
        return SelectedContext(
            query: normalizedQuery,
            entries: fallbackEntries,
            usedModelSelection: false
        )
    }

    func contextSection(
        query: String,
        recentTools: [String] = [],
        alreadySurfacedSlugs: Set<String> = []
    ) async -> String? {
        guard let context = await selectedContext(
            query: query,
            recentTools: recentTools,
            alreadySurfacedSlugs: alreadySurfacedSlugs
        ) else {
            return nil
        }
        return Self.renderSection(context)
    }

    private func selectedEntriesUsingModel(
        query: String,
        candidates: [AgentMemoryStore.Entry],
        recentTools: [String]
    ) async -> [AgentMemoryStore.Entry]? {
        let manifest = Self.memoryManifest(from: candidates)
        guard !manifest.isEmpty else { return [] }

        let selectedFilenames: [String]?
        if let selector {
            selectedFilenames = await selector(query, manifest, recentTools)
        } else {
            selectedFilenames = await selectRelevantFilenames(
                query: query,
                manifest: manifest,
                validFilenames: Set(candidates.map { $0.fileURL.lastPathComponent }),
                recentTools: recentTools
            )
        }

        guard let selectedFilenames else {
            return nil
        }

        let entriesByFilename = Dictionary(
            uniqueKeysWithValues: candidates.map { ($0.fileURL.lastPathComponent, $0) }
        )
        let selectedEntries = selectedFilenames.compactMap { entriesByFilename[$0] }
        return Array(selectedEntries.prefix(Config.maxSelectedMemories))
    }

    private func selectRelevantFilenames(
        query: String,
        manifest: String,
        validFilenames: Set<String>,
        recentTools: [String]
    ) async -> [String]? {
        guard let modelConfig, modelConfig.isConfigured else {
            return nil
        }

        let client = LLMChatClient(modelConfig: modelConfig)
        let toolsSection = recentTools.isEmpty
            ? ""
            : "\n\nRecently used tools: \(recentTools.joined(separator: ", "))"
        let userPrompt = """
        Query: \(query)

        Available memories:
        \(manifest)\(toolsSection)
        """

        do {
            let response = try await client.chat(
                body: ChatRequestBody(
                    messages: [
                        .system(content: .text(Self.selectionSystemPrompt)),
                        .user(content: .text(userPrompt)),
                    ],
                    maxCompletionTokens: Config.selectionMaxCompletionTokens,
                    stream: false,
                    temperature: 0
                )
            )
            return Self.parseSelectionResponse(response.text, validFilenames: validFilenames)
        } catch {
            return nil
        }
    }

    private static var selectionSystemPrompt: String {
        """
        You are selecting memories that will be useful to OpenAva as it processes a user's query. You will be given the user's query and a list of available memory files with their filenames and descriptions.

        Return JSON only using this schema:
        {
          "selected_memories": ["filename.md"]
        }

        Rules:
        - Return up to 5 filenames for memories that will clearly be useful while processing the user's query.
        - Only include memories you are certain will help based on filename, name, type, and description.
        - If you are unsure whether a memory is useful, do not include it.
        - If none of the memories are clearly useful, return {"selected_memories":[]}.
        - If recently used tools are provided, do not select usage references or API documentation for those tools just because they overlap in keywords.
        - Still select memories containing warnings, gotchas, or known issues related to actively used tools when they are clearly relevant.
        """
    }

    private static func parseSelectionResponse(_ raw: String, validFilenames: Set<String>) -> [String]? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let data = trimmed.data(using: .utf8),
              let decoded = try? JSONDecoder().decode(SelectionResponse.self, from: data)
        else {
            return nil
        }

        let filtered = decoded.selected_memories.filter { validFilenames.contains($0) }
        if !decoded.selected_memories.isEmpty, filtered.isEmpty {
            return nil
        }

        var seen = Set<String>()
        return filtered.filter { seen.insert($0).inserted }
    }

    private static func memoryManifest(from entries: [AgentMemoryStore.Entry]) -> String {
        guard !entries.isEmpty else { return "" }
        return entries.map { entry in
            let filename = entry.fileURL.lastPathComponent
            return "- filename=\(filename) | type=\(entry.type.rawValue) | slug=\(entry.slug) | version=\(entry.version) | name=\(singleLine(entry.name)) | description=\(singleLine(entry.description)) | content=\(manifestExcerpt(for: entry.content))"
        }.joined(separator: "\n")
    }

    private static func manifestExcerpt(for content: String) -> String {
        truncated(singleLine(content), limit: Config.maxManifestContentCharacters)
    }

    private static func renderSection(_ context: SelectedContext) -> String {
        let lines = context.entries.map { entry -> String in
            let excerpt = truncated(singleLine(entry.content), limit: Config.maxContentCharacters)
            return """
            - [\(entry.type.rawValue)] \(entry.name) (slug=\(entry.slug), version=\(entry.version))
              - description: \(entry.description)
              - content: \(excerpt)
            """
        }

        return """
        ## Dynamic Memory Recall
        Current request query: \(context.query)

        Relevant active durable memories:
        \(lines.joined(separator: "\n"))
        """
    }

    private static func normalizedQuery(_ raw: String) -> String {
        let collapsed = raw
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return truncated(collapsed, limit: Config.maxQueryCharacters)
    }

    private static func normalizedRecentTools(_ tools: [String]) -> [String] {
        var seen = Set<String>()
        return tools
            .map(singleLine)
            .filter { !$0.isEmpty }
            .filter { seen.insert($0).inserted }
            .prefix(Config.maxRecentTools)
            .map { $0 }
    }

    private static func truncated(_ raw: String, limit: Int) -> String {
        guard raw.count > limit else { return raw }
        let endIndex = raw.index(raw.startIndex, offsetBy: limit)
        return String(raw[..<endIndex]) + "…"
    }

    private static func singleLine(_ raw: String) -> String {
        raw
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
