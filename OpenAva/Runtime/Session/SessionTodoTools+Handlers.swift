import ChatUI
import Foundation
import OpenClawKit

extension SessionTodoTools {
    func registerHandlers(into handlers: inout [String: ToolHandler], context _: ToolHandlerRegistrationContext) {
        handlers["todo.write"] = { request in
            do {
                return try await Self.handleTodoWrite(request)
            } catch {
                return ToolInvocationHelpers.errorResponse(
                    id: request.id,
                    code: .invalidRequest,
                    message: "TODO_WRITE_FAILED: \(error.localizedDescription)"
                )
            }
        }
    }

    private struct TodoWriteParams: Decodable {
        struct Item: Decodable {
            let content: String
            let status: String
            let activeForm: String
        }

        let todos: [Item]
    }

    private static func handleTodoWrite(_ request: BridgeInvokeRequest) async throws -> BridgeInvokeResponse {
        let params: TodoWriteParams
        do {
            params = try ToolInvocationHelpers.decodeParams(TodoWriteParams.self, from: request.paramsJSON)
        } catch {
            return ToolInvocationHelpers.invalidRequest(id: request.id, error.localizedDescription)
        }

        let normalizedItems: [TodoListMetadata.Item]
        do {
            normalizedItems = try normalize(params.todos)
        } catch let error as TodoValidationError {
            return ToolInvocationHelpers.invalidRequest(id: request.id, error.message)
        }

        guard let session = await MainActor.run(body: { cachedSession(for: ToolRuntime.InvocationContext.sessionID) }) else {
            return ToolInvocationHelpers.unavailableResponse(
                id: request.id,
                "TODO_WRITE_UNAVAILABLE: no active conversation session found"
            )
        }

        let activeItems = normalizedItems.allSatisfy { $0.status == "completed" } ? [] : normalizedItems

        await MainActor.run {
            upsertTodoMessage(in: session, items: activeItems)
        }

        return ToolInvocationHelpers.successResponse(id: request.id, payload: successMessage)
    }

    private static func normalize(_ items: [TodoWriteParams.Item]) throws -> [TodoListMetadata.Item] {
        let normalized = try items.map { item -> TodoListMetadata.Item in
            let content = item.content.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !content.isEmpty else {
                throw TodoValidationError("todo content cannot be empty")
            }

            let activeForm = item.activeForm.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !activeForm.isEmpty else {
                throw TodoValidationError("todo activeForm cannot be empty")
            }

            let status = item.status.trimmingCharacters(in: .whitespacesAndNewlines)
            guard ["pending", "in_progress", "completed"].contains(status) else {
                throw TodoValidationError("todo status must be one of pending, in_progress, completed")
            }

            return .init(content: content, status: status, activeForm: activeForm)
        }

        let inProgressCount = normalized.filter { $0.status == "in_progress" }.count
        guard inProgressCount <= 1 else {
            throw TodoValidationError("at most one todo may be in_progress")
        }
        if !normalized.isEmpty, !normalized.allSatisfy({ $0.status == "completed" }), inProgressCount != 1 {
            throw TodoValidationError("an active todo list must contain exactly one in_progress task")
        }
        return normalized
    }

    @MainActor
    private static func upsertTodoMessage(in session: ConversationSession, items: [TodoListMetadata.Item]) {
        let metadata = items.isEmpty ? nil : TodoListMetadata(items: items, updatedAt: timestampFormatter.string(from: Date()))
        let message: ConversationMessage
        if let existingIndex = session.messages.firstIndex(where: \.isTodoListContainer) {
            message = session.messages.remove(at: existingIndex)
            session.messages.append(message)
        } else {
            message = session.appendNewMessage(role: .system) { msg in
                msg.isTodoListContainer = true
                msg.textContent = ""
            }
        }

        message.createdAt = Date()
        message.isTodoListContainer = true
        message.textContent = ""
        message.subtype = items.isEmpty ? nil : "todo_list"
        message.todoListMetadata = metadata

        session.recordMessageInTranscript(message)
        session.notifyMessagesDidChange(scrolling: false)
    }

    @MainActor
    private static func cachedSession(for invocationSessionID: String?) -> ConversationSession? {
        guard let sessionID = resolvedMainSessionID(from: invocationSessionID) else { return nil }
        return ConversationSessionManager.shared.cachedSession(for: sessionID)
    }

    private static func resolvedMainSessionID(from invocationSessionID: String?) -> String? {
        guard let invocationSessionID else { return nil }
        let trimmed = invocationSessionID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        guard let separator = trimmed.range(of: "::") else { return trimmed }
        let suffix = trimmed[separator.upperBound...].trimmingCharacters(in: .whitespacesAndNewlines)
        return suffix.isEmpty ? trimmed : suffix
    }

    private static let successMessage = "Todos have been modified successfully. Ensure that you continue to use the todo list to track your progress. Please proceed with the current tasks if applicable"

    private static let timestampFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()
}

private struct TodoValidationError: LocalizedError {
    let message: String

    init(_ message: String) {
        self.message = message
    }

    var errorDescription: String? {
        message
    }
}
