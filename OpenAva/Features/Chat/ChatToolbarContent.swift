//
//  ChatToolbarContent.swift
//  OpenAva
//

import ChatUI
import OpenClawKit
import SwiftUI
import UserNotifications

struct TopoBotNavigationBar: View {
    let agentName: String
    let agentEmoji: String
    let modelName: String
    let agents: [AgentProfile]
    let activeAgentID: UUID?
    let autoCompactEnabled: Bool
    let onTapModel: () -> Void
    let onMenuAction: ((ChatViewControllerWrapper.MenuAction) -> Void)?
    let onAgentSwitch: ((UUID) -> Void)?
    let onCreateLocalAgent: (() -> Void)?
    let onDeleteCurrentAgent: (() -> Void)?
    let onToggleAutoCompact: (() -> Void)?

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                leadingMenu

                VStack(spacing: 0) {
                    titleMenu
                    modelButton
                }
                .frame(maxWidth: .infinity)

                trailingMenu
            }
            .frame(minHeight: 44)
            .padding(.horizontal, 12)
            .padding(.bottom, 8)

            Rectangle()
                .fill(Color.primary.opacity(0.08))
                .frame(height: 0.5)
        }
        .background(Color(uiColor: ChatUIDesign.Color.warmCream))
    }

    // MARK: - Leading (Agent Picker)

    private var leadingMenu: some View {
        Menu {
            agentMenuContent
        } label: {
            Image(uiImage: UIImage.chatInputIcon(named: "users") ?? UIImage(systemName: "person.2")!)
                .renderingMode(.template)
                .foregroundStyle(.primary.opacity(0.9))
                .frame(width: 32, height: 32)
        }
        .buttonStyle(.plain)
    }

    private var titleMenu: some View {
        Menu {
            agentMenuContent
        } label: {
            HStack(spacing: 4) {
                Text(resolvedAgentTitle)
                    .font(.system(size: 15, weight: .regular))
                    .foregroundStyle(Color(uiColor: ChatUIDesign.Color.offBlack))
                    .lineLimit(1)

                Image(systemName: "chevron.down")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(Color(uiColor: ChatUIDesign.Color.black60))
            }
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private var agentMenuContent: some View {
        agentPickerContent

        Section {
            Button(action: { onCreateLocalAgent?() }) {
                Label(L10n.tr("chat.menu.newLocalAgent"), systemImage: "plus.circle")
            }
        }
    }

    private var modelButton: some View {
        Button(action: onTapModel) {
            Text(resolvedModelTitle)
                .font(.system(size: 11, weight: .regular))
                .foregroundStyle(Color(uiColor: ChatUIDesign.Color.black60))
                .lineLimit(1)
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private var agentPickerContent: some View {
        ForEach(agents, id: \.id) { agent in
            agentButton(for: agent)
        }

        if agents.isEmpty {
            Text(L10n.tr("chat.menu.noAgentsAvailable"))
        }
    }

    @ViewBuilder
    private func agentButton(for agent: AgentProfile) -> some View {
        let isActive = agent.id == activeAgentID
        Toggle(isOn: Binding(
            get: { isActive },
            set: { newValue in if newValue { onAgentSwitch?(agent.id) } }
        )) {
            let title = agentMenuTitle(for: agent)
            if let image = makeEmojiImage(from: agent.emoji) {
                Label {
                    Text(title)
                } icon: {
                    image
                }
            } else {
                Text(title)
            }
        }
    }

    // MARK: - Trailing (Settings Menu)

    private var trailingMenu: some View {
        Menu {
            Section {
                Button(action: { onMenuAction?(.openLLM) }) {
                    Label(L10n.tr("settings.llm.navigationTitle"), systemImage: "cpu")
                }
                Button(action: { onMenuAction?(.openSkills) }) {
                    Label(L10n.tr("settings.skills.navigationTitle"), systemImage: "square.stack.3d.up")
                }
                Button(action: { onMenuAction?(.openContext) }) {
                    Label(L10n.tr("settings.context.navigationTitle"), systemImage: "doc.text")
                }
                Button(action: { onMenuAction?(.openCron) }) {
                    Label(L10n.tr("settings.cron.navigationTitle"), systemImage: "calendar.badge.clock")
                }
            }
            Section {
                Toggle(isOn: Binding(
                    get: { BackgroundExecutionPreferences.shared.isEnabled },
                    set: { newValue in
                        BackgroundExecutionPreferences.shared.isEnabled = newValue
                        if newValue {
                            UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
                        }
                    }
                )) {
                    Label(L10n.tr("settings.background.enabled"), systemImage: "arrow.down.app")
                }
                Toggle(isOn: Binding(
                    get: { autoCompactEnabled },
                    set: { _ in onToggleAutoCompact?() }
                )) {
                    Label(L10n.tr("chat.menu.autoCompact"), systemImage: "rectangle.compress.vertical")
                }
                Button(action: { onMenuAction?(.openRemoteControl) }) {
                    Label(L10n.tr("settings.remoteControl.navigationTitle"), systemImage: "dot.radiowaves.left.and.right")
                }
                renameButton
                deleteButton
            }
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.primary.opacity(0.6))
                .frame(width: 32, height: 32)
        }
        .buttonStyle(.plain)
    }

    private var renameButton: some View {
        Button(action: { onTapRename() }) {
            Label(L10n.tr("chat.menu.renameAgent"), systemImage: "pencil")
        }
    }

    private var deleteButton: some View {
        Button(role: .destructive, action: { onDeleteCurrentAgent?() }) {
            Label(L10n.tr("chat.menu.deleteAgent"), systemImage: "trash")
        }
    }

    private func onTapRename() {
        // Rename requires a text field alert which SwiftUI Menu cannot show directly.
        // This is handled by the coordinator via UIKit alert.
        // We route through a notification that the coordinator observes.
        NotificationCenter.default.post(name: .chatToolbarRenameRequested, object: nil)
    }

    // MARK: - Helpers

    private var resolvedAgentTitle: String {
        let trimmedEmoji = agentEmoji.trimmingCharacters(in: .whitespacesAndNewlines)
        let name = agentName.trimmingCharacters(in: .whitespacesAndNewlines)
        let resolvedName = name.isEmpty ? "Assistant" : name
        if trimmedEmoji.isEmpty {
            return resolvedName
        }
        return "\(trimmedEmoji) \(resolvedName)"
    }

    private var resolvedModelTitle: String {
        let model = modelName.trimmingCharacters(in: .whitespacesAndNewlines)
        return model.isEmpty ? "Not Selected" : model
    }

    private func agentMenuTitle(for agent: AgentProfile) -> String {
        agent.name
    }

    private func makeEmojiImage(from emoji: String) -> Image? {
        let trimmed = emoji.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return nil }

        let size = CGSize(width: 20, height: 20)
        let renderer = UIGraphicsImageRenderer(size: size)
        let uiImage = renderer.image { _ in
            let text = trimmed as NSString
            let font = UIFont.systemFont(ofSize: 16)
            let attributes: [NSAttributedString.Key: Any] = [
                .font: font,
                .paragraphStyle: {
                    let p = NSMutableParagraphStyle()
                    p.alignment = .center
                    return p
                }(),
            ]
            let textSize = text.size(withAttributes: attributes)
            let rect = CGRect(
                x: (size.width - textSize.width) / 2,
                y: (size.height - textSize.height) / 2,
                width: textSize.width,
                height: textSize.height
            )
            text.draw(in: rect, withAttributes: attributes)
        }
        return Image(uiImage: uiImage.withRenderingMode(.alwaysOriginal))
    }
}

extension Notification.Name {
    static let chatToolbarRenameRequested = Notification.Name("chatToolbarRenameRequested")
}
