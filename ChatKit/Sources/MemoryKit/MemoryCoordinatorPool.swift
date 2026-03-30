//
//  MemoryCoordinatorPool.swift
//  MemoryKit
//
//  Reuses memory coordinators per conversation.
//

import ChatClient
import Foundation

public actor MemoryCoordinatorPool {
    private let workspaceRoot: URL
    private let chatClient: (any ChatClient)?
    private let memoryWindow: Int
    private var coordinators: [String: MemoryCoordinator] = [:]

    public init(
        workspaceRoot: URL,
        chatClient: (any ChatClient)?,
        memoryWindow: Int = 100
    ) {
        self.workspaceRoot = workspaceRoot
        self.chatClient = chatClient
        self.memoryWindow = max(2, memoryWindow)
    }

    public func coordinator(for conversationID: String) -> MemoryCoordinator? {
        if let existing = coordinators[conversationID] {
            return existing
        }
        guard let chatClient else {
            return nil
        }
        guard let store = try? MemoryStore(workspaceDirectory: workspaceRoot) else {
            return nil
        }
        let consolidator: any MemoryConsolidator = LLMSaveMemoryConsolidator(chatClient: chatClient)
        let coordinator = MemoryCoordinator(
            store: store,
            consolidator: consolidator,
            memoryWindow: memoryWindow
        )
        coordinators[conversationID] = coordinator
        return coordinator
    }
}
