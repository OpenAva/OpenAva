import Foundation
import OpenClawKit
import OpenClawProtocol

extension TextImageRenderService: ToolDefinitionProvider {
    func toolDefinitions() -> [ToolDefinition] {
        [
            ToolDefinition(
                functionName: "text_to_social_images",
                command: "text.image.render",
                description: "Render plain text into one or more social-media-ready image cards with clean typography and automatic pagination.",
                parametersSchema: AnyCodable([
                    "type": "object",
                    "properties": [
                        "text": [
                            "type": "string",
                            "description": "The main text content to place on images.",
                        ],
                        "title": [
                            "type": "string",
                            "description": "Optional card title shown at the top.",
                        ],
                        "theme": [
                            "type": "string",
                            "enum": ["notes", "dark"],
                            "description": "Visual theme for card style.",
                        ],
                        "width": [
                            "type": "integer",
                            "minimum": 720,
                            "maximum": 2000,
                            "description": "Image width in pixels. Height is derived from aspectRatio.",
                        ],
                        "aspectRatio": [
                            "type": "string",
                            "description": "Aspect ratio formatted as 'w:h', e.g. '3:4', '4:5', '16:9'.",
                        ],
                        "maxPages": [
                            "type": "integer",
                            "minimum": 1,
                            "maximum": 12,
                            "description": "Maximum number of generated images before truncation.",
                        ],
                    ],
                    "required": ["text"],
                    "additionalProperties": false,
                ] as [String: Any])
            ),
        ]
    }

    func registerHandlers(into handlers: inout [String: ToolHandler]) {
        handlers["text.image.render"] = { [weak self] request in
            guard let self else { throw NodeCapabilityRouter.RouterError.handlerUnavailable }
            return try await self.handleTextImageRenderInvoke(request)
        }
    }

    /// Render plain text into social-media-ready image cards.
    private func handleTextImageRenderInvoke(_ request: BridgeInvokeRequest) async throws -> BridgeInvokeResponse {
        struct Params: Codable {
            let text: String
            let title: String?
            let theme: String?
            let width: Int?
            let aspectRatio: String?
            let maxPages: Int?
        }

        let params = try ToolInvocationHelpers.decodeParams(Params.self, from: request.paramsJSON)
        let result = try render(
            request: TextImageRenderService.Request(
                text: params.text,
                title: params.title,
                theme: params.theme,
                width: params.width,
                aspectRatio: params.aspectRatio,
                maxPages: params.maxPages
            )
        )

        var mediaTags: [String] = []
        for page in result.pages {
            let mediaFile: PersistedMediaFile
            if let persister = mediaPersister {
                mediaFile = try persister(page.data, page.format, "text-card-p\(page.index)")
            } else {
                // Fallback: no persister available, use placeholder
                mediaFile = PersistedMediaFile(path: "unavailable", sizeBytes: page.data.count)
            }
            mediaTags.append(
                ToolInvocationHelpers.composeTag(
                    name: "media",
                    attributes: [
                        ("tool", "text_image_render"),
                        ("page", "\(page.index)"),
                        ("total-pages", "\(page.total)"),
                        ("format", page.format),
                        ("mime-type", ToolInvocationHelpers.mimeType(for: page.format)),
                        ("size-bytes", "\(mediaFile.sizeBytes)"),
                        ("width", "\(page.width)"),
                        ("height", "\(page.height)"),
                        ("path", mediaFile.path),
                    ]
                )
            )
        }

        let payload = ToolInvocationHelpers.composeBlock(
            name: "text-image-render",
            attributes: [
                ("pages", "\(result.pages.count)"),
                ("truncated", result.truncated ? "1" : "0"),
                ("theme", result.theme),
            ],
            children: mediaTags
        )

        return ToolInvocationHelpers.successResponse(id: request.id, payload: payload)
    }
}
