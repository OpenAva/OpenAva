import Foundation
import OpenClawKit
import OpenClawProtocol

/// Tool definition provider for file system service
extension FileSystemService: ToolDefinitionProvider {
    func toolDefinitions() -> [ToolDefinition] {
        [
            ToolDefinition(
                functionName: "fs_read",
                command: "fs.read",
                description: "Read content from a file. Supports workspace-relative paths and absolute paths inside allowed read-only roots such as built-in Skills. Optionally specify a line range.",
                parametersSchema: AnyCodable([
                    "type": "object",
                    "properties": [
                        "path": [
                            "type": "string",
                            "description": "Workspace-relative path, or an absolute path inside an allowed read-only root such as built-in Skills",
                        ],
                        "startLine": [
                            "type": "integer",
                            "description": "Starting line number (1-indexed, optional)",
                        ],
                        "endLine": [
                            "type": "integer",
                            "description": "Ending line number (1-indexed, optional)",
                        ],
                    ],
                    "required": ["path"],
                    "additionalProperties": false,
                ] as [String: Any])
            ),
            ToolDefinition(
                functionName: "fs_write",
                command: "fs.write",
                description: "Write content to a file. Creates the file if it doesn't exist, overwrites if it does.",
                parametersSchema: AnyCodable([
                    "type": "object",
                    "properties": [
                        "path": [
                            "type": "string",
                            "description": "Workspace-relative path, or an absolute path inside the active agent workspace directory",
                        ],
                        "content": [
                            "type": "string",
                            "description": "Content to write to the file",
                        ],
                        "createDirectories": [
                            "type": "boolean",
                            "description": "Whether to create parent directories if they don't exist (default: true)",
                        ],
                    ],
                    "required": ["path", "content"],
                    "additionalProperties": false,
                ] as [String: Any])
            ),
            ToolDefinition(
                functionName: "fs_replace",
                command: "fs.replace",
                description: "Find and replace text within a file. The old text must match exactly.",
                parametersSchema: AnyCodable([
                    "type": "object",
                    "properties": [
                        "path": [
                            "type": "string",
                            "description": "Workspace-relative path, or an absolute path inside the active agent workspace directory",
                        ],
                        "oldText": [
                            "type": "string",
                            "description": "Text to find (must match exactly)",
                        ],
                        "newText": [
                            "type": "string",
                            "description": "Text to replace with",
                        ],
                    ],
                    "required": ["path", "oldText", "newText"],
                    "additionalProperties": false,
                ] as [String: Any])
            ),
            ToolDefinition(
                functionName: "fs_append",
                command: "fs.append",
                description: "Append content to the end of a file. Creates the file if it doesn't exist.",
                parametersSchema: AnyCodable([
                    "type": "object",
                    "properties": [
                        "path": [
                            "type": "string",
                            "description": "Workspace-relative path, or an absolute path inside the active agent workspace directory",
                        ],
                        "content": [
                            "type": "string",
                            "description": "Content to append to the file",
                        ],
                    ],
                    "required": ["path", "content"],
                    "additionalProperties": false,
                ] as [String: Any])
            ),
            ToolDefinition(
                functionName: "fs_list",
                command: "fs.list",
                description: "List files and directories in a directory. Supports workspace-relative paths and absolute paths inside allowed read-only roots such as built-in Skills.",
                parametersSchema: AnyCodable([
                    "type": "object",
                    "properties": [
                        "path": [
                            "type": "string",
                            "description": "Workspace-relative path, or an absolute path inside an allowed read-only root such as built-in Skills (use '.' for workspace root)",
                        ],
                    ],
                    "required": ["path"],
                    "additionalProperties": false,
                ] as [String: Any])
            ),
            ToolDefinition(
                functionName: "fs_mkdir",
                command: "fs.mkdir",
                description: "Create a directory at the given path. By default, creates intermediate directories and succeeds if the directory already exists.",
                parametersSchema: AnyCodable([
                    "type": "object",
                    "properties": [
                        "path": [
                            "type": "string",
                            "description": "Workspace-relative path, or an absolute path inside the active agent workspace directory",
                        ],
                        "recursive": [
                            "type": "boolean",
                            "description": "Whether to create intermediate directories (default: true)",
                        ],
                        "ifNotExists": [
                            "type": "boolean",
                            "description": "Whether to succeed when target directory already exists (default: true)",
                        ],
                    ],
                    "required": ["path"],
                    "additionalProperties": false,
                ] as [String: Any])
            ),
            ToolDefinition(
                functionName: "fs_delete",
                command: "fs.delete",
                description: "Delete a file or directory. Directories are deleted recursively.",
                parametersSchema: AnyCodable([
                    "type": "object",
                    "properties": [
                        "path": [
                            "type": "string",
                            "description": "Workspace-relative path, or an absolute path inside the active agent workspace directory",
                        ],
                    ],
                    "required": ["path"],
                    "additionalProperties": false,
                ] as [String: Any])
            ),
            ToolDefinition(
                functionName: "fs_find",
                command: "fs.find",
                description: "Find files by glob pattern under a path. Supports basename matches like '*.swift' plus path-aware patterns such as 'Sources/**/*.swift', character classes, and brace groups like '*.{swift,md}'.",
                parametersSchema: AnyCodable([
                    "type": "object",
                    "properties": [
                        "glob": [
                            "type": "string",
                            "description": "Glob pattern to match files. Examples: '*.swift', 'Sources/**/*.swift', '*.{swift,md}'",
                        ],
                        "path": [
                            "type": "string",
                            "description": "Workspace-relative path, or an absolute path inside an allowed read-only root such as built-in Skills (default: '.')",
                        ],
                        "recursive": [
                            "type": "boolean",
                            "description": "Whether to search subdirectories (default: true)",
                        ],
                    ],
                    "required": ["glob"],
                    "additionalProperties": false,
                ] as [String: Any])
            ),
            ToolDefinition(
                functionName: "fs_grep",
                command: "fs.grep",
                description: "Search file contents for a pattern. Supports regex or literal searches.",
                parametersSchema: AnyCodable([
                    "type": "object",
                    "properties": [
                        "pattern": [
                            "type": "string",
                            "description": "Regex or literal pattern to search for",
                        ],
                        "path": [
                            "type": "string",
                            "description": "Workspace-relative path, or an absolute path inside an allowed read-only root such as built-in Skills (default: '.')",
                        ],
                        "recursive": [
                            "type": "boolean",
                            "description": "Whether to search subdirectories (default: true)",
                        ],
                        "isRegex": [
                            "type": "boolean",
                            "description": "Treat pattern as a regular expression (default: true)",
                        ],
                        "caseInsensitive": [
                            "type": "boolean",
                            "description": "Perform case-insensitive matching (default: true)",
                        ],
                    ],
                    "required": ["pattern"],
                    "additionalProperties": false,
                ] as [String: Any])
            ),
        ]
    }
}
