import ChatUI
import SwiftUI

struct AgentOnboardingView: View {
    @State private var navigationPath: [AgentCreationViewModel.CreationMode] = []

    let onComplete: () -> Void

    var body: some View {
        NavigationStack(path: $navigationPath) {
            ScrollView {
                VStack(alignment: .leading, spacing: 28) {
                    heroSection
                    actionSection
                }
                .padding(.horizontal, 28)
                .padding(.vertical, 56)
                .frame(maxWidth: 640, alignment: .leading)
                .frame(maxWidth: .infinity)
            }
            .background(Color(uiColor: ChatUIDesign.Color.warmCream).ignoresSafeArea())
            .navigationBarTitleDisplayMode(.inline)
            .navigationDestination(for: AgentCreationViewModel.CreationMode.self) { mode in
                AgentCreationView(initialMode: mode, onComplete: onComplete)
            }
        }
    }

    private var heroSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                Image("Logo")
                    .resizable()
                    .scaledToFit()
                    .frame(width: 28, height: 28)

                Text("OpenAva")
                    .font(.system(size: 18, weight: .medium))
                    .foregroundStyle(Color(uiColor: ChatUIDesign.Color.black80))
            }

            VStack(alignment: .leading, spacing: 10) {
                Text(L10n.tr("agent.onboarding.title"))
                    .font(.system(size: 34, weight: .semibold))
                    .tracking(-0.8)
                    .foregroundStyle(Color(uiColor: ChatUIDesign.Color.offBlack))
                    .fixedSize(horizontal: false, vertical: true)

                Text(L10n.tr("agent.onboarding.subtitle"))
                    .font(.system(size: 16))
                    .foregroundStyle(Color(uiColor: ChatUIDesign.Color.black60))
                    .fixedSize(horizontal: false, vertical: true)
                    .lineSpacing(3)
            }
        }
    }

    private var actionSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(L10n.tr("agent.onboarding.sectionTitle"))
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(Color(uiColor: ChatUIDesign.Color.black60))

            VStack(spacing: 12) {
                onboardingCard(
                    title: L10n.tr("agent.onboarding.createSingle.title"),
                    subtitle: L10n.tr("agent.onboarding.createSingle.subtitle"),
                    systemImage: "sparkles",
                    tint: Color(uiColor: ChatUIDesign.Color.offBlack),
                    chevronTint: Color(uiColor: ChatUIDesign.Color.black50)
                ) {
                    navigationPath.append(.singleAgent)
                }
            }
        }
    }

    private func onboardingCard(
        title: String,
        subtitle: String,
        systemImage: String,
        tint: Color,
        chevronTint: Color,
        action: @escaping () -> Void
    ) -> some View {
        return Button(action: action) {
            HStack(spacing: 16) {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(tint.opacity(0.10))
                    .frame(width: 48, height: 48)
                    .overlay {
                        Image(systemName: systemImage)
                            .font(.system(size: 20, weight: .medium))
                            .foregroundStyle(tint)
                    }

                VStack(alignment: .leading, spacing: 6) {
                    Text(title)
                        .font(.system(size: 22, weight: .semibold))
                        .tracking(-0.3)
                        .foregroundStyle(Color(uiColor: ChatUIDesign.Color.offBlack))

                    Text(subtitle)
                        .font(.system(size: 15))
                        .foregroundStyle(Color(uiColor: ChatUIDesign.Color.black60))
                        .fixedSize(horizontal: false, vertical: true)
                        .lineSpacing(2)
                }

                Spacer(minLength: 12)

                Image(systemName: "chevron.right")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(chevronTint)
            }
            .padding(20)
            .background(Color.white.opacity(0.88))
            .clipShape(RoundedRectangle(cornerRadius: ChatUIDesign.Radius.card, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: ChatUIDesign.Radius.card, style: .continuous)
                    .stroke(Color(uiColor: ChatUIDesign.Color.oatBorder), lineWidth: 1)
            )
        }
        .buttonStyle(ScaleButtonStyle())
    }
}

// MARK: - Custom Style

struct ScaleButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(.easeInOut(duration: 0.2), value: configuration.isPressed)
    }
}

#Preview {
    AgentOnboardingView(onComplete: {})
        .environment(\.appContainerStore, AppContainerStore(container: .makeDefault()))
}
