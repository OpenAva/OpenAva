//
//  OpenAICompatibleResponseDecoderTests.swift
//  ChatClientKitTests
//

import Foundation
import Testing
@testable import ChatClient

struct OpenAICompatibleResponseDecoderTests {
    @Test("Non-stream decoder keeps DeepSeek reasoning_content when text is empty")
    func decodeReasoningContentWithoutText() throws {
        let json = """
        {
            "choices": [{
                "message": {
                    "content": "",
                    "reasoning_content": "{\"history_summary\":\"summary\",\"should_update_memory\":false,\"memory_append\":\"\"}"
                }
            }]
        }
        """

        let decoder = OpenAICompatibleResponseDecoder()
        let chunks = try decoder.decodeResponse(from: Data(json.utf8))
        let response = ChatResponse(chunks: chunks)

        #expect(response.text == "")
        #expect(response.reasoning == "{\"history_summary\":\"summary\",\"should_update_memory\":false,\"memory_append\":\"\"}")
    }

    @Test("Non-stream decoder keeps plain content responses unchanged")
    func decodePlainContent() throws {
        let json = """
        {
            "choices": [{
                "message": {
                    "content": "plain response"
                }
            }]
        }
        """

        let decoder = OpenAICompatibleResponseDecoder()
        let chunks = try decoder.decodeResponse(from: Data(json.utf8))
        let response = ChatResponse(chunks: chunks)

        #expect(response.text == "plain response")
        #expect(response.reasoning.isEmpty)
    }

    @Test("Non-stream decoder keeps Gemini-style reasoning field")
    func decodeReasoningField() throws {
        let json = """
        {
            "choices": [{
                "message": {
                    "content": "",
                    "reasoning": "structured result"
                }
            }]
        }
        """

        let decoder = OpenAICompatibleResponseDecoder()
        let chunks = try decoder.decodeResponse(from: Data(json.utf8))
        let response = ChatResponse(chunks: chunks)

        #expect(response.text == "")
        #expect(response.reasoning == "structured result")
    }
}
