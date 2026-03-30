import Foundation

open class OpenAICompatibleClient: BaseChatClient, @unchecked Sendable {
    public let model: String
    open var baseURL: String?
    open var path: String?
    open var apiKey: String?
    open var defaultHeaders: [String: String]
    open var requestCustomization: [String: Any]

    public enum Error: Swift.Error {
        case invalidURL
        case invalidApiKey
        case invalidData
    }

    let session: URLSessioning
    let eventSourceFactory: EventSourceProducing
    let responseDecoderFactory: @Sendable () -> JSONDecoding
    let chunkDecoderFactory: @Sendable () -> JSONDecoding
    let errorExtractor: CompletionErrorExtractor

    public convenience init(
        model: String,
        baseURL: String? = nil,
        path: String? = nil,
        apiKey: String? = nil,
        defaultHeaders: [String: String] = [:],
        requestCustomization: [String: Any] = [:]
    ) {
        self.init(
            model: model,
            baseURL: baseURL,
            path: path,
            apiKey: apiKey,
            defaultHeaders: defaultHeaders,
            requestCustomization: requestCustomization,
            dependencies: .live
        )
    }

    public init(
        model: String,
        baseURL: String? = nil,
        path: String? = nil,
        apiKey: String? = nil,
        defaultHeaders: [String: String] = [:],
        requestCustomization: [String: Any] = [:],
        errorCollector: ErrorCollector = .new(),
        dependencies: RemoteClientDependencies
    ) {
        self.model = model
        self.baseURL = baseURL
        self.path = path
        self.apiKey = apiKey
        self.defaultHeaders = defaultHeaders
        self.requestCustomization = requestCustomization
        session = dependencies.session
        eventSourceFactory = dependencies.eventSourceFactory
        responseDecoderFactory = dependencies.responseDecoderFactory
        chunkDecoderFactory = dependencies.chunkDecoderFactory
        errorExtractor = dependencies.errorExtractor
        super.init(errorCollector: errorCollector)
    }

    /// Non-streaming: sends a single HTTP POST with stream=false and decodes the full response.
    override open func chat(body: ChatRequestBody) async throws -> ChatResponse {
        let requestBody = applyModelSettings(to: body, streaming: false)
            .sanitizingOutboundMessages()
        let request = try makeURLRequest(body: requestBody)
        logger.info("starting non-streaming request to model: \(self.model) with \(body.messages.count) messages")

        let (data, response) = try await session.data(for: request)
        if let http = response as? HTTPURLResponse, !(200 ..< 300).contains(http.statusCode) {
            let message = extractConnectionError(from: data, statusCode: http.statusCode)
            await errorCollector.collect(message)
            throw Error.invalidData
        }

        let decoder = OpenAICompatibleResponseDecoder(decoder: responseDecoderFactory())
        let chunks = try decoder.decodeResponse(from: data)
        return ChatResponse(chunks: chunks)
    }

    override open func provideStreamingChat(
        body: ChatRequestBody
    ) async throws -> AnyAsyncSequence<ChatResponseChunk> {
        let requestBody = applyModelSettings(to: body, streaming: true)
        let request = try makeURLRequest(body: requestBody)
        let this = self
        logger.info("starting streaming request to model: \(this.model) with \(body.messages.count) messages, temperature: \(body.temperature ?? 1.0)")

        let processor = OpenAICompatibleStreamProcessor(
            eventSourceFactory: eventSourceFactory,
            chunkDecoder: chunkDecoderFactory(),
            errorExtractor: errorExtractor
        )

        return processor.stream(request: request) { [weak self] error in
            await self?.collect(error: error)
        }
    }

    func makeRequestBuilder() -> OpenAICompatibleRequestBuilder {
        OpenAICompatibleRequestBuilder(
            baseURL: baseURL,
            path: path,
            apiKey: apiKey,
            defaultHeaders: defaultHeaders
        )
    }

    func makeURLRequest(body: ChatRequestBody) throws -> URLRequest {
        let builder = makeRequestBuilder()
        return try builder.makeRequest(body: body, requestCustomization: requestCustomization)
    }

    func applyModelSettings(to body: ChatRequestBody, streaming: Bool) -> ChatRequestBody {
        var requestBody = body
        requestBody.model = model
        requestBody.stream = streaming
        return requestBody
    }

    override open func extractConnectionError(from response: Data?, statusCode: Int) -> String {
        if let data = response, let decodedError = errorExtractor.extractError(from: data) {
            return decodedError.localizedDescription
        }
        return String(localized: "Connection error: \(statusCode)")
    }
}
