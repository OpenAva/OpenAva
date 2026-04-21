import ChatUI
import SwiftUI

struct AgentOnboardingView: View {
    @State private var navigationPath: [AgentCreationViewModel.CreationMode] = []

    let onComplete: () -> Void

    var body: some View {
        NavigationStack(path: $navigationPath) {
            GeometryReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 48) {
                        heroSection
                        actionSection
                    }
                    .padding(.horizontal, 32)
                    .frame(maxWidth: 640, alignment: .leading)
                    .frame(maxWidth: .infinity)
                    // Offset vertically slightly above true center for a better golden ratio feel
                    .frame(minHeight: proxy.size.height * 0.85, alignment: .center)
                }
            }
            .background(Color(uiColor: ChatUIDesign.Color.warmCream).ignoresSafeArea())
            .navigationBarTitleDisplayMode(.inline)
            .navigationDestination(for: AgentCreationViewModel.CreationMode.self) { mode in
                AgentCreationView(initialMode: mode, onComplete: onComplete)
            }
        }
    }

    // MARK: - Hero

    private var heroSection: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack(spacing: 12) {
                Image("Logo")
                    .resizable()
                    .scaledToFit()
                    .frame(width: 32, height: 32)

                Text("OpenAva")
                    .font(.system(size: 20, weight: .medium))
                    .foregroundStyle(Color(uiColor: ChatUIDesign.Color.black80))
            }

            VStack(alignment: .leading, spacing: 12) {
                Text(L10n.tr("agent.onboarding.title"))
                    .font(.system(size: 36, weight: .semibold))
                    .tracking(-1.0)
                    .foregroundStyle(Color(uiColor: ChatUIDesign.Color.offBlack))
                    .fixedSize(horizontal: false, vertical: true)

                Text(L10n.tr("agent.onboarding.subtitle"))
                    .font(.system(size: 16))
                    .foregroundStyle(Color(uiColor: ChatUIDesign.Color.black60))
                    .fixedSize(horizontal: false, vertical: true)
                    .lineSpacing(4)
            }
        }
    }

    // MARK: - Action

    private var actionSection: some View {
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

    // MARK: - Card

    private func onboardingCard(
        title: String,
        subtitle: String,
        systemImage: String,
        tint: Color,
        chevronTint: Color,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 16) {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(tint.opacity(0.08))
                    .frame(width: 52, height: 52)
                    .overlay {
                        Image(systemName: systemImage)
                            .font(.system(size: 20, weight: .medium))
                            .foregroundStyle(tint)
                    }

                VStack(alignment: .leading, spacing: 4) {
                    Text(title)
                        .font(.system(size: 18, weight: .semibold))
                        .tracking(-0.3)
                        .foregroundStyle(Color(uiColor: ChatUIDesign.Color.offBlack))

                    Text(subtitle)
                        .font(.system(size: 15))
                        .foregroundStyle(Color(uiColor: ChatUIDesign.Color.black60))
                        .fixedSize(horizontal: false, vertical: true)
                        .lineSpacing(3)
                }

                Spacer(minLength: 12)

                Image(systemName: "chevron.right")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(chevronTint)
            }
            .padding(20)
            .background(Color.white)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
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
