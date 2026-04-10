import Foundation
import Testing
@testable import ChatClient

struct AnthropicNonStreamingTests {
    @Test("AnthropicClient chat sends stream=false and decodes text response")
    func nonStreamingTextResponse() async throws {
        let session = RecordingSession(
            responseData: Data(#"{"content":[{"type":"text","text":"hello"}],"usage":{"input_tokens":12,"output_tokens":34}}"#.utf8)
        )
        let client = AnthropicClient(
            model: "claude-sonnet-4-20250514",
            dependencies: .init(
                session: session,
                eventSourceFactory: DefaultEventSourceFactory(),
                responseDecoderFactory: { JSONDecoderWrapper() },
                chunkDecoderFactory: { JSONDecoderWrapper() },
                errorExtractor: CompletionErrorExtractor()
            )
        )

        let response = try await client.chat(body: ChatRequestBody(
            messages: [.user(content: .text("hello"))]
        ))

        #expect(response.text == "hello")
        #expect(response.tools.isEmpty)
        #expect(response.usage?.inputTokens == 12)
        #expect(response.usage?.outputTokens == 34)

        let requestJSON = try session.requestJSON()
        #expect(requestJSON["stream"] as? Bool == false)
    }

    @Test("AnthropicClient chat decodes tool_use response")
    func nonStreamingToolResponse() async throws {
        let session = RecordingSession(
            responseData: Data(#"{"content":[{"type":"tool_use","id":"tool-1","name":"set_conversation_title","input":{"title":"Hello","titleAvatar":"🦊"}}]}"#.utf8)
        )
        let client = AnthropicClient(
            model: "claude-sonnet-4-20250514",
            dependencies: .init(
                session: session,
                eventSourceFactory: DefaultEventSourceFactory(),
                responseDecoderFactory: { JSONDecoderWrapper() },
                chunkDecoderFactory: { JSONDecoderWrapper() },
                errorExtractor: CompletionErrorExtractor()
            )
        )

        let response = try await client.chat(body: ChatRequestBody(
            messages: [.user(content: .text("hello"))]
        ))

        #expect(response.text.isEmpty)
        #expect(response.tools.count == 1)
        #expect(response.tools.first?.id == "tool-1")
        #expect(response.tools.first?.name == "set_conversation_title")
        #expect(response.tools.first?.arguments == #"{"title":"Hello","titleAvatar":"🦊"}"#)
    }
}

private final class RecordingSession: URLSessioning, @unchecked Sendable {
    private let responseData: Data
    private let response: URLResponse
    private let lock = NSLock()
    private var recordedRequest: URLRequest?

    init(responseData: Data, statusCode: Int = 200) {
        self.responseData = responseData
        response = HTTPURLResponse(
            url: URL(string: "https://example.com/v1/messages")!,
            statusCode: statusCode,
            httpVersion: nil,
            headerFields: nil
        )!
    }

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        lock.lock()
        recordedRequest = request
        lock.unlock()
        return (responseData, response)
    }

    func requestJSON() throws -> [String: Any] {
        lock.lock()
        let request = recordedRequest
        lock.unlock()

        guard let body = request?.httpBody else {
            throw NSError(domain: "RecordingSession", code: 1, userInfo: [NSLocalizedDescriptionKey: "Missing recorded request body"])
        }
        let jsonObject = try JSONSerialization.jsonObject(with: body)
        guard let dictionary = jsonObject as? [String: Any] else {
            throw NSError(domain: "RecordingSession", code: 2, userInfo: [NSLocalizedDescriptionKey: "Recorded request body was not a JSON object"])
        }
        return dictionary
    }
}
