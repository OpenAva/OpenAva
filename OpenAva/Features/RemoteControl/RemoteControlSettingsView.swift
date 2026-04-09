import ChatUI
import SwiftUI

struct RemoteControlSettingsView: View {
    #if targetEnvironment(macCatalyst)
        @State private var statusStore = RemoteControlStatusStore.shared
    #endif

    let onDone: (() -> Void)?

    init(onDone: (() -> Void)? = nil) {
        self.onDone = onDone
    }

    var body: some View {
        #if targetEnvironment(macCatalyst)
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    if let onDone {
                        ZStack {
                            Text(L10n.tr("settings.remoteControl.navigationTitle"))
                                .font(.headline)
                                .foregroundStyle(.primary)

                            HStack {
                                Spacer(minLength: 0)
                                actionButton(title: L10n.tr("common.done"), action: onDone)
                            }
                        }
                    }

                    hostCard
                }
                .padding(24)
                .frame(maxWidth: 640)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(uiColor: ChatUIDesign.Color.warmCream))
        #else
            RemoteControlClientView()
        #endif
    }

    #if targetEnvironment(macCatalyst)
        private var hostCard: some View {
            VStack(alignment: .leading, spacing: 16) {
                HStack(spacing: 8) {
                    ZStack {
                        Circle()
                            .fill(Color.blue.opacity(0.16))
                            .frame(width: 18, height: 18)

                        Circle()
                            .fill(Color.blue)
                            .frame(width: 8, height: 8)
                    }

                    Text(L10n.tr("settings.remoteControl.host.title"))
                        .font(.system(size: 16, weight: .medium))
                        .foregroundStyle(Color(uiColor: ChatUIDesign.Color.offBlack))
                }

                VStack(alignment: .leading, spacing: 12) {
                    if let advertiseStatusText = statusStore.advertiseStatusText {
                        Text(advertiseStatusText)
                            .font(.system(size: 14, weight: .regular))
                            .foregroundStyle(Color(uiColor: ChatUIDesign.Color.black60))
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    if let advertiseRegistrationText = statusStore.advertiseRegistrationText {
                        Text(advertiseRegistrationText)
                            .font(.system(size: 14, weight: .regular))
                            .foregroundStyle(Color(uiColor: ChatUIDesign.Color.black60))
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    if let port = statusStore.advertisedPort {
                        Text("\(L10n.tr("settings.remoteControl.status.hostPort")): \(port)")
                            .font(.system(size: 14, weight: .regular))
                            .foregroundStyle(Color(uiColor: ChatUIDesign.Color.black60))
                    }

                    if let pairCode = statusStore.currentPairCode {
                        HStack(spacing: 8) {
                            Text(L10n.tr("settings.remoteControl.status.hostCode"))
                                .font(.system(size: 14, weight: .regular))
                                .foregroundStyle(Color(uiColor: ChatUIDesign.Color.black60))
                            Text(pairCode)
                                .font(.system(size: 14, design: .monospaced).weight(.medium))
                                .foregroundStyle(Color(uiColor: ChatUIDesign.Color.offBlack))
                        }
                    } else {
                        statusPill(
                            title: L10n.tr("settings.remoteControl.host.waiting"),
                            tint: Color(uiColor: ChatUIDesign.Color.brandOrange)
                        )
                    }

                    if let peerName = statusStore.currentPairPeerName {
                        Text("\(L10n.tr("settings.remoteControl.status.hostPeer")): \(peerName)")
                            .font(.system(size: 14, weight: .medium))
                            .foregroundStyle(Color(uiColor: ChatUIDesign.Color.offBlack))
                    }
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: ChatUIDesign.Radius.card, style: .continuous)
                    .fill(Color(uiColor: ChatUIDesign.Color.warmCream))
            )
            .overlay(
                RoundedRectangle(cornerRadius: ChatUIDesign.Radius.card, style: .continuous)
                    .strokeBorder(Color(uiColor: ChatUIDesign.Color.oatBorder), lineWidth: 1)
            )
        }

        private func actionButton(
            title: String,
            action: @escaping () -> Void
        ) -> some View {
            Button(action: action) {
                Text(title)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(Color(uiColor: ChatUIDesign.Color.offBlack))
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(Color.clear)
                    .clipShape(RoundedRectangle(cornerRadius: ChatUIDesign.Radius.button, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: ChatUIDesign.Radius.button, style: .continuous)
                            .strokeBorder(Color(uiColor: ChatUIDesign.Color.oatBorder), lineWidth: 1)
                    )
            }
            .buttonStyle(.plain)
        }

        private func statusPill(
            title: String,
            tint: Color
        ) -> some View {
            HStack(spacing: 6) {
                Circle()
                    .fill(tint)
                    .frame(width: 6, height: 6)

                Text(title)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Color(uiColor: ChatUIDesign.Color.black80))
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(
                Capsule()
                    .fill(tint.opacity(0.12))
            )
        }
    #endif
}
