import Foundation
import OpenClawKit

nonisolated enum XServiceError: Error, LocalizedError {
    case invalidRequest(String)
    case authenticationRequired(String)
    case notFound(String)
    case rateLimited
    case invalidResponse(String)
    case unavailable(String)

    var errorDescription: String? {
        switch self {
        case let .invalidRequest(message):
            return "Invalid request: \(message)"
        case let .authenticationRequired(message):
            return message
        case let .notFound(message):
            return message
        case .rateLimited:
            return "X rate limited the request."
        case let .invalidResponse(message):
            return "Invalid X response: \(message)"
        case let .unavailable(message):
            return message
        }
    }
}

nonisolated enum XQueryOperation: String, Codable {
    case searchTweets = "search_tweets"
    case profileTweets = "profile_tweets"
    case followers
    case following
    case userProfiles = "user_profiles"
}

nonisolated enum XAuthAction: String, Codable {
    case set
    case clear
    case status
}

nonisolated struct XInlineAuth: Codable {
    let authToken: String?
    let csrfToken: String?
    let bearerToken: String?
}

nonisolated struct XSearchInput: Codable {
    let searchQuery: String?
    let query: String?
    let allWords: [String]?
    let anyWords: [String]?
    let exactPhrases: [String]?
    let excludeWords: [String]?
    let hashtagsAny: [String]?
    let hashtagsExclude: [String]?
    let fromUsers: [String]?
    let toUsers: [String]?
    let mentioningUsers: [String]?
    let lang: String?
    let tweetType: String?
    let verifiedOnly: Bool?
    let blueVerifiedOnly: Bool?
    let hasImages: Bool?
    let hasVideos: Bool?
    let hasLinks: Bool?
    let hasMentions: Bool?
    let hasHashtags: Bool?
    let minLikes: Int?
    let minReplies: Int?
    let minRetweets: Int?
    let place: String?
    let geocode: String?
    let near: String?
    let within: String?
    let since: String?
    let until: String?
}

nonisolated struct XQueryRequest: Codable {
    let operation: XQueryOperation
    let query: String?
    let search: XSearchInput?
    let username: String?
    let usernames: [String]?
    let userId: String?
    let cursor: String?
    let maxResults: Int?
    let displayType: String?
    let auth: XInlineAuth?
}

nonisolated struct XUserReference: Codable {
    let userID: String?
    let username: String?
    let name: String?
}

nonisolated struct XUserProfile: Codable {
    let userID: String?
    let username: String?
    let name: String?
    let description: String?
    let location: String?
    let createdAt: String?
    let followersCount: Int
    let followingCount: Int
    let statusesCount: Int
    let favouritesCount: Int
    let mediaCount: Int
    let listedCount: Int
    let verified: Bool
    let blueVerified: Bool
    let protected: Bool
    let profileImageURL: String?
    let profileBannerURL: String?
    let url: String?
    let profileURL: String?
}

nonisolated struct XTweet: Codable {
    let id: String
    let text: String
    let embeddedText: String?
    let createdAt: String?
    let replyCount: Int
    let likeCount: Int
    let retweetCount: Int
    let quoteCount: Int
    let viewCount: Int?
    let language: String?
    let source: String?
    let mediaURLs: [String]
    let tweetURL: String?
    let author: XUserReference
    let isRetweet: Bool
    let isQuote: Bool
}

nonisolated struct XResolvedTarget: Codable {
    let userID: String
    let username: String?
    let name: String?
    let profileURL: String?
}

nonisolated struct XAuthUsageSummary: Codable {
    let usedStoredCredentials: Bool
    let usedInlineCredentials: Bool
    let bootstrappedCSRFToken: Bool
}

nonisolated struct XQueryRequestSummary: Codable {
    let query: String?
    let username: String?
    let usernames: [String]?
    let userId: String?
    let maxResults: Int
    let cursor: String?
    let displayType: String?
}

nonisolated struct XQueryResult: Codable {
    let operation: XQueryOperation
    let request: XQueryRequestSummary
    let resolvedTarget: XResolvedTarget?
    let profiles: [XUserProfile]
    let tweets: [XTweet]
    let users: [XUserProfile]
    let nextCursor: String?
    let warnings: [String]
    let auth: XAuthUsageSummary
    let message: String
}

nonisolated struct XStoredAuthStatus: Codable {
    let hasStoredAuthToken: Bool
    let hasStoredCSRFToken: Bool
    let hasStoredBearerToken: Bool
    let canUseDefaultBearerToken: Bool
    let isReadyForAuthenticatedRequests: Bool
}

nonisolated struct XAuthConfigurationResult: Codable {
    let action: XAuthAction
    let status: XStoredAuthStatus
    let bootstrappedCSRFToken: Bool
    let message: String
}

nonisolated struct XCredentialStore {
    private nonisolated static let keychainService = "OpenAva.XService"

    let loadHandler: @Sendable (String) -> String?
    let saveHandler: @Sendable (String, String) -> Bool
    let deleteHandler: @Sendable (String) -> Bool

    nonisolated static let live = XCredentialStore(
        loadHandler: { account in
            GenericPasswordKeychainStore.loadString(service: keychainService, account: account)
        },
        saveHandler: { account, value in
            GenericPasswordKeychainStore.saveString(value, service: keychainService, account: account)
        },
        deleteHandler: { account in
            GenericPasswordKeychainStore.delete(service: keychainService, account: account)
        }
    )

    nonisolated func load(account: String) -> String? {
        loadHandler(account)
    }

    @discardableResult
    nonisolated func save(account: String, value: String) -> Bool {
        saveHandler(account, value)
    }

    @discardableResult
    nonisolated func delete(account: String) -> Bool {
        deleteHandler(account)
    }
}

private nonisolated struct XResolvedCredentials {
    let authToken: String
    let csrfToken: String
    let bearerToken: String
    let usedStoredCredentials: Bool
    let usedInlineCredentials: Bool
    let bootstrappedCSRFToken: Bool
}

private nonisolated enum XManifestOperation: String {
    case searchTimeline = "search_timeline"
    case userLookupScreenName = "user_lookup_screen_name"
    case profileTimeline = "profile_timeline"
    case followers
    case following
}

actor XService {
    private enum StorageKey {
        static let authToken = "auth_token"
        static let csrfToken = "csrf_token"
        static let bearerToken = "bearer_token"
    }

    private struct TimelineExtraction<T> {
        let items: [T]
        let cursor: String?
    }

    private static let defaultTimeoutSeconds: TimeInterval = 20
    private static let baseURL = URL(string: "https://x.com")!
    private static let homeURL = URL(string: "https://x.com/home")!
    private static let defaultBearerToken = "AAAAAAAAAAAAAAAAAAAAANRILgAAAAAAnNwIzUejRCOuH5E6I8xnZz4puTs%3D1Zv7ttfk8LF81IUq16cHjhLTvJu4FA33AGWWjCpTnA"
    private static let userAgent = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/122.0.0.0 Safari/537.36"

    private static let queryIDs: [XManifestOperation: String] = [
        .searchTimeline: "rkp6b4vtR9u7v3naGoOzUQ",
        .userLookupScreenName: "IGgvgiOx4QZndDHuD3x9TQ",
        .profileTimeline: "O0epvwaQPUx-bT9YlqlL6w",
        .followers: "Enf9DNUZYiT037aersI5gg",
        .following: "ntIPnH1WMBKW--4Tn1q71A",
    ]

    private static let endpoints: [XManifestOperation: String] = [
        .searchTimeline: "https://x.com/i/api/graphql/{query_id}/SearchTimeline",
        .userLookupScreenName: "https://x.com/i/api/graphql/{query_id}/UserByScreenName",
        .profileTimeline: "https://x.com/i/api/graphql/{query_id}/UserTweets",
        .followers: "https://x.com/i/api/graphql/{query_id}/Followers",
        .following: "https://x.com/i/api/graphql/{query_id}/Following",
    ]

    private static let globalFeatures: [String: Bool] = [
        "rweb_video_screen_enabled": false,
        "profile_label_improvements_pcf_label_in_post_enabled": true,
        "responsive_web_profile_redirect_enabled": false,
        "rweb_tipjar_consumption_enabled": false,
        "verified_phone_label_enabled": false,
        "creator_subscriptions_tweet_preview_api_enabled": true,
        "responsive_web_graphql_timeline_navigation_enabled": true,
        "responsive_web_graphql_skip_user_profile_image_extensions_enabled": false,
        "premium_content_api_read_enabled": false,
        "communities_web_enable_tweet_community_results_fetch": true,
        "c9s_tweet_anatomy_moderator_badge_enabled": true,
        "responsive_web_grok_analyze_button_fetch_trends_enabled": false,
        "responsive_web_grok_analyze_post_followups_enabled": true,
        "responsive_web_jetfuel_frame": true,
        "responsive_web_grok_share_attachment_enabled": true,
        "responsive_web_grok_annotations_enabled": false,
        "articles_preview_enabled": true,
        "responsive_web_edit_tweet_api_enabled": true,
        "graphql_is_translatable_rweb_tweet_is_translatable_enabled": true,
        "view_counts_everywhere_api_enabled": true,
        "longform_notetweets_consumption_enabled": true,
        "responsive_web_twitter_article_tweet_consumption_enabled": true,
        "tweet_awards_web_tipping_enabled": false,
        "responsive_web_grok_show_grok_translated_post": false,
        "responsive_web_grok_analysis_button_from_backend": true,
        "post_ctas_fetch_enabled": true,
        "creator_subscriptions_quote_tweet_preview_enabled": false,
        "freedom_of_speech_not_reach_fetch_enabled": true,
        "standardized_nudges_misinfo": true,
        "tweet_with_visibility_results_prefer_gql_limited_actions_policy_enabled": true,
        "longform_notetweets_rich_text_read_enabled": true,
        "longform_notetweets_inline_media_enabled": true,
        "responsive_web_grok_image_annotation_enabled": true,
        "responsive_web_grok_imagine_annotation_enabled": true,
        "responsive_web_grok_community_note_auto_translation_is_enabled": false,
        "responsive_web_enhance_cards_enabled": false,
    ]

    private static let followsRequiredFeatures: [String: Bool] = [
        "rweb_video_screen_enabled": false,
        "profile_label_improvements_pcf_label_in_post_enabled": true,
        "responsive_web_profile_redirect_enabled": false,
        "rweb_tipjar_consumption_enabled": false,
        "verified_phone_label_enabled": false,
        "creator_subscriptions_tweet_preview_api_enabled": true,
        "responsive_web_graphql_timeline_navigation_enabled": true,
        "responsive_web_graphql_skip_user_profile_image_extensions_enabled": false,
        "premium_content_api_read_enabled": false,
        "communities_web_enable_tweet_community_results_fetch": true,
        "c9s_tweet_anatomy_moderator_badge_enabled": true,
        "responsive_web_grok_analyze_button_fetch_trends_enabled": false,
        "responsive_web_grok_analyze_post_followups_enabled": true,
        "responsive_web_jetfuel_frame": true,
        "responsive_web_grok_share_attachment_enabled": true,
        "responsive_web_grok_annotations_enabled": true,
        "articles_preview_enabled": true,
        "responsive_web_edit_tweet_api_enabled": true,
        "graphql_is_translatable_rweb_tweet_is_translatable_enabled": true,
        "view_counts_everywhere_api_enabled": true,
        "longform_notetweets_consumption_enabled": true,
        "responsive_web_twitter_article_tweet_consumption_enabled": true,
        "tweet_awards_web_tipping_enabled": false,
        "responsive_web_grok_show_grok_translated_post": false,
        "responsive_web_grok_analysis_button_from_backend": true,
        "post_ctas_fetch_enabled": true,
        "creator_subscriptions_quote_tweet_preview_enabled": false,
        "freedom_of_speech_not_reach_fetch_enabled": true,
        "standardized_nudges_misinfo": true,
        "tweet_with_visibility_results_prefer_gql_limited_actions_policy_enabled": true,
        "longform_notetweets_rich_text_read_enabled": true,
        "longform_notetweets_inline_media_enabled": true,
        "responsive_web_grok_image_annotation_enabled": true,
        "responsive_web_grok_imagine_annotation_enabled": true,
        "responsive_web_grok_community_note_auto_translation_is_enabled": false,
        "responsive_web_enhance_cards_enabled": false,
        "tweetypie_unmention_optimization_enabled": true,
        "responsive_web_twitter_blue_verified_badge_is_enabled": true,
        "vibe_api_enabled": false,
        "responsive_web_graphql_exclude_directive_enabled": true,
        "longform_notetweets_richtext_consumption_enabled": true,
    ]

    private static let operationFeatures: [XManifestOperation: [String: Bool]] = [
        .userLookupScreenName: [
            "hidden_profile_subscriptions_enabled": true,
            "subscriptions_verification_info_is_identity_verified_enabled": true,
            "subscriptions_verification_info_verified_since_enabled": true,
            "highlights_tweets_tab_ui_enabled": true,
            "responsive_web_twitter_article_notes_tab_enabled": true,
            "subscriptions_feature_can_gift_premium": true,
        ],
    ]

    private static let fieldToggles: [XManifestOperation: [String: Bool]] = [
        .userLookupScreenName: [
            "withPayments": false,
            "withAuxiliaryUserLabels": true,
        ],
        .profileTimeline: [
            "withArticlePlainText": false,
        ],
    ]

    private let session: URLSession
    private let credentialStore: XCredentialStore

    init(
        timeoutSeconds: TimeInterval = defaultTimeoutSeconds,
        credentialStore: XCredentialStore = .live
    ) {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = timeoutSeconds
        configuration.timeoutIntervalForResource = timeoutSeconds
        configuration.httpShouldSetCookies = true
        session = URLSession(configuration: configuration)
        self.credentialStore = credentialStore
    }

    init(session: URLSession, credentialStore: XCredentialStore = .live) {
        self.session = session
        self.credentialStore = credentialStore
    }

    func configureAuth(action: XAuthAction, credentials: XInlineAuth?) async throws -> XAuthConfigurationResult {
        switch action {
        case .status:
            let status = storedAuthStatus()
            return XAuthConfigurationResult(
                action: action,
                status: status,
                bootstrappedCSRFToken: false,
                message: status.isReadyForAuthenticatedRequests
                    ? "Stored X credentials are ready."
                    : "Stored X credentials are incomplete. Save an auth_token and ct0/CSRF token first."
            )

        case .clear:
            _ = credentialStore.delete(account: StorageKey.authToken)
            _ = credentialStore.delete(account: StorageKey.csrfToken)
            _ = credentialStore.delete(account: StorageKey.bearerToken)
            return XAuthConfigurationResult(
                action: action,
                status: storedAuthStatus(),
                bootstrappedCSRFToken: false,
                message: "Cleared stored X credentials."
            )

        case .set:
            let explicitCredentials = try await normalizeCredentials(
                inline: credentials,
                fallbackToStored: false,
                allowBootstrap: true
            )

            guard credentialStore.save(account: StorageKey.authToken, value: explicitCredentials.authToken) else {
                throw XServiceError.unavailable("Failed to save X auth_token to the keychain.")
            }
            guard credentialStore.save(account: StorageKey.csrfToken, value: explicitCredentials.csrfToken) else {
                throw XServiceError.unavailable("Failed to save X ct0/CSRF token to the keychain.")
            }
            if !explicitCredentials.bearerToken.isEmpty,
               !credentialStore.save(account: StorageKey.bearerToken, value: explicitCredentials.bearerToken)
            {
                throw XServiceError.unavailable("Failed to save X bearer token to the keychain.")
            }

            return XAuthConfigurationResult(
                action: action,
                status: storedAuthStatus(),
                bootstrappedCSRFToken: explicitCredentials.bootstrappedCSRFToken,
                message: explicitCredentials.bootstrappedCSRFToken
                    ? "Saved X credentials and bootstrapped the ct0/CSRF token from auth_token."
                    : "Saved X credentials."
            )
        }
    }

    nonisolated static func buildEffectiveSearchQueryForTesting(
        query: String?,
        search: XSearchInput?
    ) throws -> String {
        let baseQuery = nonEmpty(query) ?? nonEmpty(search?.searchQuery) ?? nonEmpty(search?.query) ?? ""
        var parts: [String] = []
        if !baseQuery.isEmpty {
            parts.append(baseQuery)
        }

        let allWords = normalizeStringList(search?.allWords).compactMap(formatQueryTerm)
        if !allWords.isEmpty {
            parts.append("(\(allWords.joined(separator: " AND ")))")
        }

        let anyWords = normalizeStringList(search?.anyWords).compactMap(formatQueryTerm)
        if !anyWords.isEmpty {
            parts.append("(\(anyWords.joined(separator: " OR ")))")
        }

        let exactPhrases = normalizeStringList(search?.exactPhrases).compactMap(formatQueryTerm)
        if !exactPhrases.isEmpty {
            parts.append("(\(exactPhrases.joined(separator: " AND ")))")
        }

        let excludeWords = normalizeStringList(search?.excludeWords).compactMap(formatQueryTerm)
        for word in excludeWords {
            parts.append("-\(word)")
        }

        let hashtagsAny = normalizeStringList(search?.hashtagsAny).compactMap(normalizeHashtag)
        if !hashtagsAny.isEmpty {
            parts.append("(\(hashtagsAny.joined(separator: " OR ")))")
        }

        let hashtagsExclude = normalizeStringList(search?.hashtagsExclude).compactMap(normalizeHashtag)
        for hashtag in hashtagsExclude {
            parts.append("-\(hashtag)")
        }

        if !queryHasOperator(baseQuery, name: "from"),
           let fromGroup = buildOperatorGroup(name: "from", values: normalizeUsernameList(search?.fromUsers ?? []))
        {
            parts.append(fromGroup)
        }

        if !queryHasOperator(baseQuery, name: "to"),
           let toGroup = buildOperatorGroup(name: "to", values: normalizeUsernameList(search?.toUsers ?? []))
        {
            parts.append(toGroup)
        }

        let mentions = normalizeUsernameList(search?.mentioningUsers ?? [])
        if !mentions.isEmpty {
            let mentionItems = mentions.map { "@\($0)" }
            parts.append(mentionItems.count == 1 ? mentionItems[0] : "(\(mentionItems.joined(separator: " OR ")))")
        }

        if let lang = nonEmpty(search?.lang), !queryHasOperator(baseQuery, name: "lang") {
            parts.append("lang:\(lang)")
        }

        if !queryHasAnyFilterOperator(baseQuery) {
            for filterToken in tweetTypeFilterTokens(normalizeTweetType(search?.tweetType)) {
                parts.append(filterToken)
            }

            let filterFlags: [(Bool, String)] = [
                (search?.verifiedOnly ?? false, "verified"),
                (search?.blueVerifiedOnly ?? false, "blue_verified"),
                (search?.hasImages ?? false, "images"),
                (search?.hasVideos ?? false, "videos"),
                (search?.hasLinks ?? false, "links"),
                (search?.hasMentions ?? false, "mentions"),
                (search?.hasHashtags ?? false, "hashtags"),
            ]
            for flag in filterFlags where flag.0 {
                parts.append("filter:\(flag.1)")
            }
        }

        if !queryHasAnyMinOperator(baseQuery) {
            if max(search?.minLikes ?? 0, 0) > 0 {
                parts.append("min_faves:\(max(search?.minLikes ?? 0, 0))")
            }
            if max(search?.minReplies ?? 0, 0) > 0 {
                parts.append("min_replies:\(max(search?.minReplies ?? 0, 0))")
            }
            if max(search?.minRetweets ?? 0, 0) > 0 {
                parts.append("min_retweets:\(max(search?.minRetweets ?? 0, 0))")
            }
        }

        if let since = nonEmpty(search?.since), !queryHasOperator(baseQuery, name: "since") {
            parts.append("since:\(queryTimeToken(since))")
        }
        if let until = nonEmpty(search?.until), !queryHasOperator(baseQuery, name: "until") {
            parts.append("until:\(queryTimeToken(until))")
        }

        if !["place", "geocode", "near", "within"].contains(where: { queryHasOperator(baseQuery, name: $0) }) {
            if let place = nonEmpty(search?.place) {
                parts.append("place:\(place)")
            } else if let geocode = nonEmpty(search?.geocode) {
                parts.append("geocode:\(geocode)")
            } else if let near = nonEmpty(search?.near) {
                parts.append("near:\(near)")
                if let within = nonEmpty(search?.within) {
                    parts.append("within:\(within)")
                }
            } else if let within = nonEmpty(search?.within) {
                parts.append("within:\(within)")
            }
        }

        let effectiveQuery = parts.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !effectiveQuery.isEmpty else {
            throw XServiceError.invalidRequest("query or search fields are required for search_tweets")
        }
        return effectiveQuery
    }

    func query(_ request: XQueryRequest) async throws -> XQueryResult {
        let maxResults = Self.clampCount(request.maxResults)
        let credentials = try await normalizeCredentials(
            inline: request.auth,
            fallbackToStored: true,
            allowBootstrap: true
        )
        let authUsage = XAuthUsageSummary(
            usedStoredCredentials: credentials.usedStoredCredentials,
            usedInlineCredentials: credentials.usedInlineCredentials,
            bootstrappedCSRFToken: credentials.bootstrappedCSRFToken
        )

        switch request.operation {
        case .userProfiles:
            let usernames = Self.normalizeUsernameList(
                request.usernames ?? (Self.nonEmpty(request.username).map { [$0] } ?? [])
            )
            guard !usernames.isEmpty else {
                throw XServiceError.invalidRequest("username or usernames is required for user_profiles")
            }

            var profiles: [XUserProfile] = []
            var warnings: [String] = []
            for username in usernames {
                do {
                    try profiles.append(await lookupUserProfile(username: username, credentials: credentials))
                } catch let error as XServiceError {
                    switch error {
                    case let .notFound(message):
                        warnings.append(message)
                    default:
                        throw error
                    }
                }
            }

            return XQueryResult(
                operation: request.operation,
                request: XQueryRequestSummary(
                    query: nil,
                    username: nil,
                    usernames: usernames,
                    userId: nil,
                    maxResults: maxResults,
                    cursor: nil,
                    displayType: nil
                ),
                resolvedTarget: nil,
                profiles: profiles,
                tweets: [],
                users: [],
                nextCursor: nil,
                warnings: warnings,
                auth: authUsage,
                message: profiles.isEmpty
                    ? "No X profiles were resolved."
                    : "Resolved \(profiles.count) X profile(s)."
            )

        case .searchTweets:
            let rawQuery = try Self.buildEffectiveSearchQueryForTesting(query: request.query, search: request.search)
            let displayType = Self.normalizeDisplayType(request.displayType)
            let payload = try await performGraphQLRequest(
                operation: .searchTimeline,
                params: Self.buildSearchParams(
                    rawQuery: rawQuery,
                    count: maxResults,
                    cursor: Self.nonEmpty(request.cursor),
                    displayType: displayType
                ),
                credentials: credentials
            )
            let extraction = Self.extractSearchTweetsAndCursor(from: payload)
            return XQueryResult(
                operation: request.operation,
                request: XQueryRequestSummary(
                    query: rawQuery,
                    username: nil,
                    usernames: nil,
                    userId: nil,
                    maxResults: maxResults,
                    cursor: Self.nonEmpty(request.cursor),
                    displayType: displayType
                ),
                resolvedTarget: nil,
                profiles: [],
                tweets: extraction.items,
                users: [],
                nextCursor: extraction.cursor,
                warnings: [],
                auth: authUsage,
                message: extraction.items.isEmpty
                    ? "No posts matched the X search query."
                    : "Found \(extraction.items.count) post(s) for the X search query."
            )

        case .profileTweets:
            let target = try await resolveTarget(
                username: request.username,
                userID: request.userId,
                credentials: credentials
            )
            let payload = try await performGraphQLRequest(
                operation: .profileTimeline,
                params: Self.buildProfileTimelineParams(
                    userID: target.userID,
                    count: maxResults,
                    cursor: Self.nonEmpty(request.cursor)
                ),
                credentials: credentials
            )
            let extraction = Self.extractProfileTweetsAndCursor(from: payload)
            return XQueryResult(
                operation: request.operation,
                request: XQueryRequestSummary(
                    query: nil,
                    username: request.username,
                    usernames: nil,
                    userId: target.userID,
                    maxResults: maxResults,
                    cursor: Self.nonEmpty(request.cursor),
                    displayType: nil
                ),
                resolvedTarget: target,
                profiles: [],
                tweets: extraction.items,
                users: [],
                nextCursor: extraction.cursor,
                warnings: [],
                auth: authUsage,
                message: extraction.items.isEmpty
                    ? "No profile tweets were returned."
                    : "Fetched \(extraction.items.count) profile tweet(s)."
            )

        case .followers, .following:
            let target = try await resolveTarget(
                username: request.username,
                userID: request.userId,
                credentials: credentials
            )
            let manifestOperation: XManifestOperation = request.operation == .followers ? .followers : .following
            let payload = try await performGraphQLRequest(
                operation: manifestOperation,
                params: Self.buildFollowsParams(
                    userID: target.userID,
                    count: maxResults,
                    cursor: Self.nonEmpty(request.cursor),
                    operation: manifestOperation
                ),
                credentials: credentials
            )
            let extraction = Self.extractFollowUsersAndCursor(from: payload)
            return XQueryResult(
                operation: request.operation,
                request: XQueryRequestSummary(
                    query: nil,
                    username: request.username,
                    usernames: nil,
                    userId: target.userID,
                    maxResults: maxResults,
                    cursor: Self.nonEmpty(request.cursor),
                    displayType: nil
                ),
                resolvedTarget: target,
                profiles: [],
                tweets: [],
                users: extraction.items,
                nextCursor: extraction.cursor,
                warnings: [],
                auth: authUsage,
                message: extraction.items.isEmpty
                    ? "No \(request.operation.rawValue) records were returned."
                    : "Fetched \(extraction.items.count) \(request.operation.rawValue) record(s)."
            )
        }
    }

    private func storedAuthStatus() -> XStoredAuthStatus {
        let storedAuthToken = Self.nonEmpty(credentialStore.load(account: StorageKey.authToken))
        let storedCSRF = Self.nonEmpty(credentialStore.load(account: StorageKey.csrfToken))
        let storedBearer = Self.nonEmpty(credentialStore.load(account: StorageKey.bearerToken))
        let defaultBearerAvailable = !Self.defaultBearerToken.isEmpty
        return XStoredAuthStatus(
            hasStoredAuthToken: storedAuthToken != nil,
            hasStoredCSRFToken: storedCSRF != nil,
            hasStoredBearerToken: storedBearer != nil,
            canUseDefaultBearerToken: defaultBearerAvailable,
            isReadyForAuthenticatedRequests: storedAuthToken != nil && storedCSRF != nil && (storedBearer != nil || defaultBearerAvailable)
        )
    }

    private func normalizeCredentials(
        inline: XInlineAuth?,
        fallbackToStored: Bool,
        allowBootstrap: Bool
    ) async throws -> XResolvedCredentials {
        let inlineAuthToken = Self.nonEmpty(inline?.authToken)
        let inlineCSRF = Self.nonEmpty(inline?.csrfToken)
        let inlineBearer = Self.normalizeBearerToken(inline?.bearerToken)

        let storedAuthToken = fallbackToStored ? Self.nonEmpty(credentialStore.load(account: StorageKey.authToken)) : nil
        let storedCSRF = fallbackToStored ? Self.nonEmpty(credentialStore.load(account: StorageKey.csrfToken)) : nil
        let storedBearer = fallbackToStored ? Self.normalizeBearerToken(credentialStore.load(account: StorageKey.bearerToken)) : nil

        let authToken = inlineAuthToken ?? storedAuthToken
        guard let authToken else {
            throw XServiceError.authenticationRequired(
                "X auth_token is required. Save credentials with x_auth or pass auth.authToken inline."
            )
        }

        var csrfToken = inlineCSRF ?? storedCSRF
        var bootstrappedCSRFToken = false
        if csrfToken == nil, allowBootstrap {
            csrfToken = try await bootstrapCSRFToken(authToken: authToken)
            bootstrappedCSRFToken = csrfToken != nil
        }
        guard let csrfToken else {
            throw XServiceError.authenticationRequired(
                "X ct0/CSRF token is required. Save credentials with x_auth or pass auth.csrfToken inline."
            )
        }

        let bearerToken = inlineBearer ?? storedBearer ?? Self.defaultBearerToken
        guard !bearerToken.isEmpty else {
            throw XServiceError.authenticationRequired("X bearer token is missing.")
        }

        return XResolvedCredentials(
            authToken: authToken,
            csrfToken: csrfToken,
            bearerToken: bearerToken,
            usedStoredCredentials: fallbackToStored && (inlineAuthToken == nil || inlineCSRF == nil || inlineBearer == nil),
            usedInlineCredentials: inlineAuthToken != nil || inlineCSRF != nil || inlineBearer != nil,
            bootstrappedCSRFToken: bootstrappedCSRFToken
        )
    }

    private func bootstrapCSRFToken(authToken: String) async throws -> String? {
        var request = URLRequest(url: Self.homeURL)
        request.httpMethod = "GET"
        request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8", forHTTPHeaderField: "Accept")
        request.setValue("auth_token=\(authToken)", forHTTPHeaderField: "Cookie")

        let (_, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw XServiceError.invalidResponse("missing HTTPURLResponse during auth bootstrap")
        }
        if http.statusCode == 401 || http.statusCode == 403 {
            throw XServiceError.authenticationRequired("X rejected the auth_token while bootstrapping ct0/CSRF.")
        }
        guard (200 ... 399).contains(http.statusCode) else {
            throw XServiceError.unavailable("X auth bootstrap failed with HTTP \(http.statusCode).")
        }

        let cookieHeaders = http.allHeaderFields.reduce(into: [String: String]()) { partialResult, item in
            partialResult[String(describing: item.key)] = String(describing: item.value)
        }
        let cookies = HTTPCookie.cookies(withResponseHeaderFields: cookieHeaders, for: Self.baseURL)
        return cookies.first(where: { $0.name.lowercased() == "ct0" })?.value
    }

    private func lookupUserProfile(
        username: String,
        credentials: XResolvedCredentials
    ) async throws -> XUserProfile {
        guard let normalizedUsername = Self.normalizeUsername(username) else {
            throw XServiceError.invalidRequest("Invalid X username: \(username)")
        }
        let payload = try await performGraphQLRequest(
            operation: .userLookupScreenName,
            params: Self.buildUserLookupParams(username: normalizedUsername),
            credentials: credentials
        )
        guard let userResult = Self.extractUserResult(from: payload) else {
            throw XServiceError.notFound("X user @\(normalizedUsername) was not found.")
        }
        let profile = Self.mapUserResultToProfile(userResult, fallbackUsername: normalizedUsername)
        guard profile.userID != nil || profile.username != nil else {
            throw XServiceError.notFound("X user @\(normalizedUsername) was not found.")
        }
        return profile
    }

    private func resolveTarget(
        username: String?,
        userID: String?,
        credentials: XResolvedCredentials
    ) async throws -> XResolvedTarget {
        if let normalizedUserID = Self.nonEmpty(userID) {
            let normalizedUsername = Self.normalizeUsername(username)
            return XResolvedTarget(
                userID: normalizedUserID,
                username: normalizedUsername,
                name: nil,
                profileURL: normalizedUsername.map { "https://x.com/\($0)" }
            )
        }

        guard let username, let normalizedUsername = Self.normalizeUsername(username) else {
            throw XServiceError.invalidRequest("username or userId is required")
        }

        let profile = try await lookupUserProfile(username: normalizedUsername, credentials: credentials)
        guard let resolvedUserID = Self.nonEmpty(profile.userID) else {
            throw XServiceError.notFound("X user @\(normalizedUsername) was not found.")
        }
        return XResolvedTarget(
            userID: resolvedUserID,
            username: profile.username,
            name: profile.name,
            profileURL: profile.profileURL
        )
    }

    private func performGraphQLRequest(
        operation: XManifestOperation,
        params: [String: String],
        credentials: XResolvedCredentials
    ) async throws -> [String: Any] {
        let url = try Self.endpointURL(for: operation, params: params)
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("https://x.com/", forHTTPHeaderField: "Referer")
        request.setValue("https://x.com", forHTTPHeaderField: "Origin")
        request.setValue("en", forHTTPHeaderField: "X-Twitter-Client-Language")
        request.setValue("yes", forHTTPHeaderField: "X-Twitter-Active-User")
        request.setValue("OAuth2Session", forHTTPHeaderField: "X-Twitter-Auth-Type")
        request.setValue("Bearer \(credentials.bearerToken)", forHTTPHeaderField: "Authorization")
        request.setValue(credentials.csrfToken, forHTTPHeaderField: "X-Csrf-Token")
        request.setValue("auth_token=\(credentials.authToken); ct0=\(credentials.csrfToken)", forHTTPHeaderField: "Cookie")

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw XServiceError.invalidResponse("missing HTTPURLResponse")
        }

        let jsonObject = try? JSONSerialization.jsonObject(with: data)
        let payload = jsonObject as? [String: Any]
        if let mappedError = Self.mapGraphQLError(statusCode: http.statusCode, payload: payload) {
            throw mappedError
        }

        guard (200 ... 299).contains(http.statusCode) else {
            throw Self.mapHTTPStatus(http.statusCode, fallbackPayload: payload)
        }
        guard let payload else {
            throw XServiceError.invalidResponse("response body was not valid JSON")
        }
        return payload
    }

    private static func buildUserLookupParams(username: String) throws -> [String: String] {
        var params: [String: String] = try [
            "variables": encodeJSON([
                "screen_name": username,
                "withGrokTranslatedBio": false,
            ]),
            "features": encodeJSON(features(for: .userLookupScreenName)),
        ]
        if let toggles = fieldToggles[.userLookupScreenName] {
            params["fieldToggles"] = try encodeJSON(toggles)
        }
        return params
    }

    private static func buildSearchParams(
        rawQuery: String,
        count: Int,
        cursor: String?,
        displayType: String
    ) throws -> [String: String] {
        let product = displayType == "top" ? "Top" : "Latest"
        var variables: [String: Any] = [
            "rawQuery": rawQuery,
            "count": count,
            "querySource": "typed_query",
            "product": product,
            "withGrokTranslatedBio": false,
        ]
        if let cursor {
            variables["cursor"] = cursor
        }
        return try [
            "variables": encodeJSON(variables),
            "features": encodeJSON(features(for: .searchTimeline)),
        ]
    }

    private static func buildProfileTimelineParams(
        userID: String,
        count: Int,
        cursor: String?
    ) throws -> [String: String] {
        var variables: [String: Any] = [
            "userId": userID,
            "count": count,
            "includePromotedContent": true,
            "withQuickPromoteEligibilityTweetFields": true,
            "withVoice": true,
        ]
        if let cursor {
            variables["cursor"] = cursor
        }

        var params: [String: String] = try [
            "variables": encodeJSON(variables),
            "features": encodeJSON(features(for: .profileTimeline)),
        ]
        if let toggles = fieldToggles[.profileTimeline] {
            params["fieldToggles"] = try encodeJSON(toggles)
        }
        return params
    }

    private static func buildFollowsParams(
        userID: String,
        count: Int,
        cursor: String?,
        operation: XManifestOperation
    ) throws -> [String: String] {
        var variables: [String: Any] = [
            "userId": userID,
            "count": count,
            "includePromotedContent": false,
            "withGrokTranslatedBio": false,
        ]
        if let cursor {
            variables["cursor"] = cursor
        }

        return try [
            "variables": encodeJSON(variables),
            "features": encodeJSON(features(for: operation)),
        ]
    }

    private static func endpointURL(for operation: XManifestOperation, params: [String: String]) throws -> URL {
        guard let endpointTemplate = endpoints[operation], let queryID = queryIDs[operation] else {
            throw XServiceError.invalidRequest("Missing endpoint configuration for \(operation.rawValue)")
        }
        guard var components = URLComponents(string: endpointTemplate.replacingOccurrences(of: "{query_id}", with: queryID)) else {
            throw XServiceError.invalidRequest("Failed to build X endpoint URL")
        }
        components.queryItems = params.map { URLQueryItem(name: $0.key, value: $0.value) }
        guard let url = components.url else {
            throw XServiceError.invalidRequest("Failed to encode X GraphQL query parameters")
        }
        return url
    }

    private static func features(for operation: XManifestOperation) -> [String: Bool] {
        var resolved = globalFeatures
        if let overrides = operationFeatures[operation] {
            for (key, value) in overrides {
                resolved[key] = value
            }
        }
        if operation == .followers || operation == .following {
            for (key, value) in followsRequiredFeatures {
                resolved[key] = value
            }
        }
        return resolved
    }

    private static func mapHTTPStatus(_ statusCode: Int, fallbackPayload: [String: Any]?) -> XServiceError {
        switch statusCode {
        case 401, 403:
            return .authenticationRequired("X authentication failed. Refresh auth_token and ct0/CSRF credentials.")
        case 404:
            return .notFound("The requested X resource was not found.")
        case 429:
            return .rateLimited
        case 400 ..< 500:
            return .invalidRequest(firstErrorMessage(in: fallbackPayload) ?? "X rejected the request with HTTP \(statusCode).")
        default:
            return .unavailable("X request failed with HTTP \(statusCode).")
        }
    }

    private static func mapGraphQLError(statusCode: Int, payload: [String: Any]?) -> XServiceError? {
        guard let payload,
              let errors = payload["errors"] as? [[String: Any]],
              !errors.isEmpty
        else {
            return nil
        }

        let message = errors.compactMap { nonEmpty($0["message"]) }.joined(separator: " | ")
        let lowered = message.lowercased()
        let codes = errors.compactMap { error -> String? in
            let extensions = error["extensions"] as? [String: Any]
            return nonEmpty(extensions?["code"])?.uppercased() ?? nonEmpty(extensions?["errorType"])?.uppercased()
        }

        if lowered.contains("rate limit") || lowered.contains("too many requests") || statusCode == 429 || codes.contains(where: { $0.contains("RATE") }) {
            return .rateLimited
        }
        if statusCode == 401 || statusCode == 403 || lowered.contains("csrf") || lowered.contains("authentication") || lowered.contains("authorization") {
            return .authenticationRequired("X authentication failed. Refresh auth_token and ct0/CSRF credentials.")
        }
        if lowered.contains("not found") || lowered.contains("could not find user") || lowered.contains("user unavailable") {
            return .notFound(message.isEmpty ? "The requested X resource was not found." : message)
        }
        return .invalidRequest(message.isEmpty ? "X returned GraphQL errors." : message)
    }

    private static func firstErrorMessage(in payload: [String: Any]?) -> String? {
        guard let payload,
              let errors = payload["errors"] as? [[String: Any]]
        else {
            return nil
        }
        return errors.compactMap { nonEmpty($0["message"]) }.first
    }

    private static func extractUserResult(from payload: [String: Any]) -> [String: Any]? {
        let dataNode = payload["data"] as? [String: Any]
        let userNode = dataNode?["user"] as? [String: Any]
        let result = userNode?["result"] as? [String: Any]
        guard let result else { return nil }
        if nonEmpty(result["__typename"]) == "UserUnavailable" {
            return nil
        }
        return result
    }

    private static func mapUserResultToProfile(_ userResult: [String: Any], fallbackUsername: String? = nil) -> XUserProfile {
        let legacy = userResult["legacy"] as? [String: Any] ?? [:]
        let core = userResult["core"] as? [String: Any] ?? [:]
        let verification = userResult["verification"] as? [String: Any] ?? [:]
        let privacy = userResult["privacy"] as? [String: Any] ?? [:]
        let avatar = userResult["avatar"] as? [String: Any] ?? [:]
        let locationNode = userResult["location"] as? [String: Any] ?? [:]
        let profileBio = userResult["profile_bio"] as? [String: Any] ?? [:]
        let entities = legacy["entities"] as? [String: Any] ?? [:]

        var resolvedURL = nonEmpty(legacy["url"])
        if resolvedURL == nil,
           let urlNode = entities["url"] as? [String: Any],
           let urlRows = urlNode["urls"] as? [[String: Any]]
        {
            for row in urlRows {
                resolvedURL = firstNonEmptyString(row["expanded_url"], row["url"], row["display_url"])
                if resolvedURL != nil {
                    break
                }
            }
        }

        let userID = firstNonEmptyString(userResult["rest_id"], userResult["id"], legacy["id_str"])
        let username = firstNonEmptyString(legacy["screen_name"], core["screen_name"], fallbackUsername)
        let verified = boolValue(legacy["verified"]) || boolValue(verification["verified"])
        let blueVerified = boolValue(userResult["is_blue_verified"]) || boolValue(verification["is_blue_verified"])
        let protected = boolValue(legacy["protected"]) || boolValue(privacy["protected"])

        return XUserProfile(
            userID: userID,
            username: username,
            name: firstNonEmptyString(legacy["name"], core["name"]),
            description: firstNonEmptyString(legacy["description"], profileBio["description"]),
            location: firstNonEmptyString(legacy["location"], locationNode["location"]),
            createdAt: firstNonEmptyString(legacy["created_at"], core["created_at"]),
            followersCount: intValue(legacy["followers_count"]),
            followingCount: intValue(legacy["friends_count"]),
            statusesCount: intValue(legacy["statuses_count"]),
            favouritesCount: intValue(legacy["favourites_count"]),
            mediaCount: intValue(legacy["media_count"]),
            listedCount: intValue(legacy["listed_count"]),
            verified: verified,
            blueVerified: blueVerified,
            protected: protected,
            profileImageURL: firstNonEmptyString(legacy["profile_image_url_https"], legacy["profile_image_url"], avatar["image_url"]),
            profileBannerURL: firstNonEmptyString(legacy["profile_banner_url"], avatar["banner_image_url"]),
            url: resolvedURL,
            profileURL: username.map { "https://x.com/\($0)" }
        )
    }

    private static func extractSearchTweetsAndCursor(from payload: [String: Any]) -> TimelineExtraction<XTweet> {
        let instructions = ((((payload["data"] as? [String: Any])?["search_by_raw_query"] as? [String: Any])?["search_timeline"] as? [String: Any])?["timeline"] as? [String: Any])?["instructions"] as? [[String: Any]] ?? []
        return extractTweetsAndCursor(fromInstructions: instructions)
    }

    private static func extractProfileTweetsAndCursor(from payload: [String: Any]) -> TimelineExtraction<XTweet> {
        extractTweetsAndCursor(fromInstructions: extractProfileTimelineInstructions(from: payload))
    }

    private static func extractFollowUsersAndCursor(from payload: [String: Any]) -> TimelineExtraction<XUserProfile> {
        let instructions = extractProfileTimelineInstructions(from: payload)
        var users: [XUserProfile] = []
        var cursor: String?
        var seen = Set<String>()

        for instruction in instructions {
            for entry in extractEntries(from: instruction) {
                let entryID = nonEmpty(entry["entryId"]) ?? ""
                let content = entry["content"] as? [String: Any] ?? [:]
                let cursorValue = nonEmpty(content["value"])
                let cursorType = (nonEmpty(content["cursorType"]) ?? "").lowercased()
                if let cursorValue {
                    if entryID.hasPrefix("cursor-bottom-") || cursorType == "bottom" {
                        cursor = cursorValue
                    } else if cursor == nil, entryID.hasPrefix("cursor-") || !cursorType.isEmpty {
                        cursor = cursorValue
                    }
                }

                for userResult in extractFollowUserResults(from: entry) {
                    let profile = mapUserResultToProfile(userResult)
                    let dedupeKey = nonEmpty(profile.userID)?.lowercased() ?? (nonEmpty(profile.username).map { "username:\($0.lowercased())" } ?? UUID().uuidString)
                    if seen.insert(dedupeKey).inserted {
                        users.append(profile)
                    }
                }
            }
        }

        return TimelineExtraction(items: users, cursor: cursor)
    }

    private static func extractTweetsAndCursor(fromInstructions instructions: [[String: Any]]) -> TimelineExtraction<XTweet> {
        var tweets: [XTweet] = []
        var cursor: String?

        for instruction in instructions {
            for entry in extractEntries(from: instruction) {
                let entryID = nonEmpty(entry["entryId"]) ?? ""
                let content = entry["content"] as? [String: Any] ?? [:]
                let cursorType = (nonEmpty(content["cursorType"]) ?? "").lowercased()
                if let cursorValue = nonEmpty(content["value"]),
                   entryID.contains("cursor-bottom") || entryID.hasPrefix("cursor-") || cursorType == "bottom"
                {
                    cursor = cursorValue
                }

                guard entryID.hasPrefix("tweet-") else { continue }
                guard let tweet = mapTweetEntryToRecord(entry) else { continue }
                tweets.append(tweet)
            }
        }

        return TimelineExtraction(items: tweets, cursor: cursor)
    }

    private static func mapTweetEntryToRecord(_ entry: [String: Any]) -> XTweet? {
        let content = entry["content"] as? [String: Any] ?? [:]
        let itemContent = content["itemContent"] as? [String: Any] ?? [:]
        let tweetResults = itemContent["tweet_results"] as? [String: Any] ?? [:]
        guard var tweetResultRaw = tweetResults["result"] as? [String: Any] else {
            return nil
        }
        if let tweetWrapper = tweetResultRaw["tweet"] as? [String: Any] {
            tweetResultRaw = tweetWrapper
        }

        let legacy = tweetResultRaw["legacy"] as? [String: Any] ?? [:]
        let core = tweetResultRaw["core"] as? [String: Any] ?? [:]
        let userResults = core["user_results"] as? [String: Any] ?? [:]
        let userResult = userResults["result"] as? [String: Any] ?? [:]
        let userLegacy = userResult["legacy"] as? [String: Any] ?? [:]
        let userCore = userResult["core"] as? [String: Any] ?? [:]

        let tweetID = firstNonEmptyString(legacy["id_str"], tweetResultRaw["rest_id"], entry["entryId"])?
            .replacingOccurrences(of: "tweet-", with: "") ?? ""
        guard !tweetID.isEmpty else { return nil }

        let noteTweet = (((tweetResultRaw["note_tweet"] as? [String: Any])?["note_tweet_results"] as? [String: Any])?["result"] as? [String: Any])
        let noteText = nonEmpty(noteTweet?["text"])
        let text = noteText ?? nonEmpty(legacy["full_text"]) ?? ""

        var mediaURLs: [String] = []
        if let extendedEntities = legacy["extended_entities"] as? [String: Any],
           let media = extendedEntities["media"] as? [[String: Any]]
        {
            for item in media {
                if let url = nonEmpty(item["media_url_https"]) {
                    mediaURLs.append(url)
                }
            }
        }

        var embeddedText: String?
        if let quotedStatusResult = tweetResultRaw["quoted_status_result"] as? [String: Any],
           let quotedResult = quotedStatusResult["result"] as? [String: Any],
           let quotedLegacy = quotedResult["legacy"] as? [String: Any]
        {
            embeddedText = nonEmpty(quotedLegacy["full_text"])
        }
        if embeddedText == nil,
           let retweetedStatusResult = legacy["retweeted_status_result"] as? [String: Any],
           let retweetedResult = retweetedStatusResult["result"] as? [String: Any],
           let retweetedLegacy = retweetedResult["legacy"] as? [String: Any]
        {
            embeddedText = nonEmpty(retweetedLegacy["full_text"])
        }

        let username = firstNonEmptyString(userLegacy["screen_name"], userCore["screen_name"])
        let tweetURL = username.map { "https://x.com/\($0)/status/\(tweetID)" }
        let viewsNode = tweetResultRaw["views"] as? [String: Any]

        return XTweet(
            id: tweetID,
            text: text,
            embeddedText: embeddedText,
            createdAt: nonEmpty(legacy["created_at"]),
            replyCount: intValue(legacy["reply_count"]),
            likeCount: intValue(legacy["favorite_count"]),
            retweetCount: intValue(legacy["retweet_count"]),
            quoteCount: intValue(legacy["quote_count"]),
            viewCount: nonEmpty(viewsNode?["count"]).flatMap { Int($0) },
            language: nonEmpty(legacy["lang"]),
            source: nonEmpty(legacy["source"]),
            mediaURLs: mediaURLs,
            tweetURL: tweetURL,
            author: XUserReference(
                userID: firstNonEmptyString(userResult["rest_id"], userResult["id"], userLegacy["id_str"]),
                username: username,
                name: firstNonEmptyString(userLegacy["name"], userCore["name"])
            ),
            isRetweet: legacy["retweeted_status_result"] != nil,
            isQuote: tweetResultRaw["quoted_status_result"] != nil
        )
    }

    private static func extractProfileTimelineInstructions(from payload: [String: Any]) -> [[String: Any]] {
        let dataNode = payload["data"] as? [String: Any]
        let userNode = dataNode?["user"] as? [String: Any]
        let resultNode = userNode?["result"] as? [String: Any]
        let timelineNode = resultNode?["timeline"] as? [String: Any]
        let innerTimelineNode = timelineNode?["timeline"] as? [String: Any]
        return innerTimelineNode?["instructions"] as? [[String: Any]] ?? []
    }

    private static func extractEntries(from instruction: [String: Any]) -> [[String: Any]] {
        var entries: [[String: Any]] = []
        if let list = instruction["entries"] as? [[String: Any]] {
            entries.append(contentsOf: list)
        }
        if let entry = instruction["entry"] as? [String: Any] {
            entries.append(entry)
        }
        return entries
    }

    private static func extractFollowUserResults(from entry: [String: Any]) -> [[String: Any]] {
        let content = entry["content"] as? [String: Any] ?? [:]
        var results: [[String: Any]] = []

        func appendFromItem(_ value: Any?) {
            guard let item = value as? [String: Any] else { return }
            let itemContent = item["itemContent"] as? [String: Any] ?? item
            let userResults = itemContent["user_results"] as? [String: Any] ?? [:]
            if let result = userResults["result"] as? [String: Any], !result.isEmpty {
                results.append(result)
            }
        }

        appendFromItem(content["itemContent"])
        if let item = content["item"] as? [String: Any] {
            appendFromItem(item["itemContent"])
        }
        if let items = content["items"] as? [[String: Any]] {
            for node in items {
                if let item = node["item"] as? [String: Any] {
                    appendFromItem(item["itemContent"])
                }
                appendFromItem(node["itemContent"])
            }
        }
        return results
    }

    private nonisolated static func clampCount(_ value: Int?) -> Int {
        min(max(value ?? 20, 1), 100)
    }

    private nonisolated static func normalizeDisplayType(_ value: String?) -> String {
        let normalized = nonEmpty(value)?.lowercased() ?? "latest"
        return normalized == "top" ? "top" : "latest"
    }

    private nonisolated static func normalizeBearerToken(_ value: String?) -> String? {
        guard let value = nonEmpty(value) else { return nil }
        if value.lowercased().hasPrefix("bearer ") {
            return nonEmpty(String(value.dropFirst(7)))
        }
        return value
    }

    private nonisolated static func normalizeUsername(_ value: String?) -> String? {
        guard let value = nonEmpty(value) else { return nil }
        let username = value.trimmingCharacters(in: .whitespacesAndNewlines).trimmingCharacters(in: CharacterSet(charactersIn: "@"))
        guard username.range(of: #"^[A-Za-z0-9_]{1,15}$"#, options: .regularExpression) != nil else {
            return nil
        }
        return username
    }

    private nonisolated static func normalizeUsernameList(_ values: [String]) -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        for value in values {
            guard let username = normalizeUsername(value) else { continue }
            let dedupeKey = username.lowercased()
            if seen.insert(dedupeKey).inserted {
                result.append(username)
            }
        }
        return result
    }

    private nonisolated static func normalizeStringList(_ values: [String]?) -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        for value in values ?? [] {
            guard let normalized = nonEmpty(value) else { continue }
            if seen.insert(normalized).inserted {
                result.append(normalized)
            }
        }
        return result
    }

    private nonisolated static func normalizeHashtag(_ value: String?) -> String? {
        guard let value = nonEmpty(value) else { return nil }
        if value.hasPrefix("#") || value.hasPrefix("$") {
            return value
        }
        return "#\(value)"
    }

    private nonisolated static func normalizeTweetType(_ value: String?) -> String {
        let normalized = nonEmpty(value)?.lowercased() ?? "all"
        switch normalized {
        case "originals_only", "replies_only", "retweets_only", "exclude_replies", "exclude_retweets", "all":
            return normalized
        default:
            return "all"
        }
    }

    private nonisolated static func tweetTypeFilterTokens(_ value: String) -> [String] {
        switch value {
        case "originals_only":
            return ["-filter:replies", "-filter:retweets"]
        case "replies_only":
            return ["filter:replies"]
        case "retweets_only":
            return ["filter:retweets"]
        case "exclude_replies":
            return ["-filter:replies"]
        case "exclude_retweets":
            return ["-filter:retweets"]
        default:
            return []
        }
    }

    private nonisolated static func formatQueryTerm(_ value: String?) -> String? {
        guard let value = nonEmpty(value) else { return nil }
        if value.hasPrefix("\""), value.hasSuffix("\"") {
            return value
        }
        if value.contains(where: { $0.isWhitespace }) {
            return "\"\(value)\""
        }
        return value
    }

    private nonisolated static func queryTimeToken(_ value: String) -> String {
        value.hasSuffix("_UTC") ? String(value.dropLast(4)) : value
    }

    private nonisolated static func queryHasOperator(_ searchQuery: String, name: String) -> Bool {
        searchQuery.range(of: #"(?<![A-Za-z0-9_])"# + NSRegularExpression.escapedPattern(for: name) + #":"#, options: .regularExpression) != nil
    }

    private nonisolated static func queryHasAnyMinOperator(_ searchQuery: String) -> Bool {
        searchQuery.range(of: #"(?<![A-Za-z0-9_])min_[a-z_]+:"#, options: .regularExpression) != nil
    }

    private nonisolated static func queryHasAnyFilterOperator(_ searchQuery: String) -> Bool {
        searchQuery.range(of: #"(?<![A-Za-z0-9_])-?filter:[a-z_]+\b"#, options: .regularExpression) != nil
    }

    private nonisolated static func buildOperatorGroup(name: String, values: [String]) -> String? {
        guard !values.isEmpty else { return nil }
        let items = values.map { "\(name):\($0)" }
        return items.count == 1 ? items[0] : "(\(items.joined(separator: " OR ")) )".replacingOccurrences(of: " )", with: ")")
    }

    private nonisolated static func firstNonEmptyString(_ values: Any?...) -> String? {
        for value in values {
            if let normalized = nonEmpty(value) {
                return normalized
            }
        }
        return nil
    }

    private nonisolated static func nonEmpty(_ value: Any?) -> String? {
        guard let value else { return nil }
        let text = String(describing: value).trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
    }

    private nonisolated static func boolValue(_ value: Any?) -> Bool {
        switch value {
        case let bool as Bool:
            return bool
        case let number as NSNumber:
            return number.boolValue
        case let string as String:
            return ["1", "true", "yes", "y", "on"].contains(string.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())
        default:
            return false
        }
    }

    private nonisolated static func intValue(_ value: Any?) -> Int {
        if let int = value as? Int {
            return int
        }
        if let number = value as? NSNumber {
            return number.intValue
        }
        if let string = nonEmpty(value), let int = Int(string) {
            return int
        }
        return 0
    }

    private nonisolated static func encodeJSON(_ object: Any) throws -> String {
        let data = try JSONSerialization.data(withJSONObject: object, options: [])
        guard let string = String(data: data, encoding: .utf8) else {
            throw XServiceError.invalidRequest("Failed to encode X GraphQL params as UTF-8 JSON")
        }
        return string
    }
}
