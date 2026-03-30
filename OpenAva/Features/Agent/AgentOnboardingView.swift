import SwiftUI

struct AgentOnboardingView: View {
    @State private var showLocalCreation = false

    let onComplete: () -> Void

    var body: some View {
        NavigationStack {
            ZStack {
                Color(.systemGroupedBackground).ignoresSafeArea()

                VStack(spacing: 0) {
                    Spacer()

                    Image("Logo")
                        .resizable()
                        .scaledToFit()
                        .frame(width: 80, height: 80)
                        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                        .shadow(color: .black.opacity(0.08), radius: 12, x: 0, y: 6)
                        .padding(.bottom, 32)

                    VStack(spacing: 12) {
                        Text(L10n.tr("agent.onboarding.title"))
                            .font(.system(size: 32, weight: .bold, design: .rounded))
                            .lineLimit(1)
                            .minimumScaleFactor(0.8)

                        Text(L10n.tr("agent.onboarding.subtitle"))
                            .font(.body)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 40)
                            .lineSpacing(4)
                    }
                    .padding(.bottom, 56)

                    VStack(spacing: 16) {
                        // Local Agent Creation
                        Button {
                            showLocalCreation = true
                        } label: {
                            HStack(spacing: 16) {
                                ZStack {
                                    Circle()
                                        .fill(Color.accentColor.opacity(0.12))
                                        .frame(width: 52, height: 52)
                                    Image(systemName: "cpu")
                                        .font(.system(size: 24, weight: .medium))
                                        .foregroundStyle(Color.accentColor)
                                }

                                VStack(alignment: .leading, spacing: 4) {
                                    Text(L10n.tr("agent.onboarding.createLocal.title"))
                                        .font(.system(.headline, design: .rounded, weight: .semibold))
                                        .foregroundStyle(.primary)
                                    Text(L10n.tr("agent.onboarding.createLocal.subtitle"))
                                        .font(.subheadline)
                                        .foregroundStyle(.secondary)
                                }

                                Spacer(minLength: 0)

                                Image(systemName: "arrow.right.circle.fill")
                                    .font(.system(size: 24))
                                    .foregroundStyle(Color.accentColor.opacity(0.8))
                            }
                            .padding(16)
                            .background(Color(.systemBackground))
                            .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
                            .shadow(color: .black.opacity(0.06), radius: 16, x: 0, y: 8)
                            .overlay(
                                RoundedRectangle(cornerRadius: 24, style: .continuous)
                                    .stroke(Color.primary.opacity(0.05), lineWidth: 1)
                            )
                        }
                        .buttonStyle(ScaleButtonStyle())
                    }
                    .padding(.horizontal, 24)

                    Spacer()
                    Spacer()
                }
            }
            .navigationBarTitleDisplayMode(.inline)
        }
        .fullScreenCover(isPresented: $showLocalCreation) {
            AgentCreationView(onComplete: {
                showLocalCreation = false
                onComplete()
            })
        }
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
