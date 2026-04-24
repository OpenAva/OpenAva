import Foundation
import OpenClawKit
import OpenClawProtocol

extension BashService: ToolDefinitionProvider {
    nonisolated func toolDefinitions() -> [ToolDefinition] {
        #if os(macOS) || targetEnvironment(macCatalyst)
            return [
                ToolDefinition(
                    functionName: "bash",
                    command: "bash.execute",
                    description: "Run a shell command with Claude Code-compatible parameters: `command`, `timeout`, `description`, `run_in_background`, and `dangerouslyDisableSandbox`. Commands run from the active workspace using `/bin/bash -lc`, force non-interactive pager settings, support a single leading `cd <path> && ...` that stays inside the workspace, and reject interactive or unsafe shell features.",
                    parametersSchema: AnyCodable([
                        "type": "object",
                        "properties": [
                            "command": [
                                "type": "string",
                                "description": "Shell command to run.",
                            ],
                            "description": [
                                "type": "string",
                                "description": "Short description of what the command does.",
                            ],
                            "timeout": [
                                "type": "integer",
                                "description": "Timeout in milliseconds. Defaults to 120000 and is capped at 600000.",
                            ],
                            "run_in_background": [
                                "type": "boolean",
                                "description": "Run the command in the background and return a task id plus output path immediately.",
                            ],
                            "dangerouslyDisableSandbox": [
                                "type": "boolean",
                                "description": "Claude Code compatibility field. OpenAva still applies its built-in Bash permission policy when this field is set.",
                            ],
                        ],
                        "required": ["command"],
                        "additionalProperties": false,
                    ] as [String: Any]),
                    isReadOnly: false,
                    isDestructive: true,
                    isConcurrencySafe: false,
                    maxResultSizeChars: 30 * 1024
                ),
            ]
        #else
            return []
        #endif
    }

    nonisolated func registerHandlers(into handlers: inout [String: ToolHandler], context _: ToolHandlerRegistrationContext) {
        handlers["bash.execute"] = { [weak self] request in
            guard let self else {
                throw ToolHandlerError.handlerUnavailable
            }

            do {
                let params = try await MainActor.run {
                    try ToolInvocationHelpers.decodeParams(Request.self, from: request.paramsJSON)
                }
                let payload = try await self.execute(request: params)
                let payloadText = Self.formatExecutionPayload(payload, request: params)
                return await MainActor.run {
                    ToolInvocationHelpers.successResponse(id: request.id, payload: payloadText)
                }
            } catch let error as BashService.BashServiceError {
                let message = error.errorDescription ?? "Bash tool failed"
                switch error {
                case .unsupportedPlatform, .workspaceUnavailable:
                    return await MainActor.run {
                        ToolInvocationHelpers.unavailableResponse(id: request.id, message)
                    }
                case .invalidRequest:
                    return await MainActor.run {
                        ToolInvocationHelpers.invalidRequest(id: request.id, message)
                    }
                case .executionFailed:
                    return await MainActor.run {
                        ToolInvocationHelpers.unavailableResponse(id: request.id, message)
                    }
                }
            } catch {
                return await MainActor.run {
                    ToolInvocationHelpers.unavailableResponse(id: request.id, error.localizedDescription)
                }
            }
        }
    }

    private static func formatExecutionPayload(_ payload: ExecutionPayload, request: Request) -> String {
        let isBackground = payload.backgroundTaskId != nil
        var lines = ["## Bash"]

        if let description = request.description?.trimmingCharacters(in: .whitespacesAndNewlines), !description.isEmpty {
            lines.append("- description: \(description)")
        }

        lines.append("- command: \(request.command)")
        lines.append("- cwd: \(payload.cwd)")
        lines.append("- status: \(renderStatus(for: payload))")

        if isBackground {
            if let backgroundTaskId = payload.backgroundTaskId {
                lines.append("- background_task_id: \(backgroundTaskId)")
            }
            if let outputPath = payload.outputPath {
                lines.append("- output_path: \(outputPath)")
            }
            if let metadataPath = payload.persistedOutputPath {
                lines.append("- metadata_path: \(metadataPath)")
            }
            if payload.noOutputExpected {
                lines.append("- no_output_expected: yes")
            }
            lines.append("- output: background command started; inspect output_path for live logs")
            return lines.joined(separator: "\n")
        }

        lines.append("- exit_code: \(payload.exitCode)")
        lines.append("- duration_ms: \(payload.durationMs)")

        if payload.timedOut {
            lines.append("- timed_out: yes")
        }
        if payload.interrupted, !payload.timedOut {
            lines.append("- interrupted: yes")
        }
        if payload.truncated {
            lines.append("- truncated: yes")
        }
        if payload.noOutputExpected {
            lines.append("- no_output_expected: yes")
        }
        if let persistedOutputPath = payload.persistedOutputPath {
            lines.append("- persisted_output_path: \(persistedOutputPath)")
        }

        var sections = [lines.joined(separator: "\n")]

        if !payload.stdout.isEmpty {
            let heading = payload.truncated ? "### Stdout Preview" : "### Stdout"
            sections.append("\(heading)\n\(payload.stdout)")
        }

        if !payload.stderr.isEmpty {
            let heading = payload.truncated ? "### Stderr Preview" : "### Stderr"
            sections.append("\(heading)\n\(payload.stderr)")
        }

        if payload.stdout.isEmpty, payload.stderr.isEmpty {
            let outputSummary = payload.noOutputExpected ? "(no output; this is expected for this command)" : "(no output)"
            sections.append("### Output\n\(outputSummary)")
        }

        if payload.truncated, let persistedOutputPath = payload.persistedOutputPath {
            sections.append("### Note\nOutput was truncated for inline display. Full captured output was saved to:\n\(persistedOutputPath)")
        }

        return sections.joined(separator: "\n\n")
    }

    private static func renderStatus(for payload: ExecutionPayload) -> String {
        if payload.backgroundTaskId != nil {
            return "started_in_background"
        }
        if payload.timedOut {
            return "timed_out"
        }
        if payload.interrupted {
            return "interrupted"
        }
        return payload.exitCode == 0 ? "completed" : "failed"
    }
}
