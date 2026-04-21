import Foundation
import OpenClawKit
import OpenClawProtocol

extension MemoryTools {
    func registerHandlers(
        into handlers: inout [String: ToolHandler],
        context: ToolHandlerRegistrationContext
    ) {
        for command in ["memory.recall", "memory.upsert", "memory.forget", "memory.transcript_search"] {
            handlers[command] = { request in
                try await Self.handleMemoryInvoke(
                    request,
                    activeRuntimeRootURLProvider: context.activeRuntimeRootURLProvider
                )
            }
        }
    }

    private static func handleMemoryInvoke(
        _ request: BridgeInvokeRequest,
        activeRuntimeRootURLProvider: @escaping @Sendable () -> URL?
    ) async throws -> BridgeInvokeResponse {
        switch request.command {
        case "memory.recall":
            return try await handleMemoryRecallInvoke(request, activeRuntimeRootURLProvider: activeRuntimeRootURLProvider)
        case "memory.upsert":
            return try await handleMemoryUpsertInvoke(request, activeRuntimeRootURLProvider: activeRuntimeRootURLProvider)
        case "memory.forget":
            return try await handleMemoryForgetInvoke(request, activeRuntimeRootURLProvider: activeRuntimeRootURLProvider)
        case "memory.transcript_search":
            return try await handleMemoryTranscriptSearchInvoke(request, activeRuntimeRootURLProvider: activeRuntimeRootURLProvider)
        default:
            return BridgeInvokeResponse(
                id: request.id,
                ok: false,
                error: OpenClawNodeError(code: .invalidRequest, message: "INVALID_REQUEST: unknown memory command")
            )
        }
    }

    private static func handleMemoryRecallInvoke(
        _ request: BridgeInvokeRequest,
        activeRuntimeRootURLProvider _: @escaping @Sendable () -> URL?
    ) async throws -> BridgeInvokeResponse {
        struct Params: Decodable {
            var query: String
            var limit: Int?
        }

        let params = try ToolInvocationHelpers.decodeParams(Params.self, from: request.paramsJSON)
        let store = AgentMemoryStore(runtimeRootURL: AgentStore.sharedRuntimeRootURL())
        let hits = try await store.recall(query: params.query, limit: min(max(params.limit ?? 5, 1), 20))
        let lines = hits.map { hit in
            """
            - [\(hit.type.rawValue)] \(hit.name) (slug=\(hit.slug), version=\(hit.version))
              - description: \(hit.description)
              - file: \(hit.fileURL.path)
              - content: \(hit.content.replacingOccurrences(of: "\n", with: " "))
            """
        }
        let text = lines.isEmpty
            ? "## Memory Recall\n- query: \(params.query)\n- summary: no matching durable memories"
            : "## Memory Recall\n- query: \(params.query)\n- summary: found \(hits.count) durable memory hit(s)\n\(lines.joined(separator: "\n"))"
        return ToolInvocationHelpers.successResponse(id: request.id, payload: text)
    }

    private static func handleMemoryUpsertInvoke(
        _ request: BridgeInvokeRequest,
        activeRuntimeRootURLProvider _: @escaping @Sendable () -> URL?
    ) async throws -> BridgeInvokeResponse {
        struct Params: Decodable {
            var name: String
            var type: String
            var description: String
            var content: String
            var slug: String?
            var expiresAt: String?
            var conflictsWith: [String]?
        }

        let params = try ToolInvocationHelpers.decodeParams(Params.self, from: request.paramsJSON)
        guard let type = AgentMemoryStore.MemoryType(rawValue: params.type.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()) else {
            return BridgeInvokeResponse(
                id: request.id,
                ok: false,
                error: OpenClawNodeError(code: .invalidRequest, message: "INVALID_REQUEST: type must be user, feedback, project, or reference")
            )
        }

        let store = AgentMemoryStore(runtimeRootURL: AgentStore.sharedRuntimeRootURL())
        let entry = try await store.upsert(
            name: params.name,
            type: type,
            description: params.description,
            content: params.content,
            slug: params.slug,
            expiresAt: params.expiresAt,
            conflictsWith: params.conflictsWith ?? []
        )
        let expiresAtLine = entry.expiresAt.map { "\n- expiresAt: \(Self.renderDate($0))" } ?? ""
        let text = "## Memory Upsert\n- status: \(entry.status.rawValue)\n- type: \(entry.type.rawValue)\n- slug: \(entry.slug)\n- version: \(entry.version)\(expiresAtLine)\n- file: \(entry.fileURL.path)"
        return ToolInvocationHelpers.successResponse(id: request.id, payload: text)
    }

    private static func handleMemoryForgetInvoke(
        _ request: BridgeInvokeRequest,
        activeRuntimeRootURLProvider _: @escaping @Sendable () -> URL?
    ) async throws -> BridgeInvokeResponse {
        struct Params: Decodable {
            var slug: String
        }

        let params = try ToolInvocationHelpers.decodeParams(Params.self, from: request.paramsJSON)
        let store = AgentMemoryStore(runtimeRootURL: AgentStore.sharedRuntimeRootURL())
        let removed = try await store.forget(slug: params.slug)
        let text = removed
            ? "## Memory Forget\n- status: removed\n- slug: \(params.slug)"
            : "## Memory Forget\n- status: not_found\n- slug: \(params.slug)"
        return ToolInvocationHelpers.successResponse(id: request.id, payload: text)
    }

    private static func handleMemoryTranscriptSearchInvoke(
        _ request: BridgeInvokeRequest,
        activeRuntimeRootURLProvider: @escaping @Sendable () -> URL?
    ) async throws -> BridgeInvokeResponse {
        struct Params: Decodable {
            var query: String
            var sessionID: String?
            var caseInsensitive: Bool?
            var limit: Int?
        }

        let params = try ToolInvocationHelpers.decodeParams(Params.self, from: request.paramsJSON)
        guard let runtimeRootURL = activeRuntimeRootURLProvider() else {
            return BridgeInvokeResponse(
                id: request.id,
                ok: false,
                error: OpenClawNodeError(code: .unavailable, message: "UNAVAILABLE: no active agent runtime")
            )
        }

        let service = AgentTranscriptSearchService(runtimeRootURL: runtimeRootURL)
        let hits = try service.search(
            query: params.query,
            sessionID: params.sessionID,
            limit: min(max(params.limit ?? 20, 1), 100),
            caseInsensitive: params.caseInsensitive ?? true
        )
        let lines = hits.map { hit in
            "- session=\(hit.sessionID) type=\(hit.entryType) line=\(hit.lineNumber) file=\(hit.fileURL.path)\n  \(hit.snippet)"
        }
        let body = lines.isEmpty ? "- (empty)" : lines.joined(separator: "\n")
        let text = "## Memory Transcript Search\n- query: \(params.query)\n- hits: \(hits.count)\n\(body)"
        return ToolInvocationHelpers.successResponse(id: request.id, payload: text)
    }

    private static func renderDate(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }
}
