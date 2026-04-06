import XCTest
@testable import OpenAva

final class ToolDefinitionSemanticsTests: XCTestCase {
    func testFileSystemDefinitionsExposeReadOnlyAndMutableSemantics() async {
        let definitions = await FileSystemService().toolDefinitions()
        let byName = Dictionary(uniqueKeysWithValues: definitions.map { ($0.functionName, $0) })

        XCTAssertEqual(byName["fs_read"]?.isReadOnly, true)
        XCTAssertEqual(byName["fs_read"]?.resolvedIsConcurrencySafe, true)
        XCTAssertEqual(byName["fs_read"]?.maxResultSizeChars, 48 * 1024)

        XCTAssertEqual(byName["fs_write"]?.isReadOnly, false)
        XCTAssertEqual(byName["fs_write"]?.isDestructive, true)
        XCTAssertEqual(byName["fs_write"]?.resolvedIsConcurrencySafe, false)

        XCTAssertEqual(byName["fs_grep"]?.isReadOnly, true)
        XCTAssertEqual(byName["fs_grep"]?.resolvedIsConcurrencySafe, true)
        XCTAssertEqual(byName["fs_grep"]?.maxResultSizeChars, 24 * 1024)
    }

    func testFallbackSemanticsCoverKnownCommands() {
        let weather = ToolDefinition(
            functionName: "weather_get",
            command: "weather.get",
            description: "",
            parametersSchema: .init([:] as [String: Any])
        )
        XCTAssertTrue(weather.resolvedIsReadOnly)
        XCTAssertTrue(weather.resolvedIsConcurrencySafe)
        XCTAssertFalse(weather.resolvedIsDestructive)

        let memoryForget = ToolDefinition(
            functionName: "memory_forget",
            command: "memory.forget",
            description: "",
            parametersSchema: .init([:] as [String: Any]),
            isReadOnly: false,
            isDestructive: true,
            isConcurrencySafe: false
        )
        XCTAssertFalse(memoryForget.resolvedIsReadOnly)
        XCTAssertTrue(memoryForget.resolvedIsDestructive)
        XCTAssertFalse(memoryForget.resolvedIsConcurrencySafe)
    }

    func testMemoryDefinitionsExposeClaudeStyleSemantics() {
        let definitions = MemoryToolDefinitions().toolDefinitions()
        let byName = Dictionary(uniqueKeysWithValues: definitions.map { ($0.functionName, $0) })

        XCTAssertEqual(byName["memory_recall"]?.resolvedIsReadOnly, true)
        XCTAssertEqual(byName["memory_recall"]?.resolvedIsConcurrencySafe, true)
        XCTAssertEqual(byName["memory_transcript_search"]?.resolvedIsReadOnly, true)
        XCTAssertEqual(byName["memory_upsert"]?.resolvedIsDestructive, true)
        XCTAssertEqual(byName["memory_forget"]?.resolvedIsDestructive, true)
    }

    func testToolRegistryDefinitionLookupPreservesMetadata() async {
        struct TestProvider: ToolDefinitionProvider {
            func toolDefinitions() -> [ToolDefinition] {
                [
                    ToolDefinition(
                        functionName: "tool_test",
                        command: "tool.test",
                        description: "",
                        parametersSchema: .init([:] as [String: Any]),
                        isReadOnly: true,
                        isDestructive: false,
                        isConcurrencySafe: true,
                        maxResultSizeChars: 1024
                    ),
                ]
            }
        }

        let registry = ToolRegistry.shared
        await registry.clear()

        await registry.register(provider: TestProvider())

        let definition = await registry.definition(forFunctionName: "tool_test")
        await MainActor.run {
            XCTAssertEqual(definition?.command, "tool.test")
            XCTAssertEqual(definition?.resolvedIsReadOnly, true)
            XCTAssertEqual(definition?.resolvedIsDestructive, false)
            XCTAssertEqual(definition?.resolvedIsConcurrencySafe, true)
            XCTAssertEqual(definition?.maxResultSizeChars, 1024)
        }

        await registry.clear()
    }
}
