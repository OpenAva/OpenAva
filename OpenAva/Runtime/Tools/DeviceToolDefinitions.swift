import Foundation
import OpenClawKit
import OpenClawProtocol

/// Provides tool definitions for device-related commands (screen, camera, location, etc.)
struct DeviceToolDefinitions: ToolDefinitionProvider {
    enum PlatformProfile {
        case iOS
        case macCatalyst

        static var current: PlatformProfile {
            #if targetEnvironment(macCatalyst)
                .macCatalyst
            #else
                .iOS
            #endif
        }

        var unsupportedFunctionNames: Set<String> {
            switch self {
            case .iOS:
                return []
            case .macCatalyst:
                return [
                    "watch_status",
                    "watch_notify",
                    "motion_activity",
                    "motion_pedometer",
                ]
            }
        }

        var limitedFunctionNames: Set<String> {
            switch self {
            case .iOS:
                return []
            case .macCatalyst:
                return [
                    "screen_record",
                    "notify_user",
                    "location_get",
                    "photos_latest",
                    "camera_list",
                    "camera_snap",
                    "camera_clip",
                    "calendar_events",
                    "calendar_add",
                    "reminders_list",
                    "reminders_add",
                    "speech_transcribe",
                ]
            }
        }
    }

    private let platform: PlatformProfile

    init(platform: PlatformProfile = .current) {
        self.platform = platform
    }

    func toolDefinitions() -> [ToolDefinition] {
        var definitions = [
            makeTool(
                functionName: "screen_record",
                command: OpenClawScreenCommand.record.rawValue,
                description: "Record the screen for a short period and return the saved file path with metadata.",
                schema: [
                    "type": "object",
                    "properties": [
                        "screenIndex": ["type": "integer"],
                        "durationMs": ["type": "integer"],
                        "fps": ["type": "number"],
                        "format": ["type": "string"],
                        "includeAudio": ["type": "boolean"],
                    ],
                    "additionalProperties": false,
                ]
            ),
            makeTool(
                functionName: "notify_user",
                command: OpenClawSystemCommand.notify.rawValue,
                description: """
                Send a notification to the user with optional text-to-speech.

                Use this tool to alert the user about important information. The message can be displayed as a system notification and/or spoken aloud.

                Examples:
                - notify_user({message: "Your download is complete", speech: true})
                - notify_user({message: "Meeting in 5 minutes", speech: true, notification_sound: false})
                - notify_user({title: "Reminder", message: "Take a break", speech: false})
                """,
                schema: [
                    "type": "object",
                    "properties": [
                        "message": [
                            "type": "string",
                            "description": "The notification message content to display and optionally speak aloud.",
                        ],
                        "title": [
                            "type": "string",
                            "description": "Optional notification title. Defaults to app name if not provided.",
                        ],
                        "speech": [
                            "type": "boolean",
                            "description": "Whether to speak the message aloud using text-to-speech. Default: true.",
                        ],
                        "notification_sound": [
                            "type": "boolean",
                            "description": "Whether to play the system notification sound. Use false for silent notifications. Default: true.",
                        ],
                        "priority": [
                            "type": "string",
                            "enum": ["passive", "active", "timeSensitive"],
                            "description": "Notification priority. Use 'passive' for non-urgent, 'timeSensitive' for urgent alerts.",
                        ],
                    ],
                    "required": ["message"],
                ]
            ),
            makeTool(
                functionName: "location_get",
                command: OpenClawLocationCommand.get.rawValue,
                description: "Get the current device location.",
                schema: [
                    "type": "object",
                    "properties": [
                        "timeoutMs": ["type": "integer"],
                        "maxAgeMs": ["type": "integer"],
                        "desiredAccuracy": ["type": "string", "enum": ["coarse", "balanced", "precise"]],
                    ],
                    "additionalProperties": false,
                ]
            ),
            makeTool(
                functionName: "device_status",
                command: OpenClawDeviceCommand.status.rawValue,
                description: "Get battery, thermal, storage, network, and uptime status.",
                schema: [
                    "type": "object",
                    "properties": [:],
                    "additionalProperties": false,
                ]
            ),
            makeTool(
                functionName: "device_info",
                command: OpenClawDeviceCommand.info.rawValue,
                description: "Get device model and app information.",
                schema: [
                    "type": "object",
                    "properties": [:],
                    "additionalProperties": false,
                ]
            ),
            makeTool(
                functionName: "current_time",
                command: "current.time",
                description: "Get the current runtime date/time with timezone and locale details.",
                schema: [
                    "type": "object",
                    "properties": [
                        "timezone": ["type": "string"],
                        "locale": ["type": "string"],
                    ],
                    "additionalProperties": false,
                ]
            ),
            makeTool(
                functionName: "photos_latest",
                command: OpenClawPhotosCommand.latest.rawValue,
                description: "Fetch the latest photos from the library and return saved file paths with metadata.",
                schema: [
                    "type": "object",
                    "properties": [
                        "limit": ["type": "integer"],
                        "maxWidth": ["type": "integer"],
                        "quality": ["type": "number"],
                    ],
                    "additionalProperties": false,
                ]
            ),
            makeTool(
                functionName: "image_remove_background",
                command: OpenClawImageCommand.removeBackground.rawValue,
                description: "Remove the background from an image file using Apple's Vision foreground mask and write the result as a transparent PNG.",
                schema: [
                    "type": "object",
                    "properties": [
                        "inputPath": ["type": "string"],
                        "outputPath": ["type": "string"],
                    ],
                    "required": ["inputPath"],
                    "additionalProperties": false,
                ]
            ),
            makeTool(
                functionName: "contacts_search",
                command: OpenClawContactsCommand.search.rawValue,
                description: "Search contacts by name, phone, or email.",
                schema: [
                    "type": "object",
                    "properties": [
                        "query": ["type": "string"],
                        "limit": ["type": "integer"],
                    ],
                    "additionalProperties": false,
                ]
            ),
            makeTool(
                functionName: "contacts_add",
                command: OpenClawContactsCommand.add.rawValue,
                description: "Create a new contact.",
                schema: [
                    "type": "object",
                    "properties": [
                        "givenName": ["type": "string"],
                        "familyName": ["type": "string"],
                        "organizationName": ["type": "string"],
                        "displayName": ["type": "string"],
                        "phoneNumbers": ["type": "array", "items": ["type": "string"]],
                        "emails": ["type": "array", "items": ["type": "string"]],
                    ],
                    "additionalProperties": false,
                ]
            ),
            makeTool(
                functionName: "calendar_events",
                command: OpenClawCalendarCommand.events.rawValue,
                description: "List calendar events in a date range.",
                schema: [
                    "type": "object",
                    "properties": [
                        "startISO": ["type": "string"],
                        "endISO": ["type": "string"],
                        "limit": ["type": "integer"],
                    ],
                    "additionalProperties": false,
                ]
            ),
            makeTool(
                functionName: "calendar_add",
                command: OpenClawCalendarCommand.add.rawValue,
                description: "Create a calendar event.",
                schema: [
                    "type": "object",
                    "properties": [
                        "title": ["type": "string"],
                        "startISO": ["type": "string"],
                        "endISO": ["type": "string"],
                        "isAllDay": ["type": "boolean"],
                        "location": ["type": "string"],
                        "notes": ["type": "string"],
                        "calendarId": ["type": "string"],
                        "calendarTitle": ["type": "string"],
                    ],
                    "required": ["title", "startISO", "endISO"],
                    "additionalProperties": false,
                ]
            ),
            makeTool(
                functionName: "reminders_list",
                command: OpenClawRemindersCommand.list.rawValue,
                description: "List reminders.",
                schema: [
                    "type": "object",
                    "properties": [
                        "status": ["type": "string", "enum": ["incomplete", "completed", "all"]],
                        "limit": ["type": "integer"],
                    ],
                    "additionalProperties": false,
                ]
            ),
            makeTool(
                functionName: "reminders_add",
                command: OpenClawRemindersCommand.add.rawValue,
                description: "Create a reminder.",
                schema: [
                    "type": "object",
                    "properties": [
                        "title": ["type": "string"],
                        "dueISO": ["type": "string"],
                        "notes": ["type": "string"],
                        "listId": ["type": "string"],
                        "listName": ["type": "string"],
                    ],
                    "required": ["title"],
                    "additionalProperties": false,
                ]
            ),
            makeTool(
                functionName: "cron",
                command: "cron",
                description: "Schedule and manage local cron reminders (add, list, remove).",
                schema: [
                    "type": "object",
                    "properties": [
                        "action": ["type": "string", "enum": ["add", "list", "remove"]],
                        "message": ["type": "string"],
                        "at": ["type": "string"],
                        "everySeconds": ["type": "integer"],
                        "every_seconds": ["type": "integer"],
                        "id": ["type": "string"],
                        "jobId": ["type": "string"],
                        "job_id": ["type": "string"],
                    ],
                    "required": ["action"],
                    "additionalProperties": false,
                ]
            ),
            makeTool(
                functionName: "camera_list",
                command: OpenClawCameraCommand.list.rawValue,
                description: "List available cameras.",
                schema: [
                    "type": "object",
                    "properties": [:],
                    "additionalProperties": false,
                ]
            ),
            makeTool(
                functionName: "camera_snap",
                command: OpenClawCameraCommand.snap.rawValue,
                description: "Capture a still image from the camera and return the saved file path with metadata.",
                schema: [
                    "type": "object",
                    "properties": [
                        "facing": ["type": "string", "enum": ["back", "front"]],
                        "maxWidth": ["type": "integer"],
                        "quality": ["type": "number"],
                        "format": ["type": "string", "enum": ["jpg", "jpeg"]],
                        "deviceId": ["type": "string"],
                        "delayMs": ["type": "integer"],
                    ],
                    "additionalProperties": false,
                ]
            ),
            makeTool(
                functionName: "camera_clip",
                command: OpenClawCameraCommand.clip.rawValue,
                description: "Record a short camera clip and return the saved file path with metadata.",
                schema: [
                    "type": "object",
                    "properties": [
                        "facing": ["type": "string", "enum": ["back", "front"]],
                        "durationMs": ["type": "integer"],
                        "includeAudio": ["type": "boolean"],
                        "format": ["type": "string", "enum": ["mp4"]],
                        "deviceId": ["type": "string"],
                    ],
                    "additionalProperties": false,
                ]
            ),
            makeTool(
                functionName: "watch_status",
                command: OpenClawWatchCommand.status.rawValue,
                description: "Get Apple Watch connectivity status.",
                schema: [
                    "type": "object",
                    "properties": [:],
                    "additionalProperties": false,
                ]
            ),
            makeTool(
                functionName: "watch_notify",
                command: OpenClawWatchCommand.notify.rawValue,
                description: "Send a notification to Apple Watch.",
                schema: [
                    "type": "object",
                    "properties": [
                        "title": ["type": "string"],
                        "body": ["type": "string"],
                        "priority": ["type": "string", "enum": ["passive", "active", "timeSensitive"]],
                        "promptId": ["type": "string"],
                        "sessionKey": ["type": "string"],
                        "kind": ["type": "string"],
                        "details": ["type": "string"],
                        "expiresAtMs": ["type": "integer"],
                        "risk": ["type": "string", "enum": ["low", "medium", "high"]],
                    ],
                    "required": ["title", "body"],
                    "additionalProperties": false,
                ]
            ),
            makeTool(
                functionName: "motion_activity",
                command: OpenClawMotionCommand.activity.rawValue,
                description: "List recent motion activities.",
                schema: [
                    "type": "object",
                    "properties": [
                        "startISO": ["type": "string"],
                        "endISO": ["type": "string"],
                        "limit": ["type": "integer"],
                    ],
                    "additionalProperties": false,
                ]
            ),
            makeTool(
                functionName: "motion_pedometer",
                command: OpenClawMotionCommand.pedometer.rawValue,
                description: "Get pedometer samples for a date range.",
                schema: [
                    "type": "object",
                    "properties": [
                        "startISO": ["type": "string"],
                        "endISO": ["type": "string"],
                    ],
                    "additionalProperties": false,
                ]
            ),
            makeTool(
                functionName: "speech_transcribe",
                command: OpenClawSpeechCommand.transcribe.rawValue,
                description: "Transcribe an audio file to text using iOS Speech recognition.",
                schema: [
                    "type": "object",
                    "properties": [
                        "filePath": ["type": "string"],
                        "locale": ["type": "string"],
                        "taskHint": ["type": "string", "enum": ["unspecified", "dictation", "search", "confirmation"]],
                        "requiresOnDeviceRecognition": ["type": "boolean"],
                        "addsPunctuation": ["type": "boolean"],
                        "contextualStrings": ["type": "array", "items": ["type": "string"]],
                    ],
                    "required": ["filePath"],
                    "additionalProperties": false,
                ]
            ),
        ]

        definitions.removeAll { platform.unsupportedFunctionNames.contains($0.functionName) }

        return definitions
    }

    private func makeTool(
        functionName: String,
        command: String,
        description: String,
        schema: [String: Any]
    ) -> ToolDefinition {
        ToolDefinition(
            functionName: functionName,
            command: command,
            description: descriptionWithPlatformHint(base: description, functionName: functionName),
            parametersSchema: AnyCodable(schema)
        )
    }

    private func descriptionWithPlatformHint(base: String, functionName: String) -> String {
        guard platform == .macCatalyst,
              platform.limitedFunctionNames.contains(functionName)
        else {
            return base
        }

        return """
        \(base)

        Platform note: this capability is available in Mac Catalyst, but can be limited by macOS permissions or API behavior differences.
        """
    }
}
