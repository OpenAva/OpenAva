import XCTest
@testable import OpenAva

final class ToolDefinitionSemanticsTests: XCTestCase {
    func testFileSystemDefinitionsExposeReadOnlyAndMutableSemantics() async {
        let definitions = await FileSystemService().toolDefinitions()
        let byName = Dictionary(uniqueKeysWithValues: definitions.map { ($0.functionName, $0) })

        XCTAssertEqual(byName["fs_read"]?.isReadOnly, true)
        XCTAssertEqual(byName["fs_read"]?.isConcurrencySafe, true)
        XCTAssertEqual(byName["fs_read"]?.maxResultSizeChars, 48 * 1024)

        XCTAssertEqual(byName["fs_write"]?.isReadOnly, false)
        XCTAssertEqual(byName["fs_write"]?.isDestructive, true)
        XCTAssertEqual(byName["fs_write"]?.isConcurrencySafe, false)

        XCTAssertEqual(byName["fs_grep"]?.isReadOnly, true)
        XCTAssertEqual(byName["fs_grep"]?.isConcurrencySafe, true)
        XCTAssertEqual(byName["fs_grep"]?.maxResultSizeChars, 24 * 1024)
    }

    func testExplicitSemanticsAreUsedDirectly() {
        let weather = ToolDefinition(
            functionName: "weather_get",
            command: "weather.get",
            description: "",
            parametersSchema: .init([:] as [String: Any]),
            isReadOnly: true,
            isConcurrencySafe: true
        )
        XCTAssertTrue(weather.isReadOnly)
        XCTAssertTrue(weather.isConcurrencySafe)
        XCTAssertFalse(weather.isDestructive)

        let memoryForget = ToolDefinition(
            functionName: "memory_forget",
            command: "memory.forget",
            description: "",
            parametersSchema: .init([:] as [String: Any]),
            isReadOnly: false,
            isDestructive: true,
            isConcurrencySafe: false
        )
        XCTAssertFalse(memoryForget.isReadOnly)
        XCTAssertTrue(memoryForget.isDestructive)
        XCTAssertFalse(memoryForget.isConcurrencySafe)
    }

    func testMemoryDefinitionsExposeClaudeStyleSemantics() {
        let definitions = MemoryToolDefinitions().toolDefinitions()
        let byName = Dictionary(uniqueKeysWithValues: definitions.map { ($0.functionName, $0) })

        XCTAssertEqual(byName["memory_recall"]?.isReadOnly, true)
        XCTAssertEqual(byName["memory_recall"]?.isConcurrencySafe, true)
        XCTAssertEqual(byName["memory_transcript_search"]?.isReadOnly, true)
        XCTAssertEqual(byName["memory_upsert"]?.isDestructive, true)
        XCTAssertEqual(byName["memory_forget"]?.isDestructive, true)
    }

    func testToolRegistryDefinitionLookupPreservesMetadata() async {
        final class TestProvider: ToolDefinitionProvider {
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
            XCTAssertEqual(definition?.isReadOnly, true)
            XCTAssertEqual(definition?.isDestructive, false)
            XCTAssertEqual(definition?.isConcurrencySafe, true)
            XCTAssertEqual(definition?.maxResultSizeChars, 1024)
        }

        await registry.clear()
    }
}
