//
//  OpenAvaApp.swift
//  OpenAva
//
//  Created by yuanyan on 4/3/26.
//

import SwiftUI
import UIKit
import UserNotifications

enum CatalystGlobalCommand: String {
    case newConversation
    case openModelSettings
    case focusInput
}

extension Notification.Name {
    static let openAvaCatalystGlobalCommand = Notification.Name("openAva.catalyst.globalCommand")
}

enum CatalystGlobalCommandCenter {
    static func post(_ command: CatalystGlobalCommand) {
        NotificationCenter.default.post(
            name: .openAvaCatalystGlobalCommand,
            object: nil,
            userInfo: ["command": command.rawValue]
        )
    }

    static func resolve(_ notification: Notification) -> CatalystGlobalCommand? {
        guard let rawValue = notification.userInfo?["command"] as? String,
              let command = CatalystGlobalCommand(rawValue: rawValue)
        else {
            return nil
        }
        return command
    }
}

@main
struct OpenAvaApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @State private var containerStore = AppContainerStore(container: .makeDefault())
    @State private var windowCoordinator = AppWindowCoordinator()

    var body: some Scene {
        WindowGroup {
            AppRootView()
                .environment(\.appContainerStore, containerStore)
                .environment(\.appWindowCoordinator, windowCoordinator)
                .onOpenURL { url in
                    let container = containerStore.container
                    Task {
                        await SkillInvocationService.handleDeepLink(url: url, container: container)
                    }
                }
        }

        #if targetEnvironment(macCatalyst)
            WindowGroup(L10n.tr("window.settings.title"), id: AppWindowID.settings) {
                SettingsWindowRootView()
                    .environment(\.appContainerStore, containerStore)
                    .environment(\.appWindowCoordinator, windowCoordinator)
            }
            .handlesExternalEvents(matching: [AppWindowID.settings])

            WindowGroup(L10n.tr("window.agentCreation.title"), id: AppWindowID.agentCreation) {
                AgentCreationWindowRootView()
                    .id(windowCoordinator.agentCreationRequestID)
                    .environment(\.appContainerStore, containerStore)
                    .environment(\.appWindowCoordinator, windowCoordinator)
            }
            .handlesExternalEvents(matching: [AppWindowID.agentCreation])
        #endif
    }
}

// MARK: - AppDelegate for DebugSwift integration

import DebugSwift

final class AppDelegate: UIResponder, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    let debugSwift = DebugSwift()
    private let backgroundCoordinator = BackgroundExecutionCoordinator.shared

    func application(
        _: UIApplication,
        didFinishLaunchingWithOptions _: [UIApplication.LaunchOptionsKey: Any]?
    ) -> Bool {
        #if DEBUG
            debugSwift.setup()
            // debugSwift.setup(disable: [.leaksDetector])
            debugSwift.show()
        #endif

        backgroundCoordinator.registerBackgroundTask()
        // Ensure local notifications can be presented while app is foreground.
        UNUserNotificationCenter.current().delegate = self

        #if targetEnvironment(macCatalyst)
            CatalystWindowCoordinator.shared.install()
            RemoteControlService.shared.startIfNeeded()
        #endif

        return true
    }

    func applicationDidEnterBackground(_: UIApplication) {
        backgroundCoordinator.scheduleRefreshTaskIfNeeded()
    }

    func applicationDidBecomeActive(_: UIApplication) {
        // Do not auto-resume interrupted chats on foreground entry.
        // Users should explicitly tap ChatUI retry to continue.
    }

    func userNotificationCenter(
        _: UNUserNotificationCenter,
        willPresent _: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .list, .sound])
    }
}

#if targetEnvironment(macCatalyst)
    private final class CatalystWindowCoordinator {
        static let shared = CatalystWindowCoordinator()

        private var sceneObservers: [NSObjectProtocol] = []

        private init() {}

        func install() {
            guard sceneObservers.isEmpty else { return }
            apply(to: UIApplication.shared.connectedScenes)
            let center = NotificationCenter.default
            sceneObservers.append(
                center.addObserver(forName: UIScene.willConnectNotification,
                                   object: nil, queue: .main)
                { [weak self] n in
                    self?.apply(from: n.object)
                }
            )
            sceneObservers.append(
                center.addObserver(forName: UIScene.didActivateNotification,
                                   object: nil, queue: .main)
                { [weak self] n in
                    self?.apply(from: n.object)
                }
            )
        }

        private func apply(to scenes: Set<UIScene>) {
            scenes.forEach { apply(from: $0) }
        }

        private func apply(from object: Any?) {
            guard let scene = object as? UIWindowScene else { return }

            if let titlebar = scene.titlebar {
                titlebar.titleVisibility = .hidden
            }
            scene.sizeRestrictions?.minimumSize = CGSize(width: 600, height: 440)
            scene.sizeRestrictions?.maximumSize = CGSize(width: 4096, height: 4096)
        }
    }

    extension AppDelegate {
        override func buildMenu(with builder: UIMenuBuilder) {
            super.buildMenu(with: builder)
            guard builder.system == .main else { return }

            builder.remove(menu: .newScene)

            builder.insertChild(
                UIMenu(
                    title: "",
                    options: .displayInline,
                    children: [
                        UIKeyCommand(
                            title: L10n.tr("chat.command.newConversation"),
                            action: #selector(handleNewConversationFromMenu(_:)),
                            input: "n",
                            modifierFlags: .command
                        ),
                    ]
                ),
                atStartOfMenu: .file
            )

            builder.insertSibling(
                UIMenu(
                    title: "",
                    options: .displayInline,
                    children: [
                        UIKeyCommand(
                            title: L10n.tr("settings.llm.navigationTitle"),
                            action: #selector(handleOpenModelSettingsFromMenu(_:)),
                            input: ",",
                            modifierFlags: .command
                        ),
                    ]
                ),
                afterMenu: .preferences
            )

            builder.insertChild(
                UIMenu(
                    title: "",
                    options: .displayInline,
                    children: [
                        UIKeyCommand(
                            title: L10n.tr("chat.command.focusInput"),
                            action: #selector(handleFocusInputFromMenu(_:)),
                            input: "l",
                            modifierFlags: .command
                        ),
                    ]
                ),
                atStartOfMenu: .view
            )
        }

        @objc private func handleNewConversationFromMenu(_: Any?) {
            CatalystGlobalCommandCenter.post(.newConversation)
        }

        @objc private func handleOpenModelSettingsFromMenu(_: Any?) {
            CatalystGlobalCommandCenter.post(.openModelSettings)
        }

        @objc private func handleFocusInputFromMenu(_: Any?) {
            CatalystGlobalCommandCenter.post(.focusInput)
        }
    }
#endif

// MARK: - Shake to Toggle DebugSwift

#if DEBUG && !targetEnvironment(macCatalyst)
    extension UIWindow {
        override open func motionEnded(_ motion: UIEvent.EventSubtype, with event: UIEvent?) {
            super.motionEnded(motion, with: event)

            if motion == .motionShake {
                if let appDelegate = UIApplication.shared.delegate as? AppDelegate {
                    appDelegate.debugSwift.toggle()
                }
            }
        }
    }
#endif

private struct AppRootView: View {
    var body: some View {
        ChatRootView()
    }
}
