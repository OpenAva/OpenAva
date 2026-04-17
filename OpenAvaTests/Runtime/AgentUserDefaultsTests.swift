import Foundation
import XCTest
@testable import OpenAva

final class AgentUserDefaultsTests: XCTestCase {
    func testLoadReturnsSavedUser() throws {
        let workspaceURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: workspaceURL, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: workspaceURL) }

        AgentUserDefaults.save(
            callName: "  Yuan  ",
            context: "  iOS 开发与 AI 自动化  ",
            directoryURL: workspaceURL
        )

        let value = AgentUserDefaults.load(directoryURL: workspaceURL)
        XCTAssertEqual(value?.callName, "Yuan")
        XCTAssertEqual(value?.context, "iOS 开发与 AI 自动化")

        let persistedText = try String(
            contentsOf: workspaceURL.appendingPathComponent(".openava.json", isDirectory: false),
            encoding: .utf8
        )
        XCTAssertTrue(persistedText.contains("\"user\""))
        let jsonFiles = try FileManager.default.contentsOfDirectory(atPath: workspaceURL.path)
            .filter { $0.hasSuffix(".json") }
            .sorted()
        XCTAssertEqual(jsonFiles, [".openava.json"])
    }

    func testSaveRemovesValueWhenEmpty() throws {
        let workspaceURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: workspaceURL, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: workspaceURL) }

        AgentUserDefaults.save(callName: "Yuan", context: "Build tools", directoryURL: workspaceURL)
        XCTAssertNotNil(AgentUserDefaults.load(directoryURL: workspaceURL))

        AgentUserDefaults.save(callName: "   ", context: "\n\n", directoryURL: workspaceURL)
        XCTAssertNil(AgentUserDefaults.load(directoryURL: workspaceURL))
    }

    @MainActor
    func testViewModelPrefillsUserFromDefaults() throws {
        let workspaceURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: workspaceURL, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: workspaceURL) }

        AgentUserDefaults.save(
            callName: "Yuan",
            context: "我喜欢简洁、直接、可执行的回答。",
            directoryURL: workspaceURL
        )

        let viewModel = AgentCreationViewModel(userDirectoryURL: workspaceURL)
        XCTAssertEqual(viewModel.data.userCallName, "Yuan")
        XCTAssertEqual(viewModel.data.userContext, "我喜欢简洁、直接、可执行的回答。")
    }
}
