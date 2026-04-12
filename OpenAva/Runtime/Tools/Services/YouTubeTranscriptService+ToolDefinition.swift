import Foundation
import OpenClawKit
import OpenClawProtocol

extension YouTubeTranscriptService: ToolDefinitionProvider {
    nonisolated func toolDefinitions() -> [ToolDefinition] {
        [
            ToolDefinition(
                functionName: "youtube_transcript",
                command: "youtube.transcript",
                description: "Fetch and read transcript text from a YouTube video URL or video ID, with optional preferred language hint and timestamped segments.",
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
                        "maxSegments": [
                            "type": "integer",
                            "minimum": 1,
                            "maximum": 2000,
                            "description": "Maximum transcript segments returned (default: 500).",
                        ],
                        "format": [
                            "type": "string",
                            "enum": ["transcript", "segments"],
                            "description": "Output format. 'transcript' (default): plain full transcript text. 'segments': numbered lines with timestamps for each segment.",
                        ],
                    ],
                    "required": ["input"],
                    "additionalProperties": false,
                ] as [String: Any]),
                isReadOnly: true,
                isConcurrencySafe: true,
                maxResultSizeChars: 32 * 1024
            ),
        ]
    }

    func registerHandlers(into handlers: inout [String: ToolHandler]) {
        handlers["youtube.transcript"] = { [weak self] request in
            guard let self else { throw NodeCapabilityRouter.RouterError.handlerUnavailable }
            return try await self.handleYouTubeTranscriptInvoke(request)
        }
    }

    private func handleYouTubeTranscriptInvoke(_ request: BridgeInvokeRequest) async throws -> BridgeInvokeResponse {
        struct Params: Codable {
            let input: String
            let preferredLanguage: String?
            let maxSegments: Int?
            let format: String?
        }

        let params = try ToolInvocationHelpers.decodeParams(Params.self, from: request.paramsJSON)
        let normalizedInput = params.input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedInput.isEmpty else {
            return ToolInvocationHelpers.invalidRequest(id: request.id, "input is required")
        }

        let result = try await fetchTranscript(
            input: normalizedInput,
            preferredLanguage: params.preferredLanguage,
            maxSegments: params.maxSegments ?? 500
        )

        let header = "## YouTube Transcript\n- video_id: \(result.videoID)\n- title: \(result.title ?? "")\n- language: \(result.language)\n- track: \(result.trackName)\n- segments: \(result.segmentCount)\n- summary: \(result.message)"
        let text: String
        switch params.format ?? "transcript" {
        case "segments":
            let segmentLines = result.segments.enumerated().map { index, segment in
                "\(index + 1). [\(String(format: "%.2f", segment.startSeconds))s +\(String(format: "%.2f", segment.durationSeconds))s] \(segment.text)"
            }
            let body = segmentLines.isEmpty ? "- (empty)" : segmentLines.joined(separator: "\n")
            text = "\(header)\n\n\(body)"
        default: // "transcript"
            let transcriptBody = result.transcript.isEmpty ? "- (empty)" : result.transcript
            text = "\(header)\n\n### Transcript\n\(transcriptBody)"
        }
        return ToolInvocationHelpers.successResponse(id: request.id, payload: text)
    }
}
