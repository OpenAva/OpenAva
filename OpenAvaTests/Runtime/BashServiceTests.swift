import Darwin
import OpenClawKit
import XCTest
@testable import OpenAva

final class BashServiceTests: XCTestCase {
    #if os(macOS) || targetEnvironment(macCatalyst)
        func testBashExecuteHandlerRunsCommandInsideWorkspace() async throws {
            let workspaceURL = makeTemporaryDirectory(named: "bash-service-tests")
            defer { try? FileManager.default.removeItem(at: workspaceURL) }

            let service = BashService(workspaceRootURL: workspaceURL, supportRootURL: workspaceURL)
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

            let service = BashService(workspaceRootURL: workspaceURL, supportRootURL: workspaceURL)
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

            let service = BashService(workspaceRootURL: workspaceURL, supportRootURL: workspaceURL)
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

        func testBashExecuteHandlerRejectsSymlinkEscapingWorkspace() async throws {
            let workspaceURL = makeTemporaryDirectory(named: "bash-service-tests")
            let outsideURL = makeTemporaryDirectory(named: "bash-service-outside")
            let linkURL = workspaceURL.appendingPathComponent("escape", isDirectory: false)
            try FileManager.default.createSymbolicLink(at: linkURL, withDestinationURL: outsideURL)
            defer {
                try? FileManager.default.removeItem(at: workspaceURL)
                try? FileManager.default.removeItem(at: outsideURL)
            }

            let service = BashService(workspaceRootURL: workspaceURL, supportRootURL: workspaceURL)
            var handlers: [String: ToolHandler] = [:]
            service.registerHandlers(into: &handlers, context: .init(workspaceRootURL: workspaceURL))

            let handler = try XCTUnwrap(handlers["bash.execute"])
            let response = try await handler(
                BridgeInvokeRequest(
                    id: "bash-cd-symlink-outside",
                    command: "bash.execute",
                    paramsJSON: #"{"command":"cd escape && pwd"}"#
                )
            )

            XCTAssertFalse(response.ok)
            XCTAssertEqual(response.error?.code, .invalidRequest)
            XCTAssertTrue(response.error?.message.contains("within the active workspace") == true)
        }

        func testBashExecuteHandlerRejectsDangerousEnvironmentAssignments() async throws {
            let workspaceURL = makeTemporaryDirectory(named: "bash-service-tests")
            defer { try? FileManager.default.removeItem(at: workspaceURL) }

            let service = BashService(workspaceRootURL: workspaceURL, supportRootURL: workspaceURL)
            var handlers: [String: ToolHandler] = [:]
            service.registerHandlers(into: &handlers, context: .init(workspaceRootURL: workspaceURL))

            let handler = try XCTUnwrap(handlers["bash.execute"])
            let response = try await handler(
                BridgeInvokeRequest(
                    id: "bash-dangerous-env",
                    command: "bash.execute",
                    paramsJSON: #"{"command":"LD_PRELOAD=/tmp/evil.dylib pwd"}"#
                )
            )

            XCTAssertFalse(response.ok)
            XCTAssertEqual(response.error?.code, .invalidRequest)
            XCTAssertTrue(response.error?.message.contains("environment variable assignment") == true)
        }

        func testBashExecuteHandlerRejectsSedHighRiskFlags() async throws {
            let workspaceURL = makeTemporaryDirectory(named: "bash-service-tests")
            defer { try? FileManager.default.removeItem(at: workspaceURL) }

            let service = BashService(workspaceRootURL: workspaceURL, supportRootURL: workspaceURL)
            var handlers: [String: ToolHandler] = [:]
            service.registerHandlers(into: &handlers, context: .init(workspaceRootURL: workspaceURL))

            let handler = try XCTUnwrap(handlers["bash.execute"])
            let inPlaceResponse = try await handler(
                BridgeInvokeRequest(
                    id: "bash-sed-in-place",
                    command: "bash.execute",
                    paramsJSON: #"{"command":"sed -i '' 's/a/b/' test.txt"}"#
                )
            )

            XCTAssertFalse(inPlaceResponse.ok)
            XCTAssertEqual(inPlaceResponse.error?.code, .invalidRequest)
            XCTAssertTrue(inPlaceResponse.error?.message.contains("in-place") == true)

            let executeFlagResponse = try await handler(
                BridgeInvokeRequest(
                    id: "bash-sed-exec-flag",
                    command: "bash.execute",
                    paramsJSON: #"{"command":"sed -e 's/a/b/e' test.txt"}"#
                )
            )

            XCTAssertFalse(executeFlagResponse.ok)
            XCTAssertEqual(executeFlagResponse.error?.code, .invalidRequest)
            XCTAssertTrue(executeFlagResponse.error?.message.contains("restricted expression") == true)
        }

        func testBashExecuteHandlerRejectsOverlyComplexCommands() async throws {
            let workspaceURL = makeTemporaryDirectory(named: "bash-service-tests")
            defer { try? FileManager.default.removeItem(at: workspaceURL) }

            let service = BashService(workspaceRootURL: workspaceURL, supportRootURL: workspaceURL)
            var handlers: [String: ToolHandler] = [:]
            service.registerHandlers(into: &handlers, context: .init(workspaceRootURL: workspaceURL))

            let handler = try XCTUnwrap(handlers["bash.execute"])
            let repeatedTrue = Array(repeating: "true", count: 55).joined(separator: " && ")
            let response = try await handler(
                BridgeInvokeRequest(
                    id: "bash-too-complex",
                    command: "bash.execute",
                    paramsJSON: #"{"command":"\#(repeatedTrue)"}"#
                )
            )

            XCTAssertFalse(response.ok)
            XCTAssertEqual(response.error?.code, .invalidRequest)
            XCTAssertTrue(response.error?.message.contains("too complex") == true)
        }

        func testBashExecuteHandlerAddsUserNodeBinsToPath() async throws {
            let workspaceURL = makeTemporaryDirectory(named: "bash-service-tests")
            let homeURL = makeTemporaryDirectory(named: "bash-service-home")
            defer {
                try? FileManager.default.removeItem(at: workspaceURL)
                try? FileManager.default.removeItem(at: homeURL)
            }

            let fakeBinURL = homeURL
                .appendingPathComponent(".nvm", isDirectory: true)
                .appendingPathComponent("versions", isDirectory: true)
                .appendingPathComponent("node", isDirectory: true)
                .appendingPathComponent("v22.22.2", isDirectory: true)
                .appendingPathComponent("bin", isDirectory: true)
            try FileManager.default.createDirectory(at: fakeBinURL, withIntermediateDirectories: true)
            let fakeToolURL = fakeBinURL.appendingPathComponent("openava-fake-node-cli", isDirectory: false)
            try "#!/bin/sh\nprintf fake-node-cli".write(to: fakeToolURL, atomically: true, encoding: .utf8)
            chmod(fakeToolURL.path, 0o755)

            let service = BashService(
                workspaceRootURL: workspaceURL,
                supportRootURL: workspaceURL,
                environmentProvider: {
                    [
                        "HOME": homeURL.path,
                        "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
                        "SHELL": "/bin/zsh",
                    ]
                },
                homeDirectoryURL: homeURL
            )
            var handlers: [String: ToolHandler] = [:]
            service.registerHandlers(into: &handlers, context: .init(workspaceRootURL: workspaceURL))

            let handler = try XCTUnwrap(handlers["bash.execute"])
            let response = try await handler(
                BridgeInvokeRequest(
                    id: "bash-user-node-bin",
                    command: "bash.execute",
                    paramsJSON: #"{"command":"openava-fake-node-cli"}"#
                )
            )

            XCTAssertTrue(response.ok)
            let payloadText = try payloadText(from: response)
            XCTAssertTrue(payloadText.contains("- status: completed"))
            XCTAssertTrue(payloadText.contains("- exit_code: 0"))
            XCTAssertTrue(payloadText.contains("fake-node-cli"))
        }

        func testBashExecuteHandlerLoadsShellSnapshotAliasesAndFunctions() async throws {
            let workspaceURL = makeTemporaryDirectory(named: "bash-service-tests")
            let homeURL = makeTemporaryDirectory(named: "bash-service-home")
            defer {
                try? FileManager.default.removeItem(at: workspaceURL)
                try? FileManager.default.removeItem(at: homeURL)
            }

            let zshrcURL = homeURL.appendingPathComponent(".zshrc", isDirectory: false)
            try """
            alias openava_snapshot_alias='printf alias-from-snapshot'
            openava_snapshot_function() { printf function-from-snapshot; }
            """.write(to: zshrcURL, atomically: true, encoding: .utf8)

            let service = BashService(
                workspaceRootURL: workspaceURL,
                supportRootURL: workspaceURL,
                environmentProvider: {
                    [
                        "HOME": homeURL.path,
                        "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
                        "SHELL": "/bin/zsh",
                    ]
                },
                homeDirectoryURL: homeURL
            )
            var handlers: [String: ToolHandler] = [:]
            service.registerHandlers(into: &handlers, context: .init(workspaceRootURL: workspaceURL))

            let handler = try XCTUnwrap(handlers["bash.execute"])
            let response = try await handler(
                BridgeInvokeRequest(
                    id: "bash-shell-snapshot",
                    command: "bash.execute",
                    paramsJSON: #"{"command":"openava_snapshot_alias && openava_snapshot_function"}"#
                )
            )

            XCTAssertTrue(response.ok)
            let payloadText = try payloadText(from: response)
            XCTAssertTrue(payloadText.contains("- status: completed"))
            XCTAssertTrue(payloadText.contains("- exit_code: 0"))
            XCTAssertTrue(payloadText.contains("alias-from-snapshot"))
            XCTAssertTrue(payloadText.contains("function-from-snapshot"))
        }

        func testBashExecuteHandlerSupportsBackgroundExecution() async throws {
            let workspaceURL = makeTemporaryDirectory(named: "bash-service-tests")
            defer { try? FileManager.default.removeItem(at: workspaceURL) }

            let service = BashService(workspaceRootURL: workspaceURL, supportRootURL: workspaceURL)
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
