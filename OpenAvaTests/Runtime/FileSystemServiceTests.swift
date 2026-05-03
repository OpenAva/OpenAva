import Foundation
import XCTest
@testable import OpenAva

final class FileSystemServiceTests: XCTestCase {
    private var workspaceURL: URL!
    private var service: FileSystemService!

    override func setUpWithError() throws {
        workspaceURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("FileSystemServiceTests")
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: workspaceURL, withIntermediateDirectories: true)
        service = FileSystemService(baseDirectoryURL: workspaceURL)
        try createFixtureTree()
    }

    override func tearDownWithError() throws {
        if let workspaceURL {
            try? FileManager.default.removeItem(at: workspaceURL)
        }
        workspaceURL = nil
        service = nil
    }

    func testFindFilesMatchesBasenameRecursively() async throws {
        let result = try await service.findFiles(glob: "*.swift")

        XCTAssertEqual(relativePaths(from: result.items), [
            "root.swift",
            "Sources/App/main.swift",
            "Sources/Feature/View.swift",
            "Sources/root.swift",
            "Tests/AppTests.swift",
        ])
    }

    func testFindFilesSupportsPathAwareDoubleStar() async throws {
        let result = try await service.findFiles(glob: "Sources/**/*.swift")

        XCTAssertEqual(relativePaths(from: result.items), [
            "Sources/App/main.swift",
            "Sources/Feature/View.swift",
            "Sources/root.swift",
        ])
    }

    func testFindFilesSupportsBraceExpansion() async throws {
        let result = try await service.findFiles(glob: "*.{swift,md}")

        XCTAssertEqual(relativePaths(from: result.items), [
            "README.md",
            "root.swift",
            "Sources/App/main.swift",
            "Sources/Feature/View.swift",
            "Sources/root.swift",
            "Tests/AppTests.swift",
        ])
    }

    func testFindFilesHonorsNonRecursiveSearch() async throws {
        let result = try await service.findFiles(glob: "*.swift", recursive: false)

        XCTAssertEqual(relativePaths(from: result.items), ["root.swift"])
    }

    func testReadFileRejectsAbsolutePathOutsideWorkspaceWithSharedPrefix() async throws {
        let parentURL = workspaceURL.deletingLastPathComponent()
        let outsideURL = parentURL
            .appendingPathComponent(workspaceURL.lastPathComponent + "-outside", isDirectory: true)
        try FileManager.default.createDirectory(at: outsideURL, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: outsideURL) }

        let outsideFileURL = outsideURL.appendingPathComponent("secret.txt")
        try "secret".write(to: outsideFileURL, atomically: true, encoding: .utf8)

        do {
            _ = try await service.readFile(path: outsideFileURL.path)
            XCTFail("Expected access denied error")
        } catch let error as FileSystemService.FileSystemError {
            guard case .accessDenied = error else {
                XCTFail("Expected accessDenied, got: \(error)")
                return
            }
        }
    }

    func testReadFileRejectsSymlinkEscapingWorkspace() async throws {
        let outsideURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("FileSystemServiceTestsOutside")
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: outsideURL, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: outsideURL) }

        let secretURL = outsideURL.appendingPathComponent("secret.txt")
        try "secret".write(to: secretURL, atomically: true, encoding: .utf8)

        let linkURL = workspaceURL.appendingPathComponent("escape", isDirectory: false)
        try FileManager.default.createSymbolicLink(at: linkURL, withDestinationURL: outsideURL)

        do {
            _ = try await service.readFile(path: "escape/secret.txt")
            XCTFail("Expected access denied error")
        } catch let error as FileSystemService.FileSystemError {
            guard case .accessDenied = error else {
                XCTFail("Expected accessDenied, got: \(error)")
                return
            }
        }
    }

    func testWriteFileRejectsSymlinkEscapingWorkspace() async throws {
        let outsideURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("FileSystemServiceTestsOutside")
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: outsideURL, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: outsideURL) }

        let linkURL = workspaceURL.appendingPathComponent("escape", isDirectory: false)
        try FileManager.default.createSymbolicLink(at: linkURL, withDestinationURL: outsideURL)

        do {
            _ = try await service.writeFile(path: "escape/leak.txt", content: "blocked")
            XCTFail("Expected access denied error")
        } catch let error as FileSystemService.FileSystemError {
            guard case .accessDenied = error else {
                XCTFail("Expected accessDenied, got: \(error)")
                return
            }
        }

        XCTAssertFalse(FileManager.default.fileExists(atPath: outsideURL.appendingPathComponent("leak.txt").path))
    }

    func testNestedWorkspaceAgentsPayloadIsInjectedOncePerSession() async throws {
        try writeFile("Sources/Feature/AGENTS.md", content: "Feature dynamic rule")
        try writeFile("Sources/Feature/Nested.swift", content: "struct Nested {}")

        let firstPayload = try await ToolRuntime.InvocationContext.$sessionID.withValue("nested-agents-session") {
            try await service.payloadWithNestedWorkspaceAgentsIfNeeded(
                "tool payload",
                targetPath: "Sources/Feature/Nested.swift"
            )
        }
        let secondPayload = try await ToolRuntime.InvocationContext.$sessionID.withValue("nested-agents-session") {
            try await service.payloadWithNestedWorkspaceAgentsIfNeeded(
                "tool payload",
                targetPath: "Sources/Feature/Nested.swift"
            )
        }

        XCTAssertTrue(firstPayload.contains("<workspace-files source=\"dynamic-agents\""), firstPayload)
        XCTAssertTrue(firstPayload.contains("Feature dynamic rule"), firstPayload)
        XCTAssertTrue(firstPayload.hasSuffix("tool payload"), firstPayload)
        XCTAssertFalse(secondPayload.contains("Feature dynamic rule"), secondPayload)
        XCTAssertEqual(secondPayload, "tool payload")
    }

    private func createFixtureTree() throws {
        try writeFile("root.swift")
        try writeFile("README.md")
        try writeFile("Sources/root.swift")
        try writeFile("Sources/App/main.swift")
        try writeFile("Sources/App/helper.ts")
        try writeFile("Sources/Feature/View.swift")
        try writeFile("Tests/AppTests.swift")
    }

    private func writeFile(_ relativePath: String, content: String = "fixture") throws {
        let fileURL = workspaceURL.appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try content.write(to: fileURL, atomically: true, encoding: .utf8)
    }

    private func relativePaths(from items: [DirectoryItem]) -> [String] {
        items.map { item in
            let itemURL = URL(fileURLWithPath: item.path).standardizedFileURL
            let basePath = workspaceURL.standardizedFileURL.path + "/"
            return String(itemURL.path.dropFirst(basePath.count))
        }
    }
}
