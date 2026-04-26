import Foundation

public struct TodoListMetadata: Codable, Sendable, Equatable, Hashable {
    public struct Item: Codable, Sendable, Equatable, Hashable {
        public let content: String
        public let status: String
        public let activeForm: String

        public init(content: String, status: String, activeForm: String) {
            self.content = content
            self.status = status
            self.activeForm = activeForm
        }
    }

    public let items: [Item]
    public let updatedAt: String?

    public init(items: [Item], updatedAt: String? = nil) {
        self.items = items
        self.updatedAt = updatedAt
    }
}

public extension ConversationMessage {
    var todoListMetadata: TodoListMetadata? {
        get {
            guard let raw = metadata["todoListMetadata"],
                  let data = raw.data(using: .utf8)
            else {
                return nil
            }
            return try? JSONDecoder().decode(TodoListMetadata.self, from: data)
        }
        set {
            guard let newValue else {
                metadata.removeValue(forKey: "todoListMetadata")
                return
            }
            guard let data = try? JSONEncoder().encode(newValue),
                  let raw = String(data: data, encoding: .utf8)
            else {
                metadata.removeValue(forKey: "todoListMetadata")
                return
            }
            metadata["todoListMetadata"] = raw
        }
    }

    var isTodoListContainer: Bool {
        get { metadata["sessionTodoListMessage"] == "true" }
        set { metadata["sessionTodoListMessage"] = newValue ? "true" : nil }
    }

    var isTodoList: Bool {
        subtype == "todo_list"
    }
}
