import ChatUI
import Foundation
import XCTest
@testable import OpenAva

final class ChatSubmissionHelpersTests: XCTestCase {
    func testMakePromptInputPreservesEveryoneMentionAsUserIntent() {
        let object = ChatInputContent(text: "@all 请同步一下进度")

        let input = makePromptInput(from: object)

        XCTAssertEqual(input.text, "@all 请同步一下进度")
        XCTAssertEqual(input.source.rawValue, ConversationSession.PromptInput.Source.user.rawValue)
        XCTAssertEqual(input.metadata[ConversationSession.PromptInput.sourceMetadataKey], "user")
    }

    func testMakePromptInputPreservesAgentMentionAsUserIntent() {
        let object = ChatInputContent(text: "请 @Alice 跟进这个问题")

        let input = makePromptInput(from: object)

        XCTAssertEqual(input.text, "请 @Alice 跟进这个问题")
        XCTAssertEqual(input.source.rawValue, ConversationSession.PromptInput.Source.user.rawValue)
        XCTAssertEqual(input.metadata[ConversationSession.PromptInput.sourceMetadataKey], "user")
    }
}
