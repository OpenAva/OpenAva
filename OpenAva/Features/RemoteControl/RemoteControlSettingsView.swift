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
            HostPairingStage(statusStore: statusStore, onDone: onDone)
        #else
            RemoteControlClientView()
        #endif
    }
}

#if targetEnvironment(macCatalyst)

    // MARK: - Host Pairing Stage (HomeKit / AirPlay pairing dialog style)

    private struct HostPairingStage: View {
        @Bindable var statusStore: RemoteControlStatusStore
        let onDone: (() -> Void)?

        var body: some View {
            ZStack {
                Color(uiColor: ChatUIDesign.Color.warmCream)
                    .ignoresSafeArea()

                VStack(spacing: 0) {
                    sheetTopBar(
                        title: L10n.tr("settings.remoteControl.navigationTitle"),
                        onDone: { onDone?() }
                    )

                    ScrollView {
                        VStack(spacing: 24) {
                            if let pairCode = statusStore.currentPairCode {
                                PairCodeStage(
                                    code: pairCode,
                                    peerName: statusStore.currentPairPeerName
                                )
                            } else {
                                WaitingStage()
                            }

                            FooterStatus(
                                advertiseStatusText: statusStore.advertiseStatusText,
                                advertisedPort: statusStore.advertisedPort
                            )
                        }
                        .padding(.horizontal, 32)
                        .padding(.vertical, 32)
                        .frame(maxWidth: 640)
                        .frame(maxWidth: .infinity)
                    }
                    .scrollBounceBehavior(.basedOnSize)
                }
            }
        }

        private func sheetTopBar(
            title: String,
            onDone: @escaping () -> Void
        ) -> some View {
            VStack(spacing: 0) {
                ZStack {
                    Text(title)
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(Color(uiColor: ChatUIDesign.Color.offBlack))

                    HStack {
                        Spacer(minLength: 0)
                        doneButton(onDone)
                    }
                }
                .padding(.horizontal, 20)
                .padding(.top, 16)
                .padding(.bottom, 12)

                Rectangle()
                    .fill(Color(uiColor: ChatUIDesign.Color.oatBorder))
                    .frame(height: 1)
            }
        }

        private func doneButton(_ action: @escaping () -> Void) -> some View {
            Button(action: action) {
                Text(L10n.tr("common.done"))
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(Color(uiColor: ChatUIDesign.Color.pureWhite))
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(Color(uiColor: ChatUIDesign.Color.offBlack))
                    .clipShape(RoundedRectangle(cornerRadius: ChatUIDesign.Radius.button, style: .continuous))
            }
            .buttonStyle(.plain)
        }
    }

    // MARK: - Waiting Stage

    private struct WaitingStage: View {
        @State private var pulse = false

        var body: some View {
            VStack(spacing: 20) {
                ZStack {
                    Circle()
                        .strokeBorder(Color(uiColor: ChatUIDesign.Color.oatBorder), lineWidth: 1)
                        .frame(width: 140, height: 140)
                        .scaleEffect(pulse ? 1.2 : 1.0)
                        .opacity(pulse ? 0.0 : 0.8)

                    Circle()
                        .strokeBorder(Color(uiColor: ChatUIDesign.Color.oatBorder), lineWidth: 1)
                        .frame(width: 104, height: 104)
                        .scaleEffect(pulse ? 1.12 : 1.0)
                        .opacity(pulse ? 0.2 : 0.8)

                    Circle()
                        .fill(Color(uiColor: ChatUIDesign.Color.pureWhite))
                        .frame(width: 76, height: 76)
                        .overlay(
                            Circle()
                                .strokeBorder(Color(uiColor: ChatUIDesign.Color.oatBorder), lineWidth: 1)
                        )

                    Image(systemName: "iphone.gen3")
                        .font(.system(size: 30, weight: .regular))
                        .foregroundStyle(Color(uiColor: ChatUIDesign.Color.offBlack))
                }
                .frame(height: 140)
                .onAppear {
                    withAnimation(.easeOut(duration: 1.8).repeatForever(autoreverses: false)) {
                        pulse = true
                    }
                }

                VStack(spacing: 6) {
                    Text(L10n.tr("settings.remoteControl.host.waiting.title"))
                        .font(.system(size: 28, weight: .regular))
                        .tracking(-0.8)
                        .foregroundStyle(Color(uiColor: ChatUIDesign.Color.offBlack))
                        .multilineTextAlignment(.center)

                    Text(L10n.tr("settings.remoteControl.host.waiting"))
                        .font(.system(size: 14, weight: .regular))
                        .foregroundStyle(Color(uiColor: ChatUIDesign.Color.black60))
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    // MARK: - Pair Code Stage (dominant code display)

    private struct PairCodeStage: View {
        let code: String
        let peerName: String?

        var body: some View {
            VStack(spacing: 24) {
                VStack(spacing: 8) {
                    HStack(spacing: 8) {
                        Circle()
                            .fill(Color(uiColor: ChatUIDesign.Color.brandOrange))
                            .frame(width: 8, height: 8)

                        Text(L10n.tr("settings.remoteControl.host.pairingRequested").uppercased())
                            .font(.system(size: 11, weight: .medium, design: .monospaced))
                            .tracking(1.2)
                            .foregroundStyle(Color(uiColor: ChatUIDesign.Color.brandOrange))
                    }

                    if let peerName {
                        Text(peerName)
                            .font(.system(size: 18, weight: .regular))
                            .tracking(-0.2)
                            .foregroundStyle(Color(uiColor: ChatUIDesign.Color.offBlack))
                            .lineLimit(1)
                    }
                }

                CodeDisplay(code: code)
            }
        }
    }

    private struct CodeDisplay: View {
        let code: String

        var body: some View {
            HStack(spacing: 10) {
                ForEach(Array(digits.enumerated()), id: \.offset) { _, digit in
                    DigitCell(digit: digit)
                }
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 24)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color(uiColor: ChatUIDesign.Color.pureWhite))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(Color(uiColor: ChatUIDesign.Color.oatBorder), lineWidth: 1)
            )
        }

        private var digits: [Character] {
            Array(code)
        }
    }

    private struct DigitCell: View {
        let digit: Character

        var body: some View {
            Text(String(digit))
                .font(.system(size: 56, weight: .semibold, design: .monospaced))
                .tracking(-1.0)
                .foregroundStyle(Color(uiColor: ChatUIDesign.Color.offBlack))
                .frame(minWidth: 44)
                .padding(.horizontal, 4)
                .overlay(alignment: .bottom) {
                    Rectangle()
                        .fill(Color(uiColor: ChatUIDesign.Color.offBlack))
                        .frame(height: 2)
                        .padding(.horizontal, 4)
                        .offset(y: 4)
                }
        }
    }

    // MARK: - Footer Status

    private struct FooterStatus: View {
        let advertiseStatusText: String?
        let advertisedPort: UInt16?

        private var isCritical: Bool {
            guard let text = advertiseStatusText else { return false }
            return text.contains("失败") || text.localizedCaseInsensitiveContains("failed")
        }

        var body: some View {
            VStack(spacing: 8) {
                if isCritical, let advertiseStatusText {
                    Text(advertiseStatusText)
                        .font(.system(size: 13, weight: .regular))
                        .foregroundStyle(.red)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                } else if let advertisedPort {
                    StatusChip(
                        label: L10n.tr("settings.remoteControl.status.hostPort"),
                        value: String(advertisedPort)
                    )
                }
            }
        }
    }

    private struct StatusChip: View {
        let label: String
        let value: String

        var body: some View {
            HStack(spacing: 6) {
                Text(label.uppercased())
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .tracking(0.8)
                    .foregroundStyle(Color(uiColor: ChatUIDesign.Color.black50))

                Text(value)
                    .font(.system(size: 12, weight: .regular, design: .monospaced))
                    .foregroundStyle(Color(uiColor: ChatUIDesign.Color.black80))
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .overlay(
                Capsule()
                    .strokeBorder(Color(uiColor: ChatUIDesign.Color.oatBorder), lineWidth: 1)
            )
        }
    }

    // MARK: - Host Button Styles

    private struct HostGhostButtonStyle: ButtonStyle {
        func makeBody(configuration: Configuration) -> some View {
            configuration.label
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(Color(uiColor: ChatUIDesign.Color.offBlack))
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(Color.clear)
                .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .strokeBorder(Color(uiColor: ChatUIDesign.Color.oatBorder), lineWidth: 1)
                )
                .scaleEffect(configuration.isPressed ? 0.85 : 1.0)
                .animation(.interactiveSpring(), value: configuration.isPressed)
        }
    }

#endif
