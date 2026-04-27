import Foundation
import OpenClawKit
import OpenClawProtocol

extension XService: ToolDefinitionProvider {
    nonisolated func toolDefinitions() -> [ToolDefinition] {
        [
            ToolDefinition(
                functionName: "x_query",
                command: "social.x_query",
                description: "Query X profiles, posts, followers, or following with authenticated web GraphQL access. Returns structured JSON and pagination cursors.",
                parametersSchema: AnyCodable([
                    "type": "object",
                    "properties": [
                        "operation": [
                            "type": "string",
                            "enum": ["search_tweets", "profile_tweets", "followers", "following", "user_profiles"],
                            "description": "Which X read operation to run.",
                        ],
                        "query": [
                            "type": "string",
                            "description": "Raw X search query, used mainly with search_tweets.",
                        ],
                        "search": [
                            "type": "object",
                            "description": "Optional structured search filters merged into the final X search query.",
                            "properties": [
                                "searchQuery": ["type": "string"],
                                "query": ["type": "string"],
                                "allWords": ["type": "array", "items": ["type": "string"]],
                                "anyWords": ["type": "array", "items": ["type": "string"]],
                                "exactPhrases": ["type": "array", "items": ["type": "string"]],
                                "excludeWords": ["type": "array", "items": ["type": "string"]],
                                "hashtagsAny": ["type": "array", "items": ["type": "string"]],
                                "hashtagsExclude": ["type": "array", "items": ["type": "string"]],
                                "fromUsers": ["type": "array", "items": ["type": "string"]],
                                "toUsers": ["type": "array", "items": ["type": "string"]],
                                "mentioningUsers": ["type": "array", "items": ["type": "string"]],
                                "lang": ["type": "string"],
                                "tweetType": [
                                    "type": "string",
                                    "enum": ["all", "originals_only", "replies_only", "retweets_only", "exclude_replies", "exclude_retweets"],
                                ],
                                "verifiedOnly": ["type": "boolean"],
                                "blueVerifiedOnly": ["type": "boolean"],
                                "hasImages": ["type": "boolean"],
                                "hasVideos": ["type": "boolean"],
                                "hasLinks": ["type": "boolean"],
                                "hasMentions": ["type": "boolean"],
                                "hasHashtags": ["type": "boolean"],
                                "minLikes": ["type": "integer", "minimum": 0],
                                "minReplies": ["type": "integer", "minimum": 0],
                                "minRetweets": ["type": "integer", "minimum": 0],
                                "place": ["type": "string"],
                                "geocode": ["type": "string"],
                                "near": ["type": "string"],
                                "within": ["type": "string"],
                                "since": ["type": "string"],
                                "until": ["type": "string"],
                            ],
                            "additionalProperties": false,
                        ],
                        "username": [
                            "type": "string",
                            "description": "Target username for profile_tweets, followers, following, or single profile lookups.",
                        ],
                        "usernames": [
                            "type": "array",
                            "items": ["type": "string"],
                            "description": "Multiple usernames, mainly for user_profiles.",
                        ],
                        "userId": [
                            "type": "string",
                            "description": "Target numeric user id for profile_tweets, followers, or following.",
                        ],
                        "cursor": [
                            "type": "string",
                            "description": "Pagination cursor returned by a previous x_query call.",
                        ],
                        "maxResults": [
                            "type": "integer",
                            "minimum": 1,
                            "maximum": 100,
                            "description": "Maximum results to request. Defaults to 20.",
                        ],
                        "displayType": [
                            "type": "string",
                            "enum": ["latest", "top"],
                            "description": "Search result mode for search_tweets. Defaults to latest.",
                        ],
                        "auth": [
                            "type": "object",
                            "description": "Optional inline credentials. If omitted, the tool uses stored credentials from x_auth.",
                            "properties": [
                                "authToken": ["type": "string"],
                                "csrfToken": ["type": "string"],
                                "bearerToken": ["type": "string"],
                            ],
                            "additionalProperties": false,
                        ],
                    ],
                    "required": ["operation"],
                    "additionalProperties": false,
                ] as [String: Any]),
                isReadOnly: true,
                isConcurrencySafe: true,
                maxResultSizeChars: 48 * 1024
            ),
            ToolDefinition(
                functionName: "x_auth",
                command: "social.x_auth",
                description: "Save, inspect, or clear stored X authentication material used by x_query.",
                parametersSchema: AnyCodable([
                    "type": "object",
                    "properties": [
                        "action": [
                            "type": "string",
                            "enum": ["set", "clear", "status"],
                            "description": "Whether to save, clear, or inspect stored X credentials.",
                        ],
                        "auth": [
                            "type": "object",
                            "description": "Credentials to save when action is set. authToken is required; csrfToken is optional if auth_token can bootstrap ct0.",
                            "properties": [
                                "authToken": ["type": "string"],
                                "csrfToken": ["type": "string"],
                                "bearerToken": ["type": "string"],
                            ],
                            "additionalProperties": false,
                        ],
                    ],
                    "required": ["action"],
                    "additionalProperties": false,
                ] as [String: Any]),
                isReadOnly: false,
                isConcurrencySafe: false,
                maxResultSizeChars: 16 * 1024
            ),
        ]
    }

    nonisolated func registerHandlers(into handlers: inout [String: ToolHandler]) {
        handlers["social.x_query"] = { [weak self] request in
            guard let self else { throw ToolHandlerError.handlerUnavailable }
            return try await self.handleXQueryInvoke(request)
        }
        handlers["social.x_auth"] = { [weak self] request in
            guard let self else { throw ToolHandlerError.handlerUnavailable }
            return try await self.handleXAuthInvoke(request)
        }
    }

    private func handleXQueryInvoke(_ request: BridgeInvokeRequest) async throws -> BridgeInvokeResponse {
        let params = try ToolInvocationHelpers.decodeParams(XQueryRequest.self, from: request.paramsJSON)
        do {
            let result = try await query(params)
            return try BridgeInvokeResponse(id: request.id, ok: true, payload: ToolInvocationHelpers.encodePayload(result))
        } catch let error as XServiceError {
            return mapXError(error, requestID: request.id)
        }
    }

    private func handleXAuthInvoke(_ request: BridgeInvokeRequest) async throws -> BridgeInvokeResponse {
        struct Params: Decodable {
            let action: XAuthAction
            let auth: XInlineAuth?
        }

        let params = try ToolInvocationHelpers.decodeParams(Params.self, from: request.paramsJSON)
        do {
            let result = try await configureAuth(action: params.action, credentials: params.auth)
            return try BridgeInvokeResponse(id: request.id, ok: true, payload: ToolInvocationHelpers.encodePayload(result))
        } catch let error as XServiceError {
            return mapXError(error, requestID: request.id)
        }
    }

    private nonisolated func mapXError(_ error: XServiceError, requestID: String) -> BridgeInvokeResponse {
        switch error {
        case let .invalidRequest(message):
            return ToolInvocationHelpers.invalidRequest(id: requestID, message)
        case let .authenticationRequired(message):
            return ToolInvocationHelpers.unavailableResponse(id: requestID, "UNAVAILABLE: \(message)")
        case let .notFound(message):
            return ToolInvocationHelpers.invalidRequest(id: requestID, message)
        case .rateLimited:
            return ToolInvocationHelpers.unavailableResponse(id: requestID, "UNAVAILABLE: X rate limited the request")
        case let .invalidResponse(message):
            return ToolInvocationHelpers.unavailableResponse(id: requestID, "UNAVAILABLE: \(message)")
        case let .unavailable(message):
            return ToolInvocationHelpers.unavailableResponse(id: requestID, "UNAVAILABLE: \(message)")
        }
    }
}
