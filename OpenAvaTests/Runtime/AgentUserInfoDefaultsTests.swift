import Foundation
import XCTest
@testable import OpenAva

final class AgentUserInfoDefaultsTests: XCTestCase {
    func testLoadReturnsSavedUserInfo() throws {
        let suiteName = "LocalAgentUserInfoDefaultsTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        AgentUserInfoDefaults.save(
            callName: "  Yuan  ",
            context: "  iOS 开发与 AI 自动化  ",
            defaults: defaults
        )

        let value = AgentUserInfoDefaults.load(defaults: defaults)
        XCTAssertEqual(value?.callName, "Yuan")
        XCTAssertEqual(value?.context, "iOS 开发与 AI 自动化")
    }

    func testSaveRemovesValueWhenEmpty() throws {
        let suiteName = "LocalAgentUserInfoDefaultsTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        AgentUserInfoDefaults.save(callName: "Yuan", context: "Build tools", defaults: defaults)
        XCTAssertNotNil(AgentUserInfoDefaults.load(defaults: defaults))

        AgentUserInfoDefaults.save(callName: "   ", context: "\n\n", defaults: defaults)
        XCTAssertNil(AgentUserInfoDefaults.load(defaults: defaults))
    }

    @MainActor
    func testViewModelPrefillsUserInfoFromDefaults() throws {
        let suiteName = "LocalAgentUserInfoDefaultsTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        AgentUserInfoDefaults.save(
            callName: "Yuan",
            context: "我喜欢简洁、直接、可执行的回答。",
            defaults: defaults
        )

        let viewModel = AgentCreationViewModel(defaults: defaults)
        XCTAssertEqual(viewModel.data.userCallName, "Yuan")
        XCTAssertEqual(viewModel.data.userContext, "我喜欢简洁、直接、可执行的回答。")
    }
}
