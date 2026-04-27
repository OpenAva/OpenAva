import Foundation
import OpenClawKit
import XCTest
@testable import OpenAva

@MainActor
final class XServiceTests: XCTestCase {
    override func tearDown() {
        XMockURLProtocol.requestHandler = nil
        super.tearDown()
    }

    func testToolDefinitionsExposeExpectedSemanticsAndSchema() throws {
        let definitions = XService().toolDefinitions()
        let byName = Dictionary(uniqueKeysWithValues: definitions.map { ($0.functionName, $0) })

        let query = try XCTUnwrap(byName["x_query"])
        XCTAssertEqual(query.command, "social.x_query")
        XCTAssertEqual(query.isReadOnly, true)
        XCTAssertEqual(query.isDestructive, false)
        XCTAssertEqual(query.isConcurrencySafe, true)
        XCTAssertEqual(query.maxResultSizeChars, 48 * 1024)

        let querySchema = try XCTUnwrap(query.parametersSchema.value as? [String: Any])
        let queryProperties = try XCTUnwrap(querySchema["properties"] as? [String: Any])
        let operation = try XCTUnwrap(queryProperties["operation"] as? [String: Any])
        let operationEnum = try XCTUnwrap(operation["enum"] as? [String])
        XCTAssertEqual(Set(operationEnum), Set(["search_tweets", "profile_tweets", "followers", "following", "user_profiles"]))
        XCTAssertNotNil(queryProperties["search"])
        XCTAssertNotNil(queryProperties["auth"])
        XCTAssertEqual(querySchema["required"] as? [String], ["operation"])

        let auth = try XCTUnwrap(byName["x_auth"])
        XCTAssertEqual(auth.command, "social.x_auth")
        XCTAssertEqual(auth.isReadOnly, false)
        XCTAssertEqual(auth.isDestructive, false)
        XCTAssertEqual(auth.isConcurrencySafe, false)
        XCTAssertEqual(auth.maxResultSizeChars, 16 * 1024)

        let authSchema = try XCTUnwrap(auth.parametersSchema.value as? [String: Any])
        let authProperties = try XCTUnwrap(authSchema["properties"] as? [String: Any])
        let action = try XCTUnwrap(authProperties["action"] as? [String: Any])
        XCTAssertEqual(try Set(XCTUnwrap(action["enum"] as? [String])), Set(["set", "clear", "status"]))
        XCTAssertNotNil(authProperties["auth"])
        XCTAssertEqual(authSchema["required"] as? [String], ["action"])
    }

    func testBuildEffectiveSearchQueryCombinesStructuredFiltersAndNormalizesInputs() throws {
        let query = try XService.buildEffectiveSearchQueryForTesting(
            query: nil,
            search: XSearchInput(
                searchQuery: "swift ai",
                query: nil,
                allWords: ["ship", "vision pro", "ship"],
                anyWords: ["ios", "macos", "ios"],
                exactPhrases: ["agent mode"],
                excludeWords: ["ads", "ads"],
                hashtagsAny: ["Swift", "#AI"],
                hashtagsExclude: ["spam"],
                fromUsers: ["@openava", "OpenAva", "bad user"],
                toUsers: ["team"],
                mentioningUsers: ["@swiftlang", "SwiftLang"],
                lang: "en",
                tweetType: "originals_only",
                verifiedOnly: true,
                blueVerifiedOnly: false,
                hasImages: true,
                hasVideos: false,
                hasLinks: false,
                hasMentions: false,
                hasHashtags: false,
                minLikes: 10,
                minReplies: 0,
                minRetweets: 3,
                place: nil,
                geocode: nil,
                near: "San Francisco",
                within: "15km",
                since: "2024-01-01_UTC",
                until: "2024-01-31_UTC"
            )
        )

        XCTAssertEqual(
            query,
            "swift ai (ship AND \"vision pro\") (ios OR macos) (\"agent mode\") -ads (#Swift OR #AI) -#spam from:openava to:team @swiftlang lang:en -filter:replies -filter:retweets filter:verified filter:images min_faves:10 min_retweets:3 since:2024-01-01 until:2024-01-31 near:San Francisco within:15km"
        )
    }

    func testBuildEffectiveSearchQueryRespectsExistingOperatorsAndRejectsEmptyInput() throws {
        let existing = try XService.buildEffectiveSearchQueryForTesting(
            query: "from:ava lang:en filter:links min_faves:5 since:2024-01-01 place:NYC",
            search: XSearchInput(
                searchQuery: nil,
                query: nil,
                allWords: nil,
                anyWords: nil,
                exactPhrases: nil,
                excludeWords: nil,
                hashtagsAny: nil,
                hashtagsExclude: nil,
                fromUsers: ["other"],
                toUsers: nil,
                mentioningUsers: nil,
                lang: "ja",
                tweetType: "exclude_retweets",
                verifiedOnly: false,
                blueVerifiedOnly: false,
                hasImages: true,
                hasVideos: false,
                hasLinks: false,
                hasMentions: false,
                hasHashtags: false,
                minLikes: 0,
                minReplies: 0,
                minRetweets: 7,
                place: nil,
                geocode: nil,
                near: "San Francisco",
                within: "10km",
                since: "2024-02-01",
                until: nil
            )
        )

        XCTAssertEqual(existing, "from:ava lang:en filter:links min_faves:5 since:2024-01-01 place:NYC")

        XCTAssertThrowsError(
            try XService.buildEffectiveSearchQueryForTesting(
                query: nil,
                search: XSearchInput(
                    searchQuery: nil,
                    query: nil,
                    allWords: nil,
                    anyWords: nil,
                    exactPhrases: nil,
                    excludeWords: nil,
                    hashtagsAny: nil,
                    hashtagsExclude: nil,
                    fromUsers: nil,
                    toUsers: nil,
                    mentioningUsers: nil,
                    lang: nil,
                    tweetType: nil,
                    verifiedOnly: nil,
                    blueVerifiedOnly: nil,
                    hasImages: nil,
                    hasVideos: nil,
                    hasLinks: nil,
                    hasMentions: nil,
                    hasHashtags: nil,
                    minLikes: nil,
                    minReplies: nil,
                    minRetweets: nil,
                    place: nil,
                    geocode: nil,
                    near: nil,
                    within: nil,
                    since: nil,
                    until: nil
                )
            )
        ) { error in
            guard case let XServiceError.invalidRequest(message) = error else {
                XCTFail("Expected invalid request, got \(error)")
                return
            }
            XCTAssertEqual(message, "query or search fields are required for search_tweets")
        }
    }

    func testXAuthHandlerSupportsStatusSetAndClearLifecycle() async throws {
        let store = InMemoryXCredentialStore()
        let service = XService(session: makeMockSession(), credentialStore: store.store)
        var handlers: [String: ToolHandler] = [:]
        service.registerHandlers(into: &handlers)

        let handler = try XCTUnwrap(handlers["social.x_auth"])

        let initial = try await handler(
            BridgeInvokeRequest(
                id: UUID().uuidString,
                command: "social.x_auth",
                paramsJSON: #"{"action":"status"}"#
            )
        )
        XCTAssertTrue(initial.ok)
        let initialStatus = try decodePayload(XAuthConfigurationResult.self, from: initial)
        XCTAssertFalse(initialStatus.status.hasStoredAuthToken)
        XCTAssertFalse(initialStatus.status.hasStoredCSRFToken)
        XCTAssertFalse(initialStatus.status.isReadyForAuthenticatedRequests)

        let setResponse = try await handler(
            BridgeInvokeRequest(
                id: UUID().uuidString,
                command: "social.x_auth",
                paramsJSON: #"{"action":"set","auth":{"authToken":"auth-token","csrfToken":"csrf-token"}}"#
            )
        )
        XCTAssertTrue(setResponse.ok)
        let setResult = try decodePayload(XAuthConfigurationResult.self, from: setResponse)
        XCTAssertEqual(setResult.action, .set)
        XCTAssertFalse(setResult.bootstrappedCSRFToken)
        XCTAssertTrue(setResult.status.hasStoredAuthToken)
        XCTAssertTrue(setResult.status.hasStoredCSRFToken)
        XCTAssertTrue(setResult.status.hasStoredBearerToken)
        XCTAssertTrue(setResult.status.isReadyForAuthenticatedRequests)
        XCTAssertEqual(store.values["auth_token"], "auth-token")
        XCTAssertEqual(store.values["csrf_token"], "csrf-token")
        XCTAssertNotNil(store.values["bearer_token"])

        let clearResponse = try await handler(
            BridgeInvokeRequest(
                id: UUID().uuidString,
                command: "social.x_auth",
                paramsJSON: #"{"action":"clear"}"#
            )
        )
        XCTAssertTrue(clearResponse.ok)
        let clearResult = try decodePayload(XAuthConfigurationResult.self, from: clearResponse)
        XCTAssertEqual(clearResult.action, .clear)
        XCTAssertFalse(clearResult.status.hasStoredAuthToken)
        XCTAssertFalse(clearResult.status.hasStoredCSRFToken)
        XCTAssertFalse(clearResult.status.hasStoredBearerToken)
        XCTAssertFalse(clearResult.status.isReadyForAuthenticatedRequests)
        XCTAssertTrue(store.values.isEmpty)
    }

    func testXQueryHandlerBuildsSearchRequestAndDecodesTimelinePayload() async throws {
        XMockURLProtocol.requestHandler = { request in
            let url = try XCTUnwrap(request.url)
            let components = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false))
            let items = Dictionary(uniqueKeysWithValues: (components.queryItems ?? []).map { ($0.name, $0.value ?? "") })

            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer custom-bearer")
            XCTAssertEqual(request.value(forHTTPHeaderField: "X-Csrf-Token"), "csrf-inline")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Cookie"), "auth_token=auth-inline; ct0=csrf-inline")
            XCTAssertTrue(components.path.contains("/SearchTimeline"))

            let variablesData = try XCTUnwrap(items["variables"]?.data(using: .utf8))
            let variables = try XCTUnwrap(JSONSerialization.jsonObject(with: variablesData) as? [String: Any])
            XCTAssertEqual(variables["rawQuery"] as? String, "OpenAva")
            XCTAssertEqual(variables["count"] as? Int, 1)
            XCTAssertEqual(variables["product"] as? String, "Latest")

            let responseObject: [String: Any] = [
                "data": [
                    "search_by_raw_query": [
                        "search_timeline": [
                            "timeline": [
                                "instructions": [
                                    [
                                        "type": "TimelineAddEntries",
                                        "entries": [
                                            [
                                                "entryId": "tweet-123456",
                                                "content": [
                                                    "itemContent": [
                                                        "tweet_results": [
                                                            "result": [
                                                                "rest_id": "123456",
                                                                "legacy": [
                                                                    "full_text": "Hello from X",
                                                                    "created_at": "Mon Jan 01 00:00:00 +0000 2024",
                                                                    "reply_count": 1,
                                                                    "favorite_count": 2,
                                                                    "retweet_count": 3,
                                                                    "quote_count": 4,
                                                                    "lang": "en",
                                                                    "source": "OpenAva Test",
                                                                ],
                                                                "views": ["count": "5"],
                                                                "core": [
                                                                    "user_results": [
                                                                        "result": [
                                                                            "rest_id": "42",
                                                                            "legacy": [
                                                                                "screen_name": "openava",
                                                                                "name": "OpenAva",
                                                                            ],
                                                                        ],
                                                                    ],
                                                                ],
                                                            ],
                                                        ],
                                                    ],
                                                ],
                                            ],
                                            [
                                                "entryId": "cursor-bottom-1",
                                                "content": [
                                                    "value": "CURSOR-123",
                                                    "cursorType": "Bottom",
                                                ],
                                            ],
                                        ],
                                    ],
                                ],
                            ],
                        ],
                    ],
                ],
            ]

            let data = try JSONSerialization.data(withJSONObject: responseObject)
            let response = try HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!
            return (response, data)
        }

        let service = XService(session: makeMockSession(), credentialStore: InMemoryXCredentialStore().store)
        var handlers: [String: ToolHandler] = [:]
        service.registerHandlers(into: &handlers)

        let handler = try XCTUnwrap(handlers["social.x_query"])
        let response = try await handler(
            BridgeInvokeRequest(
                id: UUID().uuidString,
                command: "social.x_query",
                paramsJSON: #"{"operation":"search_tweets","query":"OpenAva","maxResults":1,"auth":{"authToken":"auth-inline","csrfToken":"csrf-inline","bearerToken":"custom-bearer"}}"#
            )
        )

        XCTAssertTrue(response.ok)
        let result = try decodePayload(XQueryResult.self, from: response)
        XCTAssertEqual(result.operation, .searchTweets)
        XCTAssertEqual(result.request.query, "OpenAva")
        XCTAssertEqual(result.request.maxResults, 1)
        XCTAssertEqual(result.request.displayType, "latest")
        XCTAssertEqual(result.nextCursor, "CURSOR-123")
        XCTAssertFalse(result.auth.usedStoredCredentials)
        XCTAssertTrue(result.auth.usedInlineCredentials)
        XCTAssertEqual(result.tweets.count, 1)

        let tweet = try XCTUnwrap(result.tweets.first)
        XCTAssertEqual(tweet.id, "123456")
        XCTAssertEqual(tweet.text, "Hello from X")
        XCTAssertEqual(tweet.replyCount, 1)
        XCTAssertEqual(tweet.likeCount, 2)
        XCTAssertEqual(tweet.retweetCount, 3)
        XCTAssertEqual(tweet.quoteCount, 4)
        XCTAssertEqual(tweet.viewCount, 5)
        XCTAssertEqual(tweet.author.userID, "42")
        XCTAssertEqual(tweet.author.username, "openava")
        XCTAssertEqual(tweet.author.name, "OpenAva")
        XCTAssertEqual(tweet.tweetURL, "https://x.com/openava/status/123456")
    }

    func testUserProfilesQueryReturnsProfilesAndWarningsForMissingUsers() async throws {
        XMockURLProtocol.requestHandler = { request in
            let url = try XCTUnwrap(request.url)
            let components = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false))
            XCTAssertTrue(components.path.contains("/UserByScreenName"))

            let variables = try decodeJSONObjectQueryItem(named: "variables", from: components)
            let username = try XCTUnwrap(variables["screen_name"] as? String)

            let responseObject: [String: Any]
            switch username {
            case "openava":
                responseObject = [
                    "data": [
                        "user": [
                            "result": [
                                "rest_id": "42",
                                "legacy": [
                                    "screen_name": "openava",
                                    "name": "OpenAva",
                                    "description": "AI agent workspace",
                                    "followers_count": 100,
                                    "friends_count": 50,
                                    "statuses_count": 12,
                                    "favourites_count": 3,
                                    "media_count": 1,
                                    "listed_count": 2,
                                    "verified": true,
                                    "profile_image_url_https": "https://img.example/openava.jpg",
                                ],
                            ],
                        ],
                    ],
                ]
            case "missinguser":
                responseObject = [
                    "data": [
                        "user": [
                            "result": [
                                "__typename": "UserUnavailable",
                            ],
                        ],
                    ],
                ]
            default:
                XCTFail("Unexpected username lookup: \(username)")
                responseObject = [:]
            }

            return try makeJSONHTTPResponse(url: url, object: responseObject)
        }

        let service = XService(session: makeMockSession(), credentialStore: InMemoryXCredentialStore().store)
        var handlers: [String: ToolHandler] = [:]
        service.registerHandlers(into: &handlers)

        let handler = try XCTUnwrap(handlers["social.x_query"])
        let response = try await handler(
            BridgeInvokeRequest(
                id: UUID().uuidString,
                command: "social.x_query",
                paramsJSON: #"{"operation":"user_profiles","usernames":["openava","missinguser","@openava"],"auth":{"authToken":"auth-inline","csrfToken":"csrf-inline","bearerToken":"custom-bearer"}}"#
            )
        )

        XCTAssertTrue(response.ok)
        let result = try decodePayload(XQueryResult.self, from: response)
        XCTAssertEqual(result.operation, .userProfiles)
        XCTAssertEqual(result.request.usernames ?? [], ["openava", "missinguser"])
        XCTAssertEqual(result.profiles.count, 1)
        XCTAssertEqual(result.warnings, ["X user @missinguser was not found."])
        XCTAssertEqual(result.message, "Resolved 1 X profile(s).")
        XCTAssertTrue(result.auth.usedInlineCredentials)

        let profile = try XCTUnwrap(result.profiles.first)
        XCTAssertEqual(profile.userID, "42")
        XCTAssertEqual(profile.username, "openava")
        XCTAssertEqual(profile.name, "OpenAva")
        XCTAssertEqual(profile.followersCount, 100)
        XCTAssertTrue(profile.verified)
        XCTAssertEqual(profile.profileURL, "https://x.com/openava")
    }

    func testFollowersQueryResolvesUsernameThenDecodesUsersAndCursor() async throws {
        XMockURLProtocol.requestHandler = { request in
            let url = try XCTUnwrap(request.url)
            let components = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false))

            if components.path.contains("/UserByScreenName") {
                let variables = try decodeJSONObjectQueryItem(named: "variables", from: components)
                XCTAssertEqual(variables["screen_name"] as? String, "openava")

                let responseObject: [String: Any] = [
                    "data": [
                        "user": [
                            "result": [
                                "rest_id": "42",
                                "legacy": [
                                    "screen_name": "openava",
                                    "name": "OpenAva",
                                ],
                            ],
                        ],
                    ],
                ]
                return try makeJSONHTTPResponse(url: url, object: responseObject)
            }

            XCTAssertTrue(components.path.contains("/Followers"))
            let variables = try decodeJSONObjectQueryItem(named: "variables", from: components)
            XCTAssertEqual(variables["userId"] as? String, "42")
            XCTAssertEqual(variables["count"] as? Int, 2)

            let responseObject: [String: Any] = [
                "data": [
                    "user": [
                        "result": [
                            "timeline": [
                                "timeline": [
                                    "instructions": [
                                        [
                                            "entries": [
                                                [
                                                    "entryId": "user-1",
                                                    "content": [
                                                        "itemContent": [
                                                            "user_results": [
                                                                "result": [
                                                                    "rest_id": "100",
                                                                    "legacy": [
                                                                        "screen_name": "alice",
                                                                        "name": "Alice",
                                                                        "followers_count": 10,
                                                                        "friends_count": 2,
                                                                    ],
                                                                ],
                                                            ],
                                                        ],
                                                    ],
                                                ],
                                                [
                                                    "entryId": "user-2",
                                                    "content": [
                                                        "itemContent": [
                                                            "user_results": [
                                                                "result": [
                                                                    "rest_id": "200",
                                                                    "legacy": [
                                                                        "screen_name": "bob",
                                                                        "name": "Bob",
                                                                        "followers_count": 20,
                                                                        "friends_count": 5,
                                                                    ],
                                                                ],
                                                            ],
                                                        ],
                                                    ],
                                                ],
                                                [
                                                    "entryId": "cursor-bottom-1",
                                                    "content": [
                                                        "value": "FOLLOW-CURSOR",
                                                        "cursorType": "Bottom",
                                                    ],
                                                ],
                                            ],
                                        ],
                                    ],
                                ],
                            ],
                        ],
                    ],
                ],
            ]
            return try makeJSONHTTPResponse(url: url, object: responseObject)
        }

        let service = XService(session: makeMockSession(), credentialStore: InMemoryXCredentialStore().store)
        var handlers: [String: ToolHandler] = [:]
        service.registerHandlers(into: &handlers)

        let handler = try XCTUnwrap(handlers["social.x_query"])
        let response = try await handler(
            BridgeInvokeRequest(
                id: UUID().uuidString,
                command: "social.x_query",
                paramsJSON: #"{"operation":"followers","username":"openava","maxResults":2,"auth":{"authToken":"auth-inline","csrfToken":"csrf-inline","bearerToken":"custom-bearer"}}"#
            )
        )

        XCTAssertTrue(response.ok)
        let result = try decodePayload(XQueryResult.self, from: response)
        XCTAssertEqual(result.operation, .followers)
        XCTAssertEqual(result.request.username, "openava")
        XCTAssertEqual(result.request.userId, "42")
        XCTAssertEqual(result.request.maxResults, 2)
        XCTAssertEqual(result.nextCursor, "FOLLOW-CURSOR")
        XCTAssertEqual(result.users.count, 2)
        XCTAssertEqual(result.resolvedTarget?.userID, "42")
        XCTAssertEqual(result.resolvedTarget?.username, "openava")
        XCTAssertEqual(result.resolvedTarget?.name, "OpenAva")
        XCTAssertEqual(result.message, "Fetched 2 followers record(s).")

        XCTAssertEqual(result.users.map(\.username), ["alice", "bob"])
        XCTAssertEqual(result.users.map(\.followersCount), [10, 20])
    }

    func testProfileTweetsQueryWithUserIdSkipsLookupAndDecodesRichTweetFields() async throws {
        XMockURLProtocol.requestHandler = { request in
            let url = try XCTUnwrap(request.url)
            let components = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false))

            XCTAssertFalse(components.path.contains("/UserByScreenName"))
            XCTAssertTrue(components.path.contains("/UserTweets"))

            let variables = try decodeJSONObjectQueryItem(named: "variables", from: components)
            XCTAssertEqual(variables["userId"] as? String, "777")
            XCTAssertEqual(variables["count"] as? Int, 1)

            let responseObject: [String: Any] = [
                "data": [
                    "user": [
                        "result": [
                            "timeline": [
                                "timeline": [
                                    "instructions": [
                                        [
                                            "entries": [
                                                [
                                                    "entryId": "tweet-987654",
                                                    "content": [
                                                        "itemContent": [
                                                            "tweet_results": [
                                                                "result": [
                                                                    "tweet": [
                                                                        "rest_id": "987654",
                                                                        "legacy": [
                                                                            "id_str": "987654",
                                                                            "full_text": "Short fallback",
                                                                            "created_at": "Mon Feb 05 00:00:00 +0000 2024",
                                                                            "reply_count": 2,
                                                                            "favorite_count": 8,
                                                                            "retweet_count": 3,
                                                                            "quote_count": 1,
                                                                            "lang": "en",
                                                                            "source": "Web App",
                                                                            "extended_entities": [
                                                                                "media": [
                                                                                    ["media_url_https": "https://img.example/1.jpg"],
                                                                                ],
                                                                            ],
                                                                        ],
                                                                        "note_tweet": [
                                                                            "note_tweet_results": [
                                                                                "result": [
                                                                                    "text": "Expanded note",
                                                                                ],
                                                                            ],
                                                                        ],
                                                                        "quoted_status_result": [
                                                                            "result": [
                                                                                "legacy": [
                                                                                    "full_text": "Quoted hello",
                                                                                ],
                                                                            ],
                                                                        ],
                                                                        "views": ["count": "99"],
                                                                        "core": [
                                                                            "user_results": [
                                                                                "result": [
                                                                                    "rest_id": "777",
                                                                                    "legacy": [
                                                                                        "screen_name": "openava",
                                                                                        "name": "OpenAva",
                                                                                    ],
                                                                                ],
                                                                            ],
                                                                        ],
                                                                    ],
                                                                ],
                                                            ],
                                                        ],
                                                    ],
                                                ],
                                                [
                                                    "entryId": "cursor-bottom-1",
                                                    "content": [
                                                        "value": "PROFILE-CURSOR",
                                                        "cursorType": "Bottom",
                                                    ],
                                                ],
                                            ],
                                        ],
                                    ],
                                ],
                            ],
                        ],
                    ],
                ],
            ]

            return try makeJSONHTTPResponse(url: url, object: responseObject)
        }

        let service = XService(session: makeMockSession(), credentialStore: InMemoryXCredentialStore().store)
        var handlers: [String: ToolHandler] = [:]
        service.registerHandlers(into: &handlers)

        let handler = try XCTUnwrap(handlers["social.x_query"])
        let response = try await handler(
            BridgeInvokeRequest(
                id: UUID().uuidString,
                command: "social.x_query",
                paramsJSON: #"{"operation":"profile_tweets","userId":"777","maxResults":1,"auth":{"authToken":"auth-inline","csrfToken":"csrf-inline","bearerToken":"custom-bearer"}}"#
            )
        )

        XCTAssertTrue(response.ok)
        let result = try decodePayload(XQueryResult.self, from: response)
        XCTAssertEqual(result.operation, .profileTweets)
        XCTAssertEqual(result.request.userId, "777")
        XCTAssertEqual(result.nextCursor, "PROFILE-CURSOR")
        XCTAssertEqual(result.resolvedTarget?.userID, "777")
        XCTAssertNil(result.resolvedTarget?.username)
        XCTAssertEqual(result.tweets.count, 1)

        let tweet = try XCTUnwrap(result.tweets.first)
        XCTAssertEqual(tweet.id, "987654")
        XCTAssertEqual(tweet.text, "Expanded note")
        XCTAssertEqual(tweet.embeddedText, "Quoted hello")
        XCTAssertEqual(tweet.mediaURLs, ["https://img.example/1.jpg"])
        XCTAssertEqual(tweet.viewCount, 99)
        XCTAssertEqual(tweet.author.userID, "777")
        XCTAssertEqual(tweet.author.username, "openava")
        XCTAssertTrue(tweet.isQuote)
        XCTAssertFalse(tweet.isRetweet)
    }

    private func decodePayload<T: Decodable>(_ type: T.Type, from response: BridgeInvokeResponse) throws -> T {
        let data = try XCTUnwrap(response.payload?.data(using: .utf8))
        return try JSONDecoder().decode(type, from: data)
    }

    private func makeMockSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [XMockURLProtocol.self]
        return URLSession(configuration: configuration)
    }
}

private final class InMemoryXCredentialStore: @unchecked Sendable {
    var values: [String: String] = [:]

    var store: XCredentialStore {
        XCredentialStore(
            loadHandler: { [self] account in values[account] },
            saveHandler: { [self] account, value in
                values[account] = value
                return true
            },
            deleteHandler: { [self] account in
                values.removeValue(forKey: account)
                return true
            }
        )
    }
}

private final class XMockURLProtocol: URLProtocol {
    static var requestHandler: ((URLRequest) throws -> (HTTPURLResponse, Data))?

    override class func canInit(with request: URLRequest) -> Bool {
        request.url != nil
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        guard let handler = Self.requestHandler else {
            client?.urlProtocol(self, didFailWithError: NSError(domain: "XMockURLProtocol", code: 0))
            return
        }

        do {
            let (response, data) = try handler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}

private func decodeJSONObjectQueryItem(named name: String, from components: URLComponents) throws -> [String: Any] {
    let items = Dictionary(uniqueKeysWithValues: (components.queryItems ?? []).map { ($0.name, $0.value ?? "") })
    let data = try XCTUnwrap(items[name]?.data(using: .utf8))
    return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
}

private func makeJSONHTTPResponse(url: URL, object: [String: Any]) throws -> (HTTPURLResponse, Data) {
    let data = try JSONSerialization.data(withJSONObject: object)
    let response = try XCTUnwrap(HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "application/json"]))
    return (response, data)
}
