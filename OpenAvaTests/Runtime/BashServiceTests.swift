import OpenClawKit
import XCTest
@testable import OpenAva

final class BashServiceTests: XCTestCase {
    #if os(macOS) || targetEnvironment(macCatalyst)
        func testBashExecuteHandlerRunsCommandInsideWorkspace() async throws {
            let workspaceURL = makeTemporaryDirectory(named: "bash-service-tests")
            defer { try? FileManager.default.removeItem(at: workspaceURL) }

            let service = BashService(workspaceRootURL: workspaceURL, runtimeRootURL: workspaceURL)
            var handlers: [String: ToolHandler] = [:]
            service.registerHandlers(into: &handlers, context: .init(workspaceRootURL: workspaceURL))

            let handler = try XCTUnwrap(handlers["bash.execute"])
            let response = try await handler(
                BridgeInvokeRequest(
                    id: "bash-pwd",
                    command: "bash.execute",
                    paramsJSON: #"{"command":"pwd"}"#
                )
            )

            XCTAssertTrue(response.ok)
            let payloadText = try payloadText(from: response)
            XCTAssertTrue(payloadText.contains("## Bash"))
            XCTAssertTrue(payloadText.contains("- command: pwd"))
            XCTAssertTrue(payloadText.contains("- cwd: \(workspaceURL.path)"))
            XCTAssertTrue(payloadText.contains("- status: completed"))
            XCTAssertTrue(payloadText.contains("- exit_code: 0"))
            XCTAssertTrue(payloadText.contains("### Stdout"))
            XCTAssertTrue(payloadText.contains(workspaceURL.path))
            XCTAssertNil(fieldValue("background_task_id", in: payloadText))
        }

        func testBashExecuteHandlerSupportsSingleLeadingWorkspaceCd() async throws {
            let workspaceURL = makeTemporaryDirectory(named: "bash-service-tests")
            let nestedURL = workspaceURL.appendingPathComponent("scripts", isDirectory: true)
            try FileManager.default.createDirectory(at: nestedURL, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: workspaceURL) }

            let service = BashService(workspaceRootURL: workspaceURL, runtimeRootURL: workspaceURL)
            var handlers: [String: ToolHandler] = [:]
            service.registerHandlers(into: &handlers, context: .init(workspaceRootURL: workspaceURL))

            let handler = try XCTUnwrap(handlers["bash.execute"])
            let response = try await handler(
                BridgeInvokeRequest(
                    id: "bash-cd-pwd",
                    command: "bash.execute",
                    paramsJSON: #"{"command":"cd scripts && pwd"}"#
                )
            )

            XCTAssertTrue(response.ok)
            let payloadText = try payloadText(from: response)
            XCTAssertTrue(payloadText.contains("- command: cd scripts && pwd"))
            XCTAssertTrue(payloadText.contains("- cwd: \(nestedURL.path)"))
            XCTAssertTrue(payloadText.contains("- status: completed"))
            XCTAssertTrue(payloadText.contains("- exit_code: 0"))
            XCTAssertTrue(payloadText.contains(nestedURL.path))
        }

        func testBashExecuteHandlerRejectsCdOutsideWorkspace() async throws {
            let workspaceURL = makeTemporaryDirectory(named: "bash-service-tests")
            defer { try? FileManager.default.removeItem(at: workspaceURL) }

            let service = BashService(workspaceRootURL: workspaceURL, runtimeRootURL: workspaceURL)
            var handlers: [String: ToolHandler] = [:]
            service.registerHandlers(into: &handlers, context: .init(workspaceRootURL: workspaceURL))

            let handler = try XCTUnwrap(handlers["bash.execute"])
            let response = try await handler(
                BridgeInvokeRequest(
                    id: "bash-cd-outside",
                    command: "bash.execute",
                    paramsJSON: #"{"command":"cd .. && pwd"}"#
                )
            )

            XCTAssertFalse(response.ok)
            XCTAssertEqual(response.error?.code, .invalidRequest)
            XCTAssertTrue(response.error?.message.contains("within the active workspace") == true)
        }

        func testBashExecuteHandlerSupportsBackgroundExecution() async throws {
            let workspaceURL = makeTemporaryDirectory(named: "bash-service-tests")
            defer { try? FileManager.default.removeItem(at: workspaceURL) }

            let service = BashService(workspaceRootURL: workspaceURL, runtimeRootURL: workspaceURL)
            var handlers: [String: ToolHandler] = [:]
            service.registerHandlers(into: &handlers, context: .init(workspaceRootURL: workspaceURL))

            let handler = try XCTUnwrap(handlers["bash.execute"])
            let response = try await handler(
                BridgeInvokeRequest(
                    id: "bash-background",
                    command: "bash.execute",
                    paramsJSON: #"{"command":"sleep 0.2; printf done","run_in_background":true}"#
                )
            )

            XCTAssertTrue(response.ok)
            let payloadText = try payloadText(from: response)
            XCTAssertTrue(payloadText.contains("- status: started_in_background"))
            let outputPath = try XCTUnwrap(fieldValue("output_path", in: payloadText))
            let metadataPath = try XCTUnwrap(fieldValue("metadata_path", in: payloadText))
            let backgroundTaskID = try XCTUnwrap(fieldValue("background_task_id", in: payloadText))
            XCTAssertFalse(backgroundTaskID.isEmpty)

            try await waitUntilBackgroundTaskCompletes(metadataPath: metadataPath)
            let outputText = try String(contentsOfFile: outputPath, encoding: .utf8)
            XCTAssertTrue(outputText.contains("done"))
        }
    #else
        func testBashToolIsHiddenOnUnsupportedPlatforms() {
            let definitions = BashService().toolDefinitions()
            XCTAssertTrue(definitions.isEmpty)
        }
    #endif

    private func makeTemporaryDirectory(named name: String) -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(name, isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func payloadText(from response: BridgeInvokeResponse) throws -> String {
        try XCTUnwrap(response.payload)
    }

    private func fieldValue(_ field: String, in payloadText: String) -> String? {
        let prefix = "- \(field): "
        for rawLine in payloadText.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(rawLine)
            if line.hasPrefix(prefix) {
                return String(line.dropFirst(prefix.count))
            }
        }
        return nil
    }

    #if os(macOS) || targetEnvironment(macCatalyst)
        private func waitUntilBackgroundTaskCompletes(metadataPath: String) async throws {
            let deadline = Date().addingTimeInterval(5)
            while Date() < deadline {
                if let data = FileManager.default.contents(atPath: metadataPath),
                   let record = try? JSONDecoder().decode(BashBackgroundRecord.self, from: data),
                   record.status != "running"
                {
                    return
                }
                try await Task.sleep(nanoseconds: 100_000_000)
            }
            XCTFail("Timed out waiting for background bash task to finish")
        }

        private struct BashBackgroundRecord: Decodable {
            let status: String
        }
    #endif
}
