import ChatClient
import ChatUI
import Foundation
import OpenClawKit
import OSLog

private let logger = Logger(subsystem: "com.day1-labs.openava", category: "runtime.tools")

extension ToolDefinition: ToolExecutor {
    var displayName: String {
        functionName
    }
}

/// ToolProvider implementation that adapts ToolRegistry to the session tool interface.
final class ToolRegistryProvider: ToolProvider {
    private let toolRuntime: LocalToolRuntime
    private let invocationSessionID: String

    init(toolRuntime: LocalToolRuntime, invocationSessionID: String) {
        self.toolRuntime = toolRuntime
        self.invocationSessionID = invocationSessionID
    }

    func enabledTools() async -> [ChatRequestBody.Tool] {
        await toolRuntime.ensureRegistryReady()
        return await ToolRegistry.shared.allDefinitions().map(\.chatRequestTool)
    }

    func findTool(for request: ToolRequest) async -> ToolExecutor? {
        await toolRuntime.ensureRegistryReady()
        return await ToolRegistry.shared.definition(forFunctionName: request.name)
    }

    func executeTool(
        _ tool: ToolExecutor,
        parameters: String
    ) async throws -> ToolResult {
        guard let definition = tool as? ToolDefinition else {
            throw ToolExecutionError.invalidToolType
        }

        let request = BridgeInvokeRequest(
            id: UUID().uuidString,
            command: definition.command,
            paramsJSON: parameters.isEmpty ? nil : parameters
        )

        logger.notice(
            "registry provider execute start session=\(self.invocationSessionID, privacy: .public) command=\(definition.command, privacy: .public) requestID=\(request.id, privacy: .public) cancelled=\(String(Task.isCancelled), privacy: .public)"
        )

        let response = await toolRuntime.handle(request, sessionID: invocationSessionID)

        logger.notice(
            "registry provider execute end session=\(self.invocationSessionID, privacy: .public) command=\(definition.command, privacy: .public) requestID=\(request.id, privacy: .public) ok=\(String(response.ok), privacy: .public) cancelled=\(String(Task.isCancelled), privacy: .public)"
        )

        if response.ok {
            if let payload = response.payload {
                return ToolResult(text: payload)
            }
            return ToolResult(text: "{}")
        } else {
            let errorMessage = response.error?.message ?? L10n.tr("common.unknownError")
            return ToolResult(error: errorMessage)
        }
    }
}

// MARK: - Error Types

private enum ToolExecutionError: LocalizedError {
    case invalidToolType

    var errorDescription: String? {
        switch self {
        case .invalidToolType:
            return L10n.tr("chat.tool.error.invalidToolType")
        }
    }
}
