//
//  OpenAvaApp.swift
//  OpenAva
//
//  Created by yuanyan on 4/3/26.
//

import ChatUI
import SwiftUI
import UIKit
import UserNotifications

enum CatalystGlobalCommand: String {
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
                        await SkillLaunchService.handleDeepLink(url: url, container: container)
                    }
                }
        }

        #if targetEnvironment(macCatalyst)
            WindowGroup(L10n.tr("window.settings.title"), id: AppWindowID.settings, for: String.self) { $sectionID in
                SettingsWindowRootView(sectionID: $sectionID)
                    .environment(\.appContainerStore, containerStore)
                    .environment(\.appWindowCoordinator, windowCoordinator)
            }
            defaultValue: {
                SettingsWindowSection.llm.rawValue
            }
            .handlesExternalEvents(matching: [AppWindowID.settings])

            WindowGroup(L10n.tr("window.agentCreation.title"), id: AppWindowID.agentCreation) {
                AgentCreationWindowRootView()
                    .id(windowCoordinator.agentCreationRequestID)
                    .environment(\.appContainerStore, containerStore)
                    .environment(\.appWindowCoordinator, windowCoordinator)
                    .onAppear {
                        if let windowScene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first(where: { $0.title == L10n.tr("window.agentCreation.title") }) {
                            let activity = NSUserActivity(activityType: "openava.window.\(AppWindowID.agentCreation)")
                            activity.targetContentIdentifier = AppWindowID.agentCreation
                            windowScene.session.stateRestorationActivity = activity
                        }
                    }
            }
            .handlesExternalEvents(matching: [AppWindowID.agentCreation])
        #endif
    }
}

// MARK: - AppDelegate for DebugSwift integration

#if DEBUG && !targetEnvironment(macCatalyst)
    import DebugSwift
#endif

final class AppDelegate: UIResponder, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    #if DEBUG && !targetEnvironment(macCatalyst)
        let debugSwift = DebugSwift()
    #endif
    private let backgroundCoordinator = BackgroundExecutionCoordinator.shared

    func application(
        _: UIApplication,
        didFinishLaunchingWithOptions _: [UIApplication.LaunchOptionsKey: Any]?
    ) -> Bool {
        #if DEBUG && !targetEnvironment(macCatalyst)
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
            configureCatalystBarButtonAppearance()
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
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        Task {
            let handledByCronRouter = await CronNotificationRouter.handle(notification)
            completionHandler(handledByCronRouter ? [] : [.banner, .list, .sound])
        }
    }

    func userNotificationCenter(
        _: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        Task {
            _ = await CronNotificationRouter.handle(response.notification)
            completionHandler()
        }
    }
}

#if targetEnvironment(macCatalyst)
    /// Remove the rounded-rect background that Mac Catalyst forces on toolbar buttons.
    private func configureCatalystBarButtonAppearance() {
        let plain = UIBarButtonItemAppearance(style: .plain)
        plain.normal.backgroundImage = UIImage()
        plain.highlighted.backgroundImage = UIImage()
        plain.focused.backgroundImage = UIImage()

        let navBarAppearance = UINavigationBarAppearance()
        navBarAppearance.configureWithDefaultBackground()
        navBarAppearance.buttonAppearance = plain
        navBarAppearance.doneButtonAppearance = plain

        UINavigationBar.appearance().standardAppearance = navBarAppearance
        UINavigationBar.appearance().compactAppearance = navBarAppearance
        UINavigationBar.appearance().scrollEdgeAppearance = navBarAppearance
    }

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
                titlebar.toolbarStyle = .automatic
                titlebar.separatorStyle = .none
            }
            scene.sizeRestrictions?.minimumSize = CGSize(width: 600, height: 440)
            scene.sizeRestrictions?.maximumSize = CGSize(width: 4096, height: 4096)

            for window in scene.windows {
                window.backgroundColor = ChatUIDesign.Color.warmCream
            }
        }
    }

    extension AppDelegate {
        override func buildMenu(with builder: UIMenuBuilder) {
            super.buildMenu(with: builder)
            guard builder.system == .main else { return }

            builder.remove(menu: .newScene)

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
        ZStack {
            Color(uiColor: ChatUIDesign.Color.warmCream)
                .ignoresSafeArea()
            ChatRootView()
        }
    }
}
