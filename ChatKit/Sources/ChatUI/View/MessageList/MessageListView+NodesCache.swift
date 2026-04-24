//
//  MessageListView+NodesCache.swift
//  ChatUI
//
//  Thread-safe cache for preprocessed markdown content.
//

import Foundation
import MarkdownParser
import MarkdownView

extension MessageListView {
    final class MarkdownPackageCache {
        private var cachedPackages: [String: MarkdownTextView.PreprocessedContent] = [:]
        private var cachedHashes: [String: Int] = [:]
        private let lock = NSLock()
        private let parser = MarkdownParser()

        func package(
            for content: String,
            id: String,
            theme: MarkdownTheme
        ) -> MarkdownTextView.PreprocessedContent {
            let contentHash = content.hashValue

            lock.lock()
            if let cached = cachedPackages[id], cachedHashes[id] == contentHash {
                lock.unlock()
                return cached
            }
            lock.unlock()

            let processedContent = updateCache(content: content, theme: theme)

            lock.lock()
            cachedPackages[id] = processedContent
            cachedHashes[id] = contentHash
            lock.unlock()

            return processedContent
        }

        func package(
            for messageRepresentation: MessageRepresentation,
            theme: MarkdownTheme
        ) -> MarkdownTextView.PreprocessedContent {
            return package(for: messageRepresentation.content, id: messageRepresentation.id, theme: theme)
        }

        private func updateCache(content: String, theme: MarkdownTheme) -> MarkdownTextView.PreprocessedContent {
            let parseResult = parser.parse(content)
            if Thread.isMainThread {
                return MainActor.assumeIsolated {
                    MarkdownTextView.PreprocessedContent(parserResult: parseResult, theme: theme)
                }
            }
            return DispatchQueue.main.sync {
                MarkdownTextView.PreprocessedContent(parserResult: parseResult, theme: theme)
            }
        }
    }
}
