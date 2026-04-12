//
//  DemoAlertTool.swift
//  Example
//
//  Created by qaq on 9/3/2026.
//

import ChatClient
import ChatUI
import UIKit

enum DemoAlertTool {
    static let name = "show_alert"

    struct Arguments: Decodable {
        let title: String
        let message: String
        let buttonTitle: String?
    }

    final class Executor: ToolExecutor {
        let displayName = String(localized: "Show Alert")

        @MainActor
        func execute(parameters: String) throws -> ToolResult {
            let data = Data(parameters.utf8)
            let arguments = try JSONDecoder().decode(Arguments.self, from: data)

            let alert = UIAlertController(
                title: arguments.title,
                message: arguments.message,
                preferredStyle: .alert
            )
            alert.addAction(
                UIAlertAction(
                    title: arguments.buttonTitle?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
                        ? arguments.buttonTitle
                        : String(localized: "OK"),
                    style: .default
                )
            )

            guard let viewController = UIApplication.shared.topPresentedViewController else {
                throw NSError(domain: "DemoAlertTool", code: 1, userInfo: [
                    NSLocalizedDescriptionKey: String(localized: "Unable to find a view controller to present the alert."),
                ])
            }
            viewController.present(alert, animated: true)
            return .init(text: String(localized: "Alert displayed successfully."))
        }
    }

    @MainActor
    final class Provider: ToolProvider {
        let executor = Executor()

        func enabledTools() async -> [ChatRequestBody.Tool] {
            [
                .function(
                    name: DemoAlertTool.name,
                    description: "Display a native iOS alert to the user when they explicitly ask you to show a popup or alert.",
                    parameters: [
                        "type": "object",
                        "properties": [
                            "title": [
                                "type": "string",
                                "description": "Short alert title.",
                            ],
                            "message": [
                                "type": "string",
                                "description": "Main alert message shown to the user.",
                            ],
                            "buttonTitle": [
                                "type": "string",
                                "description": "Optional confirmation button title.",
                            ],
                        ],
                        "required": ["title", "message"],
                        "additionalProperties": false,
                    ],
                    strict: true
                ),
            ]
        }

        func findTool(for request: ToolRequest) async -> ToolExecutor? {
            request.name == DemoAlertTool.name ? executor : nil
        }

        func executeTool(
            _ tool: ToolExecutor,
            parameters: String
        ) async throws -> ToolResult {
            guard let tool = tool as? Executor else {
                return .init(error: String(localized: "Unsupported tool executor."))
            }
            return try await MainActor.run {
                try tool.execute(parameters: parameters)
            }
        }
    }
}

extension UIApplication {
    @MainActor
    var topPresentedViewController: UIViewController? {
        connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows)
            .first(where: { $0.isKeyWindow })?
            .topPresentedViewController
    }
}

extension UIViewController {
    @MainActor
    var topPresentedViewController: UIViewController {
        var current = self
        while let presented = current.presentedViewController {
            current = presented
        }
        return current
    }
}
