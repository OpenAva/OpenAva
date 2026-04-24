import Foundation

enum YouTubeTranscriptServiceError: Error, LocalizedError {
    case invalidInput
    case videoIDNotFound
    case watchPageUnavailable
    case captionsUnavailable
    case transcriptTrackUnavailable
    case transcriptParseFailed

    var errorDescription: String? {
        switch self {
        case .invalidInput:
            return "Invalid YouTube URL or video identifier"
        case .videoIDNotFound:
            return "Unable to extract YouTube video ID"
        case .watchPageUnavailable:
            return "Unable to fetch YouTube watch page"
        case .captionsUnavailable:
            return "No captions available for this video"
        case .transcriptTrackUnavailable:
            return "Unable to load YouTube transcript track"
        case .transcriptParseFailed:
            return "Failed to parse YouTube transcript response"
        }
    }
}

struct YouTubeTranscriptSegment: Codable {
    let startSeconds: Double
    let durationSeconds: Double
    let text: String
}

struct YouTubeTranscriptDocument: Codable {
    let videoID: String
    let input: String
    let title: String?
    let language: String
    let trackName: String
    let totalSegmentCount: Int
    let transcript: String
    let segments: [YouTubeTranscriptSegment]
    let message: String
}

actor YouTubeTranscriptService {
    private struct CaptionTrack: Decodable {
        struct CaptionName: Decodable {
            struct CaptionRun: Decodable {
                let text: String?
            }

            let simpleText: String?
            let runs: [CaptionRun]?

            var textValue: String {
                if let simpleText, !simpleText.isEmpty {
                    return simpleText
                }
                let joined = (runs ?? []).compactMap { $0.text }.joined()
                return joined.isEmpty ? "Unknown" : joined
            }
        }

        let baseUrl: String
        let name: CaptionName
        let languageCode: String
        let kind: String?
    }

    private struct TrackListRenderer: Decodable {
        let captionTracks: [CaptionTrack]?
    }

    private struct CaptionsNode: Decodable {
        let playerCaptionsTracklistRenderer: TrackListRenderer?
    }

    private struct VideoDetailsNode: Decodable {
        let videoId: String?
        let title: String?
    }

    private struct PlayerResponseNode: Decodable {
        let captions: CaptionsNode?
        let videoDetails: VideoDetailsNode?
    }

    private struct YTCfgNode: Decodable {
        let innertubeAPIKey: String?
        let visitorData: String?

        enum CodingKeys: String, CodingKey {
            case innertubeAPIKey = "INNERTUBE_API_KEY"
            case visitorData = "VISITOR_DATA"
        }
    }

    private struct FallbackPlayerClient {
        let clientName: String
        let clientVersion: String
        let clientNameHeader: Int
        let userAgent: String
        let osName: String?
        let osVersion: String?
        let deviceMake: String?
        let deviceModel: String?
        let androidSDKVersion: Int?
    }

    private static let defaultTimeoutSeconds: TimeInterval = 20
    private static let defaultUserAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 14_7_2) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/122.0.0.0 Safari/537.36"
    private static let transcriptFallbackClients: [FallbackPlayerClient] = [
        FallbackPlayerClient(
            clientName: "ANDROID",
            clientVersion: "21.02.35",
            clientNameHeader: 3,
            userAgent: "com.google.android.youtube/21.02.35 (Linux; U; Android 11) gzip",
            osName: "Android",
            osVersion: "11",
            deviceMake: nil,
            deviceModel: nil,
            androidSDKVersion: 30
        ),
        FallbackPlayerClient(
            clientName: "IOS",
            clientVersion: "21.02.3",
            clientNameHeader: 5,
            userAgent: "com.google.ios.youtube/21.02.3 (iPhone16,2; U; CPU iOS 18_3_2 like Mac OS X;)",
            osName: "iPhone",
            osVersion: "18.3.2.22D82",
            deviceMake: "Apple",
            deviceModel: "iPhone16,2",
            androidSDKVersion: nil
        ),
    ]

    private let session: URLSession

    init(timeoutSeconds: TimeInterval = defaultTimeoutSeconds) {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = timeoutSeconds
        config.timeoutIntervalForResource = timeoutSeconds
        session = URLSession(configuration: config)
    }

    func fetchTranscriptDocument(
        input: String,
        preferredLanguage: String?
    ) async throws -> YouTubeTranscriptDocument {
        let normalizedInput = Self.normalizeWhitespace(input)
        guard !normalizedInput.isEmpty else {
            throw YouTubeTranscriptServiceError.invalidInput
        }

        let videoID = try Self.extractVideoID(from: normalizedInput)
        let watchPage = try await fetchWatchPage(videoID: videoID)
        let playerResponse = try Self.extractPlayerResponse(from: watchPage)

        // Primary source: caption tracks embedded in ytInitialPlayerResponse.
        var tracks = playerResponse.captions?.playerCaptionsTracklistRenderer?.captionTracks ?? []
        if tracks.isEmpty {
            // Fallback for pages where captions are omitted from initial player response.
            tracks = try await fetchTimedtextTrackList(videoID: videoID)
        }

        var fallbackPlayerTracksCache: [CaptionTrack]?
        func loadFallbackPlayerTracks() async -> [CaptionTrack] {
            if let fallbackPlayerTracksCache {
                return fallbackPlayerTracksCache
            }
            let fetched = await fetchFallbackPlayerTracks(videoID: videoID, watchPage: watchPage)
            fallbackPlayerTracksCache = fetched
            return fetched
        }

        if tracks.isEmpty {
            let fallbackTracks = await loadFallbackPlayerTracks()
            guard !fallbackTracks.isEmpty else {
                throw YouTubeTranscriptServiceError.captionsUnavailable
            }
            tracks = fallbackTracks
        }

        let preferredLanguageCode = Self.normalizeLanguage(preferredLanguage)
        var selectedTrack = Self.selectTrack(from: tracks, preferredLanguage: preferredLanguageCode)
        if selectedTrack == nil {
            selectedTrack = Self.selectTrack(from: await loadFallbackPlayerTracks(), preferredLanguage: preferredLanguageCode)
        }

        guard var selectedTrack else {
            throw YouTubeTranscriptServiceError.transcriptTrackUnavailable
        }

        // Some WEB subtitle URLs now return empty payloads (PO-token gated).
        var parsedSegments = (try? await fetchTranscriptSegments(baseURLString: selectedTrack.baseUrl)) ?? []
        if parsedSegments.isEmpty {
            if let fallbackTrack = Self.selectTrack(from: await loadFallbackPlayerTracks(), preferredLanguage: preferredLanguageCode) {
                let fallbackSegments = (try? await fetchTranscriptSegments(baseURLString: fallbackTrack.baseUrl)) ?? []
                if !fallbackSegments.isEmpty {
                    selectedTrack = fallbackTrack
                    parsedSegments = fallbackSegments
                }
            }
        }

        guard !parsedSegments.isEmpty else {
            throw YouTubeTranscriptServiceError.transcriptParseFailed
        }

        let transcript = parsedSegments.map(\.text).joined(separator: "\n")
        let title = playerResponse.videoDetails?.title
        let message = "Loaded \(parsedSegments.count) transcript segments for video \(videoID)."

        return YouTubeTranscriptDocument(
            videoID: playerResponse.videoDetails?.videoId ?? videoID,
            input: normalizedInput,
            title: title,
            language: selectedTrack.languageCode,
            trackName: selectedTrack.name.textValue,
            totalSegmentCount: parsedSegments.count,
            transcript: transcript,
            segments: parsedSegments,
            message: message
        )
    }

    private func fetchWatchPage(videoID: String) async throws -> String {
        var components = URLComponents(string: "https://www.youtube.com/watch")
        // Align with yt-dlp defaults to bypass some verification gates.
        components?.queryItems = [
            URLQueryItem(name: "v", value: videoID),
            URLQueryItem(name: "bpctr", value: "9999999999"),
            URLQueryItem(name: "has_verified", value: "1"),
        ]
        guard let url = components?.url else {
            throw YouTubeTranscriptServiceError.watchPageUnavailable
        }

        var request = URLRequest(url: url)
        request.setValue(Self.defaultUserAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("en-US,en;q=0.9", forHTTPHeaderField: "Accept-Language")

        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse,
              (200 ... 299).contains(httpResponse.statusCode)
        else {
            throw YouTubeTranscriptServiceError.watchPageUnavailable
        }

        return String(decoding: data, as: UTF8.self)
    }

    private func fetchTimedtextTrackList(videoID: String) async throws -> [CaptionTrack] {
        // Legacy timedtext endpoint still exposes available transcript tracks.
        var components = URLComponents(string: "https://www.youtube.com/api/timedtext")
        components?.queryItems = [
            URLQueryItem(name: "type", value: "list"),
            URLQueryItem(name: "v", value: videoID),
        ]
        guard let url = components?.url else {
            return []
        }

        var request = URLRequest(url: url)
        request.setValue(Self.defaultUserAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("en-US,en;q=0.9", forHTTPHeaderField: "Accept-Language")

        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse,
              (200 ... 299).contains(httpResponse.statusCode)
        else {
            return []
        }

        let xml = String(decoding: data, as: UTF8.self)
        return Self.parseTimedtextTrackListXML(xml, videoID: videoID)
    }

    private func fetchFallbackPlayerTracks(videoID: String, watchPage: String) async -> [CaptionTrack] {
        guard let ytcfg = Self.extractYTCfg(from: watchPage),
              let apiKey = ytcfg.innertubeAPIKey,
              !apiKey.isEmpty
        else {
            return []
        }

        for client in Self.transcriptFallbackClients {
            guard let response = await fetchFallbackPlayerResponse(
                videoID: videoID,
                apiKey: apiKey,
                visitorData: ytcfg.visitorData,
                client: client
            ) else {
                continue
            }

            let tracks = response.captions?.playerCaptionsTracklistRenderer?.captionTracks ?? []
            if !tracks.isEmpty {
                return tracks
            }
        }

        return []
    }

    private func fetchFallbackPlayerResponse(
        videoID: String,
        apiKey: String,
        visitorData: String?,
        client: FallbackPlayerClient
    ) async -> PlayerResponseNode? {
        var components = URLComponents(string: "https://www.youtube.com/youtubei/v1/player")
        components?.queryItems = [
            URLQueryItem(name: "key", value: apiKey),
            URLQueryItem(name: "prettyPrint", value: "false"),
        ]
        guard let url = components?.url else {
            return nil
        }

        var clientPayload: [String: Any] = [
            "clientName": client.clientName,
            "clientVersion": client.clientVersion,
            "userAgent": client.userAgent,
        ]
        if let osName = client.osName {
            clientPayload["osName"] = osName
        }
        if let osVersion = client.osVersion {
            clientPayload["osVersion"] = osVersion
        }
        if let deviceMake = client.deviceMake {
            clientPayload["deviceMake"] = deviceMake
        }
        if let deviceModel = client.deviceModel {
            clientPayload["deviceModel"] = deviceModel
        }
        if let androidSDKVersion = client.androidSDKVersion {
            clientPayload["androidSdkVersion"] = androidSDKVersion
        }

        let payload: [String: Any] = [
            "videoId": videoID,
            "context": [
                "client": clientPayload,
                "user": ["lockedSafetyMode": false],
                "request": ["useSsl": true],
            ],
            "contentCheckOk": true,
            "racyCheckOk": true,
        ]

        guard let requestBody = try? JSONSerialization.data(withJSONObject: payload) else {
            return nil
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpBody = requestBody
        request.setValue(client.userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("https://www.youtube.com", forHTTPHeaderField: "Origin")
        request.setValue("https://www.youtube.com/watch?v=\(videoID)", forHTTPHeaderField: "Referer")
        request.setValue("\(client.clientNameHeader)", forHTTPHeaderField: "X-YouTube-Client-Name")
        request.setValue(client.clientVersion, forHTTPHeaderField: "X-YouTube-Client-Version")
        if let visitorData, !visitorData.isEmpty {
            request.setValue(visitorData, forHTTPHeaderField: "X-Goog-Visitor-Id")
        }

        guard let (data, response) = try? await session.data(for: request),
              let httpResponse = response as? HTTPURLResponse,
              (200 ... 299).contains(httpResponse.statusCode)
        else {
            return nil
        }

        return try? JSONDecoder().decode(PlayerResponseNode.self, from: data)
    }

    private func fetchTranscriptSegments(baseURLString: String) async throws -> [YouTubeTranscriptSegment] {
        // Keep source format first, then force srv3 as compatibility retry.
        let defaultXML = try await fetchTranscriptXML(baseURLString: baseURLString, forcedFormat: nil)
        let defaultSegments = Self.parseTranscriptXML(defaultXML)
        if !defaultSegments.isEmpty {
            return defaultSegments
        }

        let srv3XML = try await fetchTranscriptXML(baseURLString: baseURLString, forcedFormat: "srv3")
        return Self.parseTranscriptXML(srv3XML)
    }

    private func fetchTranscriptXML(baseURLString: String, forcedFormat: String?) async throws -> String {
        guard var components = URLComponents(string: baseURLString) else {
            throw YouTubeTranscriptServiceError.transcriptTrackUnavailable
        }

        if let forcedFormat {
            var items = (components.queryItems ?? []).filter { $0.name.caseInsensitiveCompare("fmt") != .orderedSame }
            items.append(URLQueryItem(name: "fmt", value: forcedFormat))
            components.queryItems = items
        }

        guard let url = components.url else {
            throw YouTubeTranscriptServiceError.transcriptTrackUnavailable
        }

        var request = URLRequest(url: url)
        request.setValue(Self.defaultUserAgent, forHTTPHeaderField: "User-Agent")

        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse,
              (200 ... 299).contains(httpResponse.statusCode)
        else {
            throw YouTubeTranscriptServiceError.transcriptTrackUnavailable
        }
        return String(decoding: data, as: UTF8.self)
    }

    private static func extractPlayerResponse(from html: String) throws -> PlayerResponseNode {
        // Similar to yt-dlp: support both direct assignment and window["ytInitialPlayerResponse"] forms.
        let pattern = #"(?:window\s*\[\s*["']ytInitialPlayerResponse["']\s*\]|ytInitialPlayerResponse)\s*="#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
            throw YouTubeTranscriptServiceError.captionsUnavailable
        }

        let matches = regex.matches(in: html, range: NSRange(html.startIndex..., in: html))
        for match in matches {
            guard let assignRange = Range(match.range(at: 0), in: html) else {
                continue
            }
            let remainder = html[assignRange.upperBound...]
            let remainderText = String(remainder)
            let trimmed = remainderText.trimmingCharacters(in: .whitespacesAndNewlines)

            if trimmed.hasPrefix("JSON.parse(") {
                if let parsed = decodeJSONParseAssignment(from: remainderText) {
                    return parsed
                }
                continue
            }

            guard let jsonRange = balancedJSONObjectRange(in: html, startSearchFrom: assignRange.upperBound) else {
                continue
            }
            let jsonString = String(html[jsonRange])
            guard let data = jsonString.data(using: .utf8) else {
                continue
            }
            if let decoded = try? JSONDecoder().decode(PlayerResponseNode.self, from: data) {
                return decoded
            }
        }

        throw YouTubeTranscriptServiceError.captionsUnavailable
    }

    private static func decodeJSONParseAssignment(from source: String) -> PlayerResponseNode? {
        guard let parseRange = source.range(of: "JSON.parse(") else {
            return nil
        }

        var index = parseRange.upperBound
        while index < source.endIndex, source[index].isWhitespace {
            index = source.index(after: index)
        }
        guard index < source.endIndex else {
            return nil
        }

        let quote = source[index]
        guard quote == "\"" || quote == "'" else {
            return nil
        }
        index = source.index(after: index)

        var escaped = false
        var payload = ""
        while index < source.endIndex {
            let char = source[index]
            if escaped {
                payload.append("\\")
                payload.append(char)
                escaped = false
                index = source.index(after: index)
                continue
            }

            if char == "\\" {
                escaped = true
                index = source.index(after: index)
                continue
            }

            if char == quote {
                break
            }

            payload.append(char)
            index = source.index(after: index)
        }

        // Decode the JS string literal into raw JSON before model decoding.
        guard let wrappedData = ("\"" + payload + "\"").data(using: .utf8),
              let jsonString = try? JSONDecoder().decode(String.self, from: wrappedData),
              let data = jsonString.data(using: .utf8)
        else {
            return nil
        }

        return try? JSONDecoder().decode(PlayerResponseNode.self, from: data)
    }

    private static func selectTrack(from tracks: [CaptionTrack], preferredLanguage: String?) -> CaptionTrack? {
        guard !tracks.isEmpty else {
            return nil
        }

        let manualTracks = tracks.filter { $0.kind?.lowercased() != "asr" }
        let preferredPool = manualTracks.isEmpty ? tracks : manualTracks

        guard let preferredLanguage, !preferredLanguage.isEmpty else {
            return preferredPool.first ?? tracks.first
        }

        if let exact = preferredPool.first(where: { $0.languageCode.compare(preferredLanguage, options: [.caseInsensitive]) == .orderedSame }) {
            return exact
        }

        if let prefix = preferredPool.first(where: {
            let normalized = $0.languageCode.lowercased()
            return normalized.hasPrefix(preferredLanguage.lowercased()) || preferredLanguage.lowercased().hasPrefix(normalized)
        }) {
            return prefix
        }

        // Last attempt: fallback to the base language (e.g. zh-Hans -> zh-*).
        let preferredBase = preferredLanguage.split(separator: "-").first.map(String.init)?.lowercased()
        if let preferredBase, !preferredBase.isEmpty {
            if let baseMatch = preferredPool.first(where: {
                let normalized = $0.languageCode.lowercased()
                return normalized == preferredBase || normalized.hasPrefix(preferredBase + "-")
            }) {
                return baseMatch
            }
        }

        // Preferred language is only a hint; if not found, return default track.
        return preferredPool.first ?? tracks.first
    }

    private static func parseTimedtextTrackListXML(_ xml: String, videoID: String) -> [CaptionTrack] {
        // Build a transcript request URL for each advertised track.
        guard let regex = try? NSRegularExpression(
            pattern: #"<track\b([^>]*)/?>"#,
            options: [.caseInsensitive]
        ) else {
            return []
        }

        let matches = regex.matches(in: xml, range: NSRange(xml.startIndex..., in: xml))
        guard !matches.isEmpty else {
            return []
        }

        var tracks: [CaptionTrack] = []
        for match in matches {
            guard let attributesRange = Range(match.range(at: 1), in: xml) else {
                continue
            }
            let attributes = String(xml[attributesRange])

            guard let languageCode = attributeValue(name: "lang_code", in: attributes),
                  !languageCode.isEmpty
            else {
                continue
            }

            var components = URLComponents(string: "https://www.youtube.com/api/timedtext")
            var items: [URLQueryItem] = [
                URLQueryItem(name: "v", value: videoID),
                URLQueryItem(name: "lang", value: languageCode),
            ]

            if let name = attributeValue(name: "name", in: attributes), !name.isEmpty {
                items.append(URLQueryItem(name: "name", value: name))
            }
            if let kind = attributeValue(name: "kind", in: attributes), !kind.isEmpty {
                items.append(URLQueryItem(name: "kind", value: kind))
            }
            components?.queryItems = items

            guard let baseURL = components?.url?.absoluteString else {
                continue
            }

            let rawName = attributeValue(name: "name", in: attributes) ?? ""
            let decodedName = normalizeWhitespace(decodeHTMLEntities(rawName))
            let displayName = decodedName.isEmpty ? languageCode : decodedName

            tracks.append(
                CaptionTrack(
                    baseUrl: baseURL,
                    name: CaptionTrack.CaptionName(simpleText: displayName, runs: nil),
                    languageCode: languageCode,
                    kind: attributeValue(name: "kind", in: attributes)
                )
            )
        }

        return tracks
    }

    private static func parseTranscriptXML(_ xml: String) -> [YouTubeTranscriptSegment] {
        // Prefer classic <text> payloads; fall back to srv3 <p>/<s> payloads.
        let legacySegments = parseTextNodeTranscriptXML(xml)
        if !legacySegments.isEmpty {
            return legacySegments
        }

        return parseSrv3TranscriptXML(xml)
    }

    private static func parseTextNodeTranscriptXML(_ xml: String) -> [YouTubeTranscriptSegment] {
        guard let regex = try? NSRegularExpression(
            pattern: #"<text\b([^>]*)>([\s\S]*?)</text>"#,
            options: [.caseInsensitive]
        ) else {
            return []
        }

        let matches = regex.matches(in: xml, range: NSRange(xml.startIndex..., in: xml))
        guard !matches.isEmpty else {
            return []
        }

        var segments: [YouTubeTranscriptSegment] = []
        for match in matches {
            guard let attributesRange = Range(match.range(at: 1), in: xml),
                  let textRange = Range(match.range(at: 2), in: xml)
            else {
                continue
            }

            let attributes = String(xml[attributesRange])
            let rawText = String(xml[textRange])
            let content = normalizeTranscriptText(rawText)
            guard !content.isEmpty else {
                continue
            }

            let start = attributeValue(name: "start", in: attributes).flatMap(Double.init) ?? 0
            let duration = attributeValue(name: "dur", in: attributes).flatMap(Double.init) ?? 0
            segments.append(YouTubeTranscriptSegment(startSeconds: start, durationSeconds: duration, text: content))
        }

        return segments
    }

    private static func parseSrv3TranscriptXML(_ xml: String) -> [YouTubeTranscriptSegment] {
        guard let regex = try? NSRegularExpression(
            pattern: #"<p\b([^>]*)>([\s\S]*?)</p>"#,
            options: [.caseInsensitive]
        ) else {
            return []
        }

        let matches = regex.matches(in: xml, range: NSRange(xml.startIndex..., in: xml))
        guard !matches.isEmpty else {
            return []
        }

        var segments: [YouTubeTranscriptSegment] = []
        for match in matches {
            guard let attributesRange = Range(match.range(at: 1), in: xml),
                  let textRange = Range(match.range(at: 2), in: xml)
            else {
                continue
            }

            let attributes = String(xml[attributesRange])
            let rawText = String(xml[textRange])
            let content = normalizeTranscriptText(rawText)
            guard !content.isEmpty else {
                continue
            }

            let startMilliseconds = attributeValue(name: "t", in: attributes).flatMap(Double.init) ?? 0
            let durationMilliseconds = attributeValue(name: "d", in: attributes).flatMap(Double.init) ?? 0
            segments.append(
                YouTubeTranscriptSegment(
                    startSeconds: startMilliseconds / 1000,
                    durationSeconds: durationMilliseconds / 1000,
                    text: content
                )
            )
        }

        return segments
    }

    private static func normalizeTranscriptText(_ rawText: String) -> String {
        // srv3 transcript may split words across adjacent <s> nodes.
        let mergedWordNodes = rawText.replacingOccurrences(
            of: #"</s>\s*<s\b[^>]*>"#,
            with: " ",
            options: .regularExpression
        )
        return normalizeWhitespace(stripTags(decodeHTMLEntities(mergedWordNodes)))
    }

    private static func attributeValue(name: String, in attributes: String) -> String? {
        let pattern = "\\b\(NSRegularExpression.escapedPattern(for: name))=\"([^\"]+)\""
        guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else {
            return nil
        }
        let range = NSRange(attributes.startIndex..., in: attributes)
        guard let match = regex.firstMatch(in: attributes, range: range),
              let valueRange = Range(match.range(at: 1), in: attributes)
        else {
            return nil
        }
        return String(attributes[valueRange])
    }

    private static func decodeHTMLEntities(_ value: String) -> String {
        var text = value
        let entities: [(String, String)] = [
            ("&amp;", "&"),
            ("&lt;", "<"),
            ("&gt;", ">"),
            ("&quot;", "\""),
            ("&#39;", "'"),
            ("&#39;", "'"),
            ("&#x27;", "'"),
            ("&nbsp;", " "),
        ]

        for (entity, replacement) in entities {
            text = text.replacingOccurrences(of: entity, with: replacement)
        }

        // Decode numeric entities like &#123; and &#x1F600;.
        text = decodeNumericEntities(in: text)
        return text
    }

    private static func decodeNumericEntities(in value: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: "&#(x?[0-9A-Fa-f]+);", options: []) else {
            return value
        }

        var output = value
        let matches = regex.matches(in: output, range: NSRange(output.startIndex..., in: output))
        guard !matches.isEmpty else {
            return output
        }

        for match in matches.reversed() {
            guard let fullRange = Range(match.range(at: 0), in: output),
                  let codeRange = Range(match.range(at: 1), in: output)
            else {
                continue
            }

            let codeText = String(output[codeRange])
            let value: UInt32?
            if codeText.lowercased().hasPrefix("x") {
                value = UInt32(codeText.dropFirst(), radix: 16)
            } else {
                value = UInt32(codeText, radix: 10)
            }

            if let scalarValue = value,
               let scalar = UnicodeScalar(scalarValue)
            {
                output.replaceSubrange(fullRange, with: String(Character(scalar)))
            }
        }

        return output
    }

    private static func stripTags(_ value: String) -> String {
        value.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
    }

    private static func normalizeWhitespace(_ value: String) -> String {
        let collapsed = value.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
        return collapsed.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func normalizeLanguage(_ value: String?) -> String? {
        guard let value else {
            return nil
        }
        let normalized = normalizeWhitespace(value).lowercased()
        return normalized.isEmpty ? nil : normalized
    }

    private static func extractVideoID(from input: String) throws -> String {
        let trimmed = normalizeWhitespace(input)
        if isLikelyVideoID(trimmed) {
            return trimmed
        }

        guard let url = URL(string: trimmed) else {
            throw YouTubeTranscriptServiceError.videoIDNotFound
        }

        let host = (url.host ?? "").lowercased()
        if host == "youtu.be" || host.hasSuffix(".youtu.be") {
            let candidate = url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            if isLikelyVideoID(candidate) {
                return candidate
            }
        }

        if host.contains("youtube.com") {
            if let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
               let v = components.queryItems?.first(where: { $0.name == "v" })?.value,
               isLikelyVideoID(v)
            {
                return v
            }

            let pathParts = url.path.split(separator: "/").map(String.init)
            if let last = pathParts.last, ["embed", "shorts", "live"].contains(pathParts.first ?? ""), isLikelyVideoID(last) {
                return last
            }
        }

        throw YouTubeTranscriptServiceError.videoIDNotFound
    }

    private static func extractYTCfg(from html: String) -> YTCfgNode? {
        guard let regex = try? NSRegularExpression(pattern: #"ytcfg\.set\("#, options: []) else {
            return nil
        }

        let matches = regex.matches(in: html, range: NSRange(html.startIndex..., in: html))
        for match in matches {
            guard let markerRange = Range(match.range(at: 0), in: html),
                  let jsonRange = balancedJSONObjectRange(in: html, startSearchFrom: markerRange.upperBound),
                  let data = String(html[jsonRange]).data(using: .utf8),
                  let decoded = try? JSONDecoder().decode(YTCfgNode.self, from: data)
            else {
                continue
            }

            if let apiKey = decoded.innertubeAPIKey, !apiKey.isEmpty {
                return decoded
            }
        }

        return nil
    }

    private static func isLikelyVideoID(_ value: String) -> Bool {
        guard value.count == 11 else {
            return false
        }
        guard let regex = try? NSRegularExpression(pattern: "^[A-Za-z0-9_-]{11}$") else {
            return false
        }
        let range = NSRange(value.startIndex..., in: value)
        return regex.firstMatch(in: value, range: range) != nil
    }

    private static func balancedJSONObjectRange(in source: String, startSearchFrom: String.Index) -> Range<String.Index>? {
        guard let start = source[startSearchFrom...].firstIndex(of: "{") else {
            return nil
        }

        var depth = 0
        var index = start
        var inString = false
        var isEscaped = false

        while index < source.endIndex {
            let char = source[index]

            if inString {
                if isEscaped {
                    isEscaped = false
                } else if char == "\\" {
                    isEscaped = true
                } else if char == "\"" {
                    inString = false
                }
            } else {
                if char == "\"" {
                    inString = true
                } else if char == "{" {
                    depth += 1
                } else if char == "}" {
                    depth -= 1
                    if depth == 0 {
                        return start ..< source.index(after: index)
                    }
                }
            }

            index = source.index(after: index)
        }

        return nil
    }

    /// Exposed for unit tests.
    static func extractVideoIDForTesting(_ input: String) throws -> String {
        try extractVideoID(from: input)
    }

    /// Exposed for unit tests.
    static func parseTranscriptXMLForTesting(_ xml: String) -> [YouTubeTranscriptSegment] {
        parseTranscriptXML(xml)
    }

    /// Exposed for unit tests.
    static func parseTimedtextTrackListXMLForTesting(_ xml: String, videoID: String) -> [String] {
        parseTimedtextTrackListXML(xml, videoID: videoID).map(\.languageCode)
    }

    /// Exposed for unit tests.
    static func selectTrackLanguageCodeForTesting(_ xml: String, videoID: String, preferredLanguage: String?) -> String? {
        let tracks = parseTimedtextTrackListXML(xml, videoID: videoID)
        let normalizedPreferred = normalizeLanguage(preferredLanguage)
        return selectTrack(from: tracks, preferredLanguage: normalizedPreferred)?.languageCode
    }

    /// Exposed for unit tests.
    static func hasCaptionTracksInWatchHTMLForTesting(_ html: String) -> Bool {
        guard let response = try? extractPlayerResponse(from: html) else {
            return false
        }
        let tracks = response.captions?.playerCaptionsTracklistRenderer?.captionTracks
        return !(tracks?.isEmpty ?? true)
    }
}
