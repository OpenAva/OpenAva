//
//  Publisher+EnsureMainThread.swift
//  ChatUI
//

import Combine
import Foundation

extension Publisher {
    func ensureMainThread() -> AnyPublisher<Output, Failure> {
        receive(on: DispatchQueue.main).eraseToAnyPublisher()
    }
}
