import SwiftUI

struct RemoteControlSettingsView: View {
    #if targetEnvironment(macCatalyst)
        @State private var statusStore = RemoteControlStatusStore.shared
    #endif

    var body: some View {
        #if targetEnvironment(macCatalyst)
            Form {
                cardSection {
                    settingsCard(
                        title: L10n.tr("settings.remoteControl.host.title"),
                        tint: .blue
                    ) {
                        if let advertiseStatusText = statusStore.advertiseStatusText {
                            Text(advertiseStatusText)
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }

                        if let advertiseRegistrationText = statusStore.advertiseRegistrationText {
                            Text(advertiseRegistrationText)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }

                        if let port = statusStore.advertisedPort {
                            infoRow(
                                title: L10n.tr("settings.remoteControl.status.hostPort"),
                                value: String(port)
                            )
                        }

                        if let pairCode = statusStore.currentPairCode {
                            infoRow(
                                title: L10n.tr("settings.remoteControl.status.hostCode"),
                                value: pairCode,
                                emphasis: true
                            )
                        } else {
                            statusPill(
                                title: L10n.tr("settings.remoteControl.host.waiting"),
                                tint: .orange
                            )
                        }

                        if let peerName = statusStore.currentPairPeerName {
                            infoRow(
                                title: L10n.tr("settings.remoteControl.status.hostPeer"),
                                value: peerName
                            )
                        }
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .background(Color(uiColor: .systemGroupedBackground))
            .navigationTitle(L10n.tr("settings.remoteControl.navigationTitle"))
            .navigationBarTitleDisplayMode(.inline)
        #else
            RemoteControlClientView()
        #endif
    }

    #if targetEnvironment(macCatalyst)
        private func cardSection<Content: View>(
            @ViewBuilder content: () -> Content
        ) -> some View {
            Section {
                content()
            }
            .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
            .listRowSeparator(.hidden)
            .listRowBackground(Color.clear)
        }

        private func settingsCard<Content: View>(
            title: String,
            tint: Color,
            @ViewBuilder content: () -> Content
        ) -> some View {
            VStack(alignment: .leading, spacing: 16) {
                HStack(spacing: 10) {
                    ZStack {
                        Circle()
                            .fill(tint.opacity(0.16))
                            .frame(width: 22, height: 22)

                        Circle()
                            .fill(tint)
                            .frame(width: 8, height: 8)
                    }

                    Text(title)
                        .font(.headline)
                        .fontWeight(.semibold)
                        .foregroundStyle(.primary)
                        .tracking(0.3)
                }

                content()
            }
            .padding(16)
            .background(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(Color(uiColor: .systemBackground))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.07), lineWidth: 0.8)
            )
            .shadow(color: .black.opacity(0.035), radius: 10, y: 4)
        }

        private func infoRow(
            title: String,
            value: String,
            emphasis: Bool = false
        ) -> some View {
            HStack(alignment: .center, spacing: 12) {
                Text(title)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.primary)

                Spacer(minLength: 12)

                Text(value)
                    .font(emphasis ? .system(.body, design: .monospaced).weight(.semibold) : .subheadline)
                    .foregroundStyle(emphasis ? .primary : .secondary)
                    .lineLimit(1)
                    .multilineTextAlignment(.trailing)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color(uiColor: .secondarySystemBackground))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.05), lineWidth: 0.8)
            )
        }

        private func statusPill(
            title: String,
            tint: Color
        ) -> some View {
            HStack(spacing: 8) {
                Circle()
                    .fill(tint)
                    .frame(width: 8, height: 8)

                Text(title)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(
                Capsule()
                    .fill(tint.opacity(0.12))
            )
        }
    #endif
}
