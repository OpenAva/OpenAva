import ChatClient
import ChatUI
import Foundation
import OpenClawKit
import OSLog
import UIKit

private let logger = Logger(subsystem: "com.day1-labs.openava", category: "runtime.tools")

/// ToolExecutor implementation that wraps a tool from ToolRegistry.
final class RegistryToolExecutor: ToolExecutor {
    let displayName: String
    let iconName: String
    let command: String
    let isReadOnly: Bool
    let isDestructive: Bool
    let isConcurrencySafe: Bool
    let maxResultSizeChars: Int?

    init(definition: ToolDefinition, iconName: String) {
        self.displayName = definition.functionName
        self.command = definition.command
        self.iconName = iconName
        self.isReadOnly = definition.resolvedIsReadOnly
        self.isDestructive = definition.resolvedIsDestructive
        self.isConcurrencySafe = definition.resolvedIsConcurrencySafe
        self.maxResultSizeChars = definition.maxResultSizeChars
    }
}

/// ToolProvider implementation that adapts ToolRegistry to ChatUI's ToolProvider protocol.
final class RegistryToolProvider: ToolProvider {
    private let toolInvokeService: LocalToolInvokeService
    private let invocationSessionID: String

    init(toolInvokeService: LocalToolInvokeService, invocationSessionID: String) {
        self.toolInvokeService = toolInvokeService
        self.invocationSessionID = invocationSessionID
    }

    func enabledTools() async -> [ChatRequestBody.Tool] {
        let definitions = await ToolRegistry.shared.allDefinitions()
        return definitions.map { definition -> ChatRequestBody.Tool in
            .function(
                name: definition.functionName,
                description: definition.description,
                parameters: convertParametersSchema(definition.parametersSchema),
                strict: nil
            )
        }
    }

    func findTool(for request: ToolRequest) async -> ToolExecutor? {
        guard let definition = await ToolRegistry.shared.definition(forFunctionName: request.name) else {
            return nil
        }
        let iconName = iconNameForCommand(definition.command)
        return RegistryToolExecutor(
            definition: definition,
            iconName: iconName
        )
    }

    func executeTool(
        _ tool: ToolExecutor,
        parameters: String,
        anchor _: UIView?
    ) async throws -> ToolResult {
        guard let registryTool = tool as? RegistryToolExecutor else {
            throw ToolExecutionError.invalidToolType
        }

        let request = BridgeInvokeRequest(
            id: UUID().uuidString,
            command: registryTool.command,
            paramsJSON: parameters.isEmpty ? nil : parameters
        )

        logger.notice(
            "registry provider execute start session=\(self.invocationSessionID, privacy: .public) command=\(registryTool.command, privacy: .public) requestID=\(request.id, privacy: .public) cancelled=\(String(Task.isCancelled), privacy: .public)"
        )

        let response = await toolInvokeService.handle(request, sessionID: invocationSessionID)

        logger.notice(
            "registry provider execute end session=\(self.invocationSessionID, privacy: .public) command=\(registryTool.command, privacy: .public) requestID=\(request.id, privacy: .public) ok=\(String(response.ok), privacy: .public) cancelled=\(String(Task.isCancelled), privacy: .public)"
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

    func prepareForConversation() async {
        // No preparation needed for registry-based tools
    }

    // MARK: - Private Helpers

    private func convertParametersSchema(_ schema: AnyCodable) -> [String: AnyCodingValue]? {
        do {
            let data = try JSONEncoder().encode(schema)
            return try JSONDecoder().decode([String: AnyCodingValue].self, from: data)
        } catch {
            logger.error("Failed to convert parameters schema: \(error)")
            return nil
        }
    }

    private func iconNameForCommand(_ command: String) -> String {
        let commandPrefix = command.split(separator: ".").first.map(String.init) ?? command
        switch commandPrefix {
        case "camera":
            return "camera.fill"
        case "screen":
            return "rectangle.on.rectangle"
        case "location":
            return "location.fill"
        case "device":
            return "iphone"
        case "watch":
            return "watchface"
        case "photos":
            return "photo.fill"
        case "contacts":
            return "person.crop.circle.fill"
        case "calendar":
            return "calendar"
        case "reminders":
            return "checklist"
        case "motion":
            return "figure.walk"
        case "system":
            return "bell.fill"
        case "chat":
            return "message.fill"
        case "file":
            return "folder.fill"
        case "web":
            return "globe"
        case "web_view":
            return "globe"
        case "memory":
            return "clock.arrow.trianglehead.counterclockwise.rotate.90"
        case "finance":
            return "chart.line.uptrend.xyaxis"
        default:
            return "wrench.and.screwdriver.fill"
        }
    }
}

// MARK: - Error Types

private enum ToolExecutionError: LocalizedError {
    case invalidToolType
    case executionFailed(String)

    var errorDescription: String? {
        switch self {
        case .invalidToolType:
            return L10n.tr("chat.tool.error.invalidToolType")
        case let .executionFailed(message):
            return L10n.tr("chat.tool.error.executionFailed", message)
        }
    }
}
