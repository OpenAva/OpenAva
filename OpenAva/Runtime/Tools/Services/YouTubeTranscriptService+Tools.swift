import Foundation
import OpenClawKit
import OpenClawProtocol

struct YouTubeTranscriptRenderedPage {
    let startSegmentIndex: Int
    let returnedSegmentCount: Int
    let body: String
}

// MARK: - Tools

extension YouTubeTranscriptService: ToolDefinitionProvider {
    private static let maxToolPayloadChars = 32 * 1024
    private static let preferredTranscriptBodyChars = 24 * 1024
    private static let preferredSegmentsBodyChars = 24 * 1024
    private static let headerReserveChars = 1024

    nonisolated func toolDefinitions() -> [ToolDefinition] {
        [
            ToolDefinition(
                functionName: "youtube_transcript",
                command: "youtube.transcript",
                description: "Fetch and read transcript pages from a YouTube video URL or video ID. For long videos, request a page number and continue with the returned next_page instead of managing page size.",
                parametersSchema: AnyCodable([
                    "type": "object",
                    "properties": [
                        "input": [
                            "type": "string",
                            "description": "YouTube video URL or 11-character video ID.",
                        ],
                        "preferredLanguage": [
                            "type": "string",
                            "description": "Preferred transcript language code (hint), such as en, en-US, zh-Hans. If unavailable, falls back to default track.",
                        ],
                        "page": [
                            "type": "integer",
                            "minimum": 1,
                            "description": "One-based page number to return. Omit for the first page, then continue with the returned next_page.",
                        ],
                        "format": [
                            "type": "string",
                            "enum": ["transcript", "segments"],
                            "description": "Output format. 'transcript' (default): plain transcript text for the current page. 'segments': paginated numbered lines with timestamps for each segment. The tool controls page boundaries automatically to avoid truncation.",
                        ],
                    ],
                    "required": ["input"],
                    "additionalProperties": false,
                ] as [String: Any]),
                isReadOnly: true,
                isConcurrencySafe: true,
                maxResultSizeChars: Self.maxToolPayloadChars
            ),
        ]
    }

    func registerHandlers(into handlers: inout [String: ToolHandler]) {
        handlers["youtube.transcript"] = { [weak self] request in
            guard let self else { throw ToolHandlerError.handlerUnavailable }
            return try await self.handleYouTubeTranscriptInvoke(request)
        }
    }

    private func handleYouTubeTranscriptInvoke(_ request: BridgeInvokeRequest) async throws -> BridgeInvokeResponse {
        struct Params: Codable {
            let input: String
            let preferredLanguage: String?
            let page: Int?
            let format: String?
        }

        let params = try ToolInvocationHelpers.decodeParams(Params.self, from: request.paramsJSON)
        let normalizedInput = params.input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedInput.isEmpty else {
            return ToolInvocationHelpers.invalidRequest(id: request.id, "input is required")
        }

        let document = try await fetchTranscriptDocument(
            input: normalizedInput,
            preferredLanguage: params.preferredLanguage
        )

        let requestedPage = max(1, params.page ?? 1)
        let text: String
        switch params.format ?? "transcript" {
        case "segments":
            let pages = Self.makeVisibleSegmentsPages(from: document)
            let page = Self.resolvePage(pages, requestedPage: requestedPage)
            let header = Self.makeHeader(
                document: document,
                requestedPage: requestedPage,
                resolvedPage: page.pageNumber,
                totalPages: page.totalPages,
                returnedSegmentCount: page.renderedPage.returnedSegmentCount,
                nextPage: page.nextPage,
                hasMore: page.hasMore,
                summary: Self.makeSummary(
                    requestedPage: requestedPage,
                    resolvedPage: page.pageNumber,
                    totalPages: page.totalPages,
                    returnedSegmentCount: page.renderedPage.returnedSegmentCount,
                    totalSegmentCount: document.totalSegmentCount,
                    nextPage: page.nextPage,
                    outOfRange: page.outOfRange
                )
            )
            let body = page.renderedPage.body.isEmpty ? "- (empty)" : page.renderedPage.body
            text = "\(header)\n\n\(body)"
        default: // "transcript"
            let pages = Self.makeVisibleTranscriptPages(from: document)
            let page = Self.resolvePage(pages, requestedPage: requestedPage)
            let header = Self.makeHeader(
                document: document,
                requestedPage: requestedPage,
                resolvedPage: page.pageNumber,
                totalPages: page.totalPages,
                returnedSegmentCount: page.renderedPage.returnedSegmentCount,
                nextPage: page.nextPage,
                hasMore: page.hasMore,
                summary: Self.makeSummary(
                    requestedPage: requestedPage,
                    resolvedPage: page.pageNumber,
                    totalPages: page.totalPages,
                    returnedSegmentCount: page.renderedPage.returnedSegmentCount,
                    totalSegmentCount: document.totalSegmentCount,
                    nextPage: page.nextPage,
                    outOfRange: page.outOfRange
                )
            )
            let transcriptBody = page.renderedPage.body.isEmpty ? "- (empty)" : page.renderedPage.body
            text = "\(header)\n\n### Transcript\n\(transcriptBody)"
        }
        return ToolInvocationHelpers.successResponse(id: request.id, payload: text)
    }

    static func makeVisibleTranscriptPages(
        from document: YouTubeTranscriptDocument,
        maxPayloadChars: Int = maxToolPayloadChars,
        preferredBodyChars: Int = preferredTranscriptBodyChars,
        reservedHeaderChars: Int = headerReserveChars
    ) -> [YouTubeTranscriptRenderedPage] {
        makeVisiblePages(
            from: document,
            maxPayloadChars: maxPayloadChars,
            preferredBodyChars: preferredBodyChars,
            reservedHeaderChars: reservedHeaderChars
        ) { _, segment in
            segment.text
        }
    }

    static func makeVisibleSegmentsPages(
        from document: YouTubeTranscriptDocument,
        maxPayloadChars: Int = maxToolPayloadChars,
        preferredBodyChars: Int = preferredSegmentsBodyChars,
        reservedHeaderChars: Int = headerReserveChars
    ) -> [YouTubeTranscriptRenderedPage] {
        makeVisiblePages(
            from: document,
            maxPayloadChars: maxPayloadChars,
            preferredBodyChars: preferredBodyChars,
            reservedHeaderChars: reservedHeaderChars
        ) { index, segment in
            let lineNumber = index + 1
            return "\(lineNumber). [\(String(format: "%.2f", segment.startSeconds))s +\(String(format: "%.2f", segment.durationSeconds))s] \(segment.text)"
        }
    }

    private static func makeVisiblePages(
        from document: YouTubeTranscriptDocument,
        maxPayloadChars: Int,
        preferredBodyChars: Int,
        reservedHeaderChars: Int,
        renderItem: (Int, YouTubeTranscriptSegment) -> String
    ) -> [YouTubeTranscriptRenderedPage] {
        let bodyBudget = max(1, min(preferredBodyChars, maxPayloadChars - reservedHeaderChars))
        guard !document.segments.isEmpty else {
            return [YouTubeTranscriptRenderedPage(startSegmentIndex: 0, returnedSegmentCount: 0, body: "")]
        }

        var pages: [YouTubeTranscriptRenderedPage] = []
        var body = ""
        var returnedSegmentCount = 0
        var startSegmentIndex = 0
        var index = 0

        while index < document.segments.count {
            let item = renderItem(index, document.segments[index])
            let separator = body.isEmpty ? "" : "\n"
            let remainingChars = bodyBudget - body.count - separator.count

            if remainingChars > 0, item.count <= remainingChars {
                if returnedSegmentCount == 0 {
                    startSegmentIndex = index
                }
                body += separator + item
                returnedSegmentCount += 1
                index += 1
                continue
            }

            if returnedSegmentCount > 0 {
                pages.append(
                    YouTubeTranscriptRenderedPage(
                        startSegmentIndex: startSegmentIndex,
                        returnedSegmentCount: returnedSegmentCount,
                        body: body
                    )
                )
                body = ""
                returnedSegmentCount = 0
                continue
            }

            pages.append(
                YouTubeTranscriptRenderedPage(
                    startSegmentIndex: index,
                    returnedSegmentCount: 1,
                    body: truncateInline(item, limit: bodyBudget)
                )
            )
            index += 1
        }

        if returnedSegmentCount > 0 {
            pages.append(
                YouTubeTranscriptRenderedPage(
                    startSegmentIndex: startSegmentIndex,
                    returnedSegmentCount: returnedSegmentCount,
                    body: body
                )
            )
        }

        return pages.isEmpty ? [YouTubeTranscriptRenderedPage(startSegmentIndex: 0, returnedSegmentCount: 0, body: "")] : pages
    }

    private static func resolvePage(
        _ pages: [YouTubeTranscriptRenderedPage],
        requestedPage: Int
    ) -> (renderedPage: YouTubeTranscriptRenderedPage, pageNumber: Int, totalPages: Int, nextPage: Int?, hasMore: Bool, outOfRange: Bool) {
        let totalPages = max(1, pages.count)
        guard !pages.isEmpty else {
            return (
                renderedPage: YouTubeTranscriptRenderedPage(startSegmentIndex: 0, returnedSegmentCount: 0, body: ""),
                pageNumber: 1,
                totalPages: 1,
                nextPage: nil,
                hasMore: false,
                outOfRange: requestedPage > 1
            )
        }

        let outOfRange = requestedPage > totalPages
        let pageNumber = outOfRange ? totalPages : requestedPage
        let renderedPage = pages[pageNumber - 1]
        let nextPage = pageNumber < totalPages ? pageNumber + 1 : nil
        return (
            renderedPage: renderedPage,
            pageNumber: pageNumber,
            totalPages: totalPages,
            nextPage: nextPage,
            hasMore: nextPage != nil,
            outOfRange: outOfRange
        )
    }

    private static func makeHeader(
        document: YouTubeTranscriptDocument,
        requestedPage: Int,
        resolvedPage: Int,
        totalPages: Int,
        returnedSegmentCount: Int,
        nextPage: Int?,
        hasMore: Bool,
        summary: String
    ) -> String {
        "## YouTube Transcript\n- video_id: \(document.videoID)\n- title: \(document.title ?? "")\n- language: \(document.language)\n- track: \(document.trackName)\n- requested_page: \(requestedPage)\n- page: \(resolvedPage)\n- total_pages: \(totalPages)\n- returned_segments: \(returnedSegmentCount)\n- total_segments: \(document.totalSegmentCount)\n- next_page: \(nextPage.map(String.init) ?? "none")\n- has_more: \(hasMore)\n- summary: \(summary)"
    }

    private static func makeSummary(
        requestedPage: Int,
        resolvedPage: Int,
        totalPages: Int,
        returnedSegmentCount: Int,
        totalSegmentCount: Int,
        nextPage: Int?,
        outOfRange: Bool
    ) -> String {
        if outOfRange {
            return "Requested page \(requestedPage) exceeds total pages \(totalPages). Returned page \(resolvedPage) instead."
        }

        guard returnedSegmentCount > 0 else {
            return "Page \(resolvedPage) of \(totalPages) is empty. Total available segments: \(totalSegmentCount)."
        }

        if let nextPage {
            return "Returned page \(resolvedPage) of \(totalPages) with \(returnedSegmentCount) segments out of \(totalSegmentCount). Continue with page=\(nextPage)."
        }
        return "Returned final page \(resolvedPage) of \(totalPages) with \(returnedSegmentCount) segments out of \(totalSegmentCount)."
    }

    private static func truncateInline(_ text: String, limit: Int) -> String {
        guard limit > 0 else { return "" }
        guard text.count > limit else { return text }
        guard limit > 1 else { return String(text.prefix(limit)) }
        return String(text.prefix(limit - 1)) + "…"
    }
}
