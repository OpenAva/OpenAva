//
//  Publisher+EnsureMainThread.swift
//  ChatUI
//

import Combine
import Foundation

extension Publisher {
    func ensureMainThread() -> AnyPublisher<Output, Failure> {
        self.flatMap(maxPublishers: .max(1)) { output -> AnyPublisher<Output, Failure> in
            if Thread.isMainThread {
                return Just(output).setFailureType(to: Failure.self).eraseToAnyPublisher()
            } else {
                return Just(output).setFailureType(to: Failure.self).receive(on: DispatchQueue.main).eraseToAnyPublisher()
            }
        }.eraseToAnyPublisher()
    }
}
