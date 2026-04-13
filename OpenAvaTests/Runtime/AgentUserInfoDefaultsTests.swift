import Foundation
import XCTest
@testable import OpenAva

final class AgentUserInfoDefaultsTests: XCTestCase {
    func testLoadReturnsSavedUserInfo() throws {
        let workspaceURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: workspaceURL, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: workspaceURL) }

        AgentUserInfoDefaults.save(
            callName: "  Yuan  ",
            context: "  iOS 开发与 AI 自动化  ",
            directoryURL: workspaceURL
        )

        let value = AgentUserInfoDefaults.load(directoryURL: workspaceURL)
        XCTAssertEqual(value?.callName, "Yuan")
        XCTAssertEqual(value?.context, "iOS 开发与 AI 自动化")
    }

    func testSaveRemovesValueWhenEmpty() throws {
        let workspaceURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: workspaceURL, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: workspaceURL) }

        AgentUserInfoDefaults.save(callName: "Yuan", context: "Build tools", directoryURL: workspaceURL)
        XCTAssertNotNil(AgentUserInfoDefaults.load(directoryURL: workspaceURL))

        AgentUserInfoDefaults.save(callName: "   ", context: "\n\n", directoryURL: workspaceURL)
        XCTAssertNil(AgentUserInfoDefaults.load(directoryURL: workspaceURL))
    }

    @MainActor
    func testViewModelPrefillsUserInfoFromDefaults() throws {
        let workspaceURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: workspaceURL, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: workspaceURL) }

        AgentUserInfoDefaults.save(
            callName: "Yuan",
            context: "我喜欢简洁、直接、可执行的回答。",
            directoryURL: workspaceURL
        )

        let viewModel = AgentCreationViewModel(userInfoDirectoryURL: workspaceURL)
        XCTAssertEqual(viewModel.data.userCallName, "Yuan")
        XCTAssertEqual(viewModel.data.userContext, "我喜欢简洁、直接、可执行的回答。")
    }
}
