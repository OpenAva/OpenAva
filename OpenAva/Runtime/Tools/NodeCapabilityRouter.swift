import Foundation
import OpenClawKit

@MainActor
final class NodeCapabilityRouter {
    enum RouterError: Error {
        case unknownCommand
        case handlerUnavailable
    }

    private let handlers: [String: ToolHandler]

    init(handlers: [String: ToolHandler]) {
        self.handlers = handlers
    }

    /// Build a router from all handlers currently registered in ToolRegistry.
    static func fromRegistry() async -> NodeCapabilityRouter {
        let handlers = await ToolRegistry.shared.allHandlers()
        return NodeCapabilityRouter(handlers: handlers)
    }

    func handle(_ request: BridgeInvokeRequest) async throws -> BridgeInvokeResponse {
        guard let handler = handlers[request.command] else {
            throw RouterError.unknownCommand
        }
        return try await handler(request)
    }
}
