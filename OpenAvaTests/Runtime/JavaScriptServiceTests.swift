import OpenClawKit
import OpenClawProtocol
import XCTest
@testable import OpenAva

@MainActor
final class JavaScriptServiceTests: XCTestCase {
    func testJavaScriptExecuteHandlerRunsWorkspaceScriptFile() async throws {
        let workspaceURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("javascript-service-tests", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let scriptDirectory = workspaceURL.appendingPathComponent("scripts", isDirectory: true)
        let scriptURL = scriptDirectory.appendingPathComponent("sum.js", isDirectory: false)

        try FileManager.default.createDirectory(at: scriptDirectory, withIntermediateDirectories: true)
        try "#!/usr/bin/env node\nconst values = openava.input.values ?? [];\nreturn { total: values.reduce((sum, value) => sum + value, 0) };\n"
            .write(to: scriptURL, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: workspaceURL) }

        let service = JavaScriptService()
        var handlers: [String: ToolHandler] = [:]
        service.registerHandlers(into: &handlers, context: .init(workspaceRootURL: workspaceURL))

        let handler = try XCTUnwrap(handlers["javascript.execute"])
        let response = try await handler(
            BridgeInvokeRequest(
                id: "javascript-execute-script",
                command: "javascript.execute",
                paramsJSON: #"{"script_path":"scripts/sum.js","input":{"values":[1,2,3]}}"#
            )
        )

        XCTAssertTrue(response.ok)
        let payload = try decodedJSONObject(from: response)
        let result = try XCTUnwrap(payload["result"] as? [String: Any])
        XCTAssertEqual(result["total"] as? Int, 6)
    }

    func testJavaScriptExecuteHandlerRejectsScriptPathOutsideWorkspace() async throws {
        let rootDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("javascript-service-tests", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let workspaceURL = rootDirectory.appendingPathComponent("workspace", isDirectory: true)
        let outsideURL = rootDirectory.appendingPathComponent("outside.js", isDirectory: false)

        try FileManager.default.createDirectory(at: workspaceURL, withIntermediateDirectories: true)
        try "return 1;".write(to: outsideURL, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: rootDirectory) }

        let service = JavaScriptService()
        var handlers: [String: ToolHandler] = [:]
        service.registerHandlers(into: &handlers, context: .init(workspaceRootURL: workspaceURL))

        let handler = try XCTUnwrap(handlers["javascript.execute"])
        let response = try await handler(
            BridgeInvokeRequest(
                id: "javascript-execute-outside-workspace",
                command: "javascript.execute",
                paramsJSON: #"{"script_path":"../outside.js"}"#
            )
        )

        XCTAssertFalse(response.ok)
        XCTAssertEqual(response.error?.code, .invalidRequest)
        XCTAssertTrue(response.error?.message.contains("within the active workspace") == true)
    }

    func testExecuteReusesPersistentSessionWhenSourceURLIsProvided() async throws {
        let service = JavaScriptService()
        let request = JavaScriptService.Request(
            code: "openava.session.counter = (openava.session.counter ?? 0) + 1; return { counter: openava.session.counter };",
            sourceURL: URL(fileURLWithPath: "/tmp/counter.js"),
            input: nil,
            allowedTools: [],
            sessionID: "counter-session",
            timeoutMs: 1000
        )

        let first = try await service.execute(request: request) { _, _ in
            XCTFail("Unexpected nested tool call")
            return BridgeInvokeResponse(
                id: UUID().uuidString,
                ok: false,
                error: OpenClawNodeError(code: .unavailable, message: "UNAVAILABLE: unexpected nested tool call")
            )
        }
        let second = try await service.execute(request: request) { _, _ in
            XCTFail("Unexpected nested tool call")
            return BridgeInvokeResponse(
                id: UUID().uuidString,
                ok: false,
                error: OpenClawNodeError(code: .unavailable, message: "UNAVAILABLE: unexpected nested tool call")
            )
        }

        let firstPayload = try decodedJSONObject(from: first)
        let secondPayload = try decodedJSONObject(from: second)
        XCTAssertEqual((firstPayload["result"] as? [String: Any])?["counter"] as? Int, 1)
        XCTAssertEqual((secondPayload["result"] as? [String: Any])?["counter"] as? Int, 2)
    }

    private func decodedJSONObject(from response: BridgeInvokeResponse) throws -> [String: Any] {
        let payloadText = try XCTUnwrap(response.payload)
        return try decodedJSONObject(fromJSONText: payloadText)
    }

    private func decodedJSONObject(from payload: JavaScriptService.ExecutionPayload) throws -> [String: Any] {
        let payloadText = try ToolInvocationHelpers.encodePayload(payload)
        return try decodedJSONObject(fromJSONText: payloadText)
    }

    private func decodedJSONObject(fromJSONText text: String) throws -> [String: Any] {
        let data = try XCTUnwrap(text.data(using: .utf8))
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }
}
