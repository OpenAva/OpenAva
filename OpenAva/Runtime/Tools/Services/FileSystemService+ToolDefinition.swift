import Foundation
import OpenClawKit
import OpenClawProtocol

/// Tool definition provider for file system service
extension FileSystemService: ToolDefinitionProvider {
    nonisolated func toolDefinitions() -> [ToolDefinition] {
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
                ] as [String: Any]),
                isReadOnly: true,
                isConcurrencySafe: true,
                maxResultSizeChars: 48 * 1024
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
                ] as [String: Any]),
                isReadOnly: false,
                isDestructive: true,
                isConcurrencySafe: false
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
                ] as [String: Any]),
                isReadOnly: false,
                isDestructive: true,
                isConcurrencySafe: false
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
                ] as [String: Any]),
                isReadOnly: false,
                isDestructive: true,
                isConcurrencySafe: false
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
                ] as [String: Any]),
                isReadOnly: true,
                isConcurrencySafe: true,
                maxResultSizeChars: 24 * 1024
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
                ] as [String: Any]),
                isReadOnly: false,
                isDestructive: true,
                isConcurrencySafe: false
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
                ] as [String: Any]),
                isReadOnly: false,
                isDestructive: true,
                isConcurrencySafe: false
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
                ] as [String: Any]),
                isReadOnly: true,
                isConcurrencySafe: true,
                maxResultSizeChars: 24 * 1024
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
                ] as [String: Any]),
                isReadOnly: true,
                isConcurrencySafe: true,
                maxResultSizeChars: 24 * 1024
            ),
        ]
    }

    func registerHandlers(into handlers: inout [String: ToolHandler]) {
        let commands = ["fs.read", "fs.write", "fs.list", "fs.mkdir", "fs.delete", "fs.replace", "fs.append", "fs.find", "fs.grep"]
        for command in commands {
            handlers[command] = { [weak self] request in
                guard let self else { throw NodeCapabilityRouter.RouterError.handlerUnavailable }
                return try await self.handleFileSystemInvoke(request)
            }
        }
    }

    private func handleFileSystemInvoke(_ request: BridgeInvokeRequest) async throws -> BridgeInvokeResponse {
        func resolvedPathText(_ path: String) async throws -> String {
            let metadata = try await pathMetadata(path: path)
            return metadata.resolvedPath
        }

        func conciseListText(for result: DirectoryListResult, resolvedPath: String) -> String {
            if result.items.isEmpty {
                return "Empty: \(resolvedPath)"
            }

            let itemLines = result.items.map { item in
                item.isDirectory ? "  \(item.name)/" : "  \(item.name)"
            }

            return ([resolvedPath] + itemLines).joined(separator: "\n")
        }

        switch request.command {
        case "fs.read":
            struct Params: Codable {
                let path: String
                let startLine: Int?
                let endLine: Int?
            }
            let params = try ToolInvocationHelpers.decodeParams(Params.self, from: request.paramsJSON)
            let result = try await readFile(
                path: params.path,
                startLine: params.startLine,
                endLine: params.endLine
            )
            var text = result.content
            if result.truncated {
                text += "\n\n... (truncated — file is \(result.totalChars) chars, limit 128000)"
            }
            return ToolInvocationHelpers.successResponse(id: request.id, payload: text)

        case "fs.write":
            struct Params: Codable {
                let path: String
                let content: String
                let createDirectories: Bool?
            }
            let params = try ToolInvocationHelpers.decodeParams(Params.self, from: request.paramsJSON)
            let result = try await writeFile(
                path: params.path,
                content: params.content,
                createDirectories: params.createDirectories ?? true
            )
            let resolvedPath = try await resolvedPathText(params.path)
            let verb = result.created ? "created" : "updated"
            let text = "OK: \(verb) \(result.size) bytes -> \(resolvedPath)"
            return ToolInvocationHelpers.successResponse(id: request.id, payload: text)

        case "fs.replace":
            struct Params: Codable {
                let path: String
                let oldText: String
                let newText: String
            }
            let params = try ToolInvocationHelpers.decodeParams(Params.self, from: request.paramsJSON)
            let result = try await replaceInFile(
                path: params.path,
                oldText: params.oldText,
                newText: params.newText
            )
            let resolvedPath = try await resolvedPathText(params.path)
            let text = "OK: replaced \(result.occurrences) occurrence\(result.occurrences == 1 ? "" : "s") -> \(resolvedPath)"
            return ToolInvocationHelpers.successResponse(id: request.id, payload: text)

        case "fs.append":
            struct Params: Codable {
                let path: String
                let content: String
            }
            let params = try ToolInvocationHelpers.decodeParams(Params.self, from: request.paramsJSON)
            let result = try await appendToFile(
                path: params.path,
                content: params.content
            )
            let resolvedPath = try await resolvedPathText(params.path)
            let text = "OK: appended \(result.appendedSize) bytes -> \(resolvedPath)"
            return ToolInvocationHelpers.successResponse(id: request.id, payload: text)

        case "fs.list":
            struct Params: Codable {
                let path: String
            }
            let params = try ToolInvocationHelpers.decodeParams(Params.self, from: request.paramsJSON)
            let result = try await listDirectory(path: params.path)
            let resolvedPath = try await resolvedPathText(params.path)
            let text = conciseListText(for: result, resolvedPath: resolvedPath)
            return ToolInvocationHelpers.successResponse(id: request.id, payload: text)

        case "fs.mkdir":
            struct Params: Codable {
                let path: String
                let recursive: Bool?
                let ifNotExists: Bool?
            }
            let params = try ToolInvocationHelpers.decodeParams(Params.self, from: request.paramsJSON)
            let result = try await makeDirectory(
                path: params.path,
                recursive: params.recursive ?? true,
                ifNotExists: params.ifNotExists ?? true
            )
            let resolvedPath = try await resolvedPathText(params.path)
            let verb = result.created ? "created" : "already exists"
            let text = "OK: \(verb) directory -> \(resolvedPath)"
            return ToolInvocationHelpers.successResponse(id: request.id, payload: text)

        case "fs.delete":
            struct Params: Codable {
                let path: String
            }
            let params = try ToolInvocationHelpers.decodeParams(Params.self, from: request.paramsJSON)
            let result = try await delete(path: params.path)
            let resolvedPath = try await resolvedPathText(params.path)
            let text = "OK: deleted -> \(resolvedPath)"
            return ToolInvocationHelpers.successResponse(id: request.id, payload: text)

        case "fs.find":
            struct Params: Codable {
                let glob: String
                let path: String?
                let recursive: Bool?
            }
            let params = try ToolInvocationHelpers.decodeParams(Params.self, from: request.paramsJSON)
            let result = try await findFiles(
                glob: params.glob,
                path: params.path ?? ".",
                recursive: params.recursive ?? true
            )
            let itemLines = result.items.map { item in
                "[FILE] \(item.path) (\(item.size ?? 0) bytes)"
            }
            let text = itemLines.isEmpty ? "No files matching '\(result.pattern)'" : itemLines.joined(separator: "\n")
            return ToolInvocationHelpers.successResponse(id: request.id, payload: text)

        case "fs.grep":
            struct Params: Codable {
                let pattern: String
                let path: String?
                let recursive: Bool?
                let isRegex: Bool?
                let caseInsensitive: Bool?
            }
            let params = try ToolInvocationHelpers.decodeParams(Params.self, from: request.paramsJSON)
            let result = try await grep(
                pattern: params.pattern,
                path: params.path ?? ".",
                recursive: params.recursive ?? true,
                isRegex: params.isRegex ?? true,
                caseInsensitive: params.caseInsensitive ?? true
            )
            let matchLines = result.matches.map { match in
                "\(match.path):\(match.lineNumber): \(match.line)"
            }
            let text = matchLines.isEmpty ? "No matches for '\(result.pattern)'" : matchLines.joined(separator: "\n")
            return ToolInvocationHelpers.successResponse(id: request.id, payload: text)

        default:
            return ToolInvocationHelpers.invalidRequest(id: request.id, "unknown command")
        }
    }
}
