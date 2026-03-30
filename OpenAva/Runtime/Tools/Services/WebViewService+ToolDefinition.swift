import Foundation
import OpenClawKit
import OpenClawProtocol

extension WebViewService: ToolDefinitionProvider {
    func toolDefinitions() -> [ToolDefinition] {
        [
            // Navigate to a URL and return an interactive element snapshot.
            ToolDefinition(
                functionName: "web_view",
                command: "web_view",
                description: "Open a floating web view, load the URL, and return a numbered list of interactive elements (links, buttons, inputs, selects). Use the element numbers with web_view_click, web_view_type, etc. Call web_view_read to get page content as markdown.",
                parametersSchema: AnyCodable([
                    "type": "object",
                    "properties": [
                        "url": [
                            "type": "string",
                            "description": "The URL to open (http/https/file), or an absolute local file path",
                        ],
                    ],
                    "required": ["url"],
                    "additionalProperties": false,
                ] as [String: Any])
            ),

            // Refresh the interactive element list for the currently open page.
            ToolDefinition(
                functionName: "web_view_snapshot",
                command: "web_view_snapshot",
                description: "Refresh and return the numbered list of interactive elements on the currently open web page. Call this after page changes to update element refs before clicking or typing.",
                parametersSchema: AnyCodable([
                    "type": "object",
                    "properties": [:] as [String: Any],
                    "additionalProperties": false,
                ] as [String: Any])
            ),

            // Click an element by its ref number.
            ToolDefinition(
                functionName: "web_view_click",
                command: "web_view_click",
                description: "Click an element on the current page. Use the element number from web_view or web_view_snapshot (e.g. \"3\" for [3]).",
                parametersSchema: AnyCodable([
                    "type": "object",
                    "properties": [
                        "ref": [
                            "type": "string",
                            "description": "Element ref number from the snapshot, e.g. \"3\"",
                        ],
                    ],
                    "required": ["ref"],
                    "additionalProperties": false,
                ] as [String: Any])
            ),

            // Fill an input field.
            ToolDefinition(
                functionName: "web_view_type",
                command: "web_view_type",
                description: "Fill text into an input or textarea element identified by its ref number. Optionally submit the form after typing.",
                parametersSchema: AnyCodable([
                    "type": "object",
                    "properties": [
                        "ref": [
                            "type": "string",
                            "description": "Element ref number from the snapshot",
                        ],
                        "text": [
                            "type": "string",
                            "description": "Text to type into the element",
                        ],
                        "submit": [
                            "type": "boolean",
                            "description": "Submit the form after typing (default: false)",
                        ],
                    ],
                    "required": ["ref", "text"],
                    "additionalProperties": false,
                ] as [String: Any])
            ),

            // Scroll the page.
            ToolDefinition(
                functionName: "web_view_scroll",
                command: "web_view_scroll",
                description: "Scroll the current web page in the given direction.",
                parametersSchema: AnyCodable([
                    "type": "object",
                    "properties": [
                        "direction": [
                            "type": "string",
                            "enum": ["up", "down", "left", "right"],
                            "description": "Scroll direction",
                        ],
                        "amount": [
                            "type": "integer",
                            "description": "Scroll distance in pixels (default: 300)",
                        ],
                    ],
                    "required": ["direction"],
                    "additionalProperties": false,
                ] as [String: Any])
            ),

            // Select a dropdown option.
            ToolDefinition(
                functionName: "web_view_select",
                command: "web_view_select",
                description: "Select an option in a <select> dropdown element identified by its ref number.",
                parametersSchema: AnyCodable([
                    "type": "object",
                    "properties": [
                        "ref": [
                            "type": "string",
                            "description": "Element ref number of the <select> element",
                        ],
                        "value": [
                            "type": "string",
                            "description": "The option value to select",
                        ],
                    ],
                    "required": ["ref", "value"],
                    "additionalProperties": false,
                ] as [String: Any])
            ),

            // Browser navigation.
            ToolDefinition(
                functionName: "web_view_navigate",
                command: "web_view_navigate",
                description: "Navigate the browser history or reload the current page.",
                parametersSchema: AnyCodable([
                    "type": "object",
                    "properties": [
                        "direction": [
                            "type": "string",
                            "enum": ["back", "forward", "reload"],
                            "description": "Navigation action",
                        ],
                    ],
                    "required": ["direction"],
                    "additionalProperties": false,
                ] as [String: Any])
            ),

            // Close the floating web view.
            ToolDefinition(
                functionName: "web_view_close",
                command: "web_view_close",
                description: "Close and dismiss the floating web view overlay.",
                parametersSchema: AnyCodable([
                    "type": "object",
                    "properties": [:] as [String: Any],
                    "additionalProperties": false,
                ] as [String: Any])
            ),

            // Read page content as markdown.
            ToolDefinition(
                functionName: "web_view_read",
                command: "web_view_read",
                description: "Extract the current page content as markdown. Use this when you need to read the text content of the page. Call web_view or web_view_snapshot to interact with elements.",
                parametersSchema: AnyCodable([
                    "type": "object",
                    "properties": [
                        "maxLength": [
                            "type": "integer",
                            "description": "Maximum characters to return (default: 120000)",
                        ],
                    ],
                    "additionalProperties": false,
                ] as [String: Any])
            ),
        ]
    }
}
