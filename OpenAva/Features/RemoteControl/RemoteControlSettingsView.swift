import SwiftUI

struct RemoteControlSettingsView: View {
    #if targetEnvironment(macCatalyst)
        @State private var statusStore = RemoteControlStatusStore.shared
    #endif

    var body: some View {
        #if targetEnvironment(macCatalyst)
            Form {
                Section(L10n.tr("settings.remoteControl.host.title")) {
                    if let advertiseStatusText = statusStore.advertiseStatusText {
                        Text(advertiseStatusText)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    if let advertiseRegistrationText = statusStore.advertiseRegistrationText {
                        Text(advertiseRegistrationText)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    if let port = statusStore.advertisedPort {
                        LabeledContent(L10n.tr("settings.remoteControl.status.hostPort"), value: String(port))
                    }
                    if let pairCode = statusStore.currentPairCode {
                        LabeledContent(L10n.tr("settings.remoteControl.status.hostCode"), value: pairCode)
                    } else {
                        Text(L10n.tr("settings.remoteControl.host.waiting"))
                            .foregroundStyle(.secondary)
                    }
                    if let peerName = statusStore.currentPairPeerName {
                        LabeledContent(L10n.tr("settings.remoteControl.status.hostPeer"), value: peerName)
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .background(Color.white)
            .navigationTitle(L10n.tr("settings.remoteControl.navigationTitle"))
            .navigationBarTitleDisplayMode(.inline)
        #else
            RemoteControlClientView()
        #endif
    }
}
