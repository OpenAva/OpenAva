import ChatUI
import SwiftUI
import UniformTypeIdentifiers

#if targetEnvironment(macCatalyst)
    @MainActor
    private final class WorkspaceDocumentPickerDelegate: NSObject, UIDocumentPickerDelegate {
        private let onCompletion: (Result<[URL], Error>) -> Void

        init(onCompletion: @escaping (Result<[URL], Error>) -> Void) {
            self.onCompletion = onCompletion
            super.init()
        }

        func documentPicker(_: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
            onCompletion(.success(urls))
        }

        func documentPickerWasCancelled(_: UIDocumentPickerViewController) {
            onCompletion(.success([]))
        }
    }
#endif

struct AgentOnboardingView: View {
    @Environment(\.appContainerStore) private var containerStore
    @Environment(\.openURL) private var openURL
    @State private var navigationPath: [AgentCreationViewModel.CreationMode] = []
    @State private var showsWorkspaceImporter = false
    @State private var showsWorkspaceOptions = false
    @State private var workspaceErrorMessage: String?
    #if targetEnvironment(macCatalyst)
        @State private var workspaceDocumentPickerDelegate: WorkspaceDocumentPickerDelegate?
    #endif

    let onComplete: () -> Void

    var body: some View {
        NavigationStack(path: $navigationPath) {
            GeometryReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 32) {
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
            .fileImporter(
                isPresented: $showsWorkspaceImporter,
                allowedContentTypes: [.folder],
                allowsMultipleSelection: false,
                onCompletion: handleWorkspaceImport
            )
            .alert(L10n.tr("common.error"), isPresented: Binding(
                get: { workspaceErrorMessage != nil },
                set: { if !$0 { workspaceErrorMessage = nil } }
            )) {
                Button(L10n.tr("common.ok"), role: .cancel) {}
            } message: {
                Text(workspaceErrorMessage ?? "")
            }
            .overlay {
                if showsWorkspaceOptions {
                    workspaceOptionsOverlay
                }
            }
        }
    }

    private func handleWorkspaceImport(_ result: Result<[URL], Error>) {
        do {
            guard let url = try result.get().first else { return }
            _ = try containerStore.importProjectWorkspace(at: url)
        } catch {
            workspaceErrorMessage = error.localizedDescription
        }
    }

    private func openWorkspaceImporter() {
        #if targetEnvironment(macCatalyst)
            if let windowScene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
               let window = windowScene.windows.first(where: { $0.isKeyWindow }),
               let rootVC = window.rootViewController
            {
                let pickerDelegate = WorkspaceDocumentPickerDelegate { result in
                    handleWorkspaceImport(result)
                    workspaceDocumentPickerDelegate = nil
                }
                workspaceDocumentPickerDelegate = pickerDelegate

                let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.folder], asCopy: false)
                picker.allowsMultipleSelection = false
                picker.delegate = pickerDelegate

                var topVC = rootVC
                while let presented = topVC.presentedViewController {
                    topVC = presented
                }
                topVC.present(picker, animated: true)
                return
            }
        #endif

        showsWorkspaceImporter = true
    }

    private var workspaceOptionsOverlay: some View {
        ZStack {
            Color.black.opacity(0.3)
                .ignoresSafeArea()
                .onTapGesture {
                    withAnimation(.easeOut(duration: 0.15)) {
                        showsWorkspaceOptions = false
                    }
                }

            if let workspace = containerStore.activeProjectWorkspace {
                VStack(spacing: 0) {
                    Text("当前工作区")
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundStyle(Color(uiColor: ChatUIDesign.Color.offBlack))
                        .tracking(-0.2)
                        .padding(.top, 24)
                        .padding(.bottom, 16)

                    VStack(alignment: .leading, spacing: 0) {
                        Button {
                            withAnimation(.easeOut(duration: 0.15)) {
                                showsWorkspaceOptions = false
                            }
                            let url = ProjectWorkspaceStore.resolvedURL(for: workspace)
                            UIApplication.shared.open(url)
                        } label: {
                            HStack(spacing: 12) {
                                ZStack {
                                    Circle()
                                        .fill(Color(uiColor: ChatUIDesign.Color.pureWhite))
                                        .frame(width: 36, height: 36)
                                        .overlay(
                                            Circle().stroke(Color(uiColor: ChatUIDesign.Color.oatBorder), lineWidth: 1)
                                        )
                                    Image(systemName: "folder")
                                        .font(.system(size: 16, weight: .regular))
                                        .foregroundStyle(Color(uiColor: ChatUIDesign.Color.offBlack))
                                }
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("在访达中打开")
                                        .font(.system(size: 16, weight: .medium))
                                        .foregroundStyle(Color(uiColor: ChatUIDesign.Color.offBlack))
                                    Text(workspace.displayPath ?? workspace.resolvedName)
                                        .font(.system(size: 13))
                                        .foregroundStyle(Color(uiColor: ChatUIDesign.Color.black60))
                                        .lineLimit(1)
                                        .truncationMode(.middle)
                                }
                                Spacer(minLength: 0)
                            }
                            .padding(.vertical, 8)
                            .padding(.horizontal, 16)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .onHover { isHovered in
                            if isHovered { NSCursor.pointingHand.push() } else { NSCursor.pop() }
                        }

                        Button {
                            withAnimation(.easeOut(duration: 0.15)) {
                                showsWorkspaceOptions = false
                            }
                            openWorkspaceImporter()
                        } label: {
                            HStack(spacing: 12) {
                                ZStack {
                                    Circle()
                                        .fill(Color(uiColor: ChatUIDesign.Color.pureWhite))
                                        .frame(width: 36, height: 36)
                                        .overlay(
                                            Circle().stroke(Color(uiColor: ChatUIDesign.Color.oatBorder), lineWidth: 1)
                                        )
                                    Image(systemName: "folder.badge.gearshape")
                                        .font(.system(size: 16, weight: .regular))
                                        .foregroundStyle(Color(uiColor: ChatUIDesign.Color.offBlack))
                                }
                                Text("更改工作区...")
                                    .font(.system(size: 16, weight: .medium))
                                    .foregroundStyle(Color(uiColor: ChatUIDesign.Color.offBlack))
                                Spacer(minLength: 0)
                            }
                            .padding(.vertical, 8)
                            .padding(.horizontal, 16)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .onHover { isHovered in
                            if isHovered { NSCursor.pointingHand.push() } else { NSCursor.pop() }
                        }
                    }
                    .padding(.bottom, 8)

                    Button {
                        withAnimation(.easeOut(duration: 0.15)) {
                            showsWorkspaceOptions = false
                        }
                    } label: {
                        Text(L10n.tr("common.cancel"))
                            .font(.system(size: 16, weight: .medium))
                            .foregroundStyle(Color(uiColor: ChatUIDesign.Color.pureWhite))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 12)
                            .background(Color(uiColor: ChatUIDesign.Color.offBlack))
                            .clipShape(RoundedRectangle(cornerRadius: ChatUIDesign.Radius.button, style: .continuous))
                    }
                    .buttonStyle(.plain)
                    .padding(.horizontal, 16)
                    .padding(.bottom, 24)
                    .onHover { isHovered in
                        if isHovered { NSCursor.pointingHand.push() } else { NSCursor.pop() }
                    }
                }
                .background(
                    Color(uiColor: ChatUIDesign.Color.warmCream),
                    in: RoundedRectangle(cornerRadius: ChatUIDesign.Radius.card, style: .continuous)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: ChatUIDesign.Radius.card, style: .continuous)
                        .stroke(Color(uiColor: ChatUIDesign.Color.oatBorder), lineWidth: 1)
                )
                .frame(width: 320)
                .shadow(color: Color.black.opacity(0.05), radius: 20, x: 0, y: 10)
                .transition(.opacity.combined(with: .scale(scale: 0.95)))
            }
        }
        .zIndex(100)
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
                    .font(.system(size: 20, weight: .regular))
                    .tracking(-0.2)
                    .foregroundStyle(Color(uiColor: ChatUIDesign.Color.offBlack))

                if let workspace = containerStore.activeProjectWorkspace {
                    Button {
                        withAnimation(.easeOut(duration: 0.15)) {
                            showsWorkspaceOptions = true
                        }
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "folder.fill")
                                .font(.system(size: 12))
                                .foregroundStyle(Color(uiColor: ChatUIDesign.Color.contentTertiary))
                            Text(workspace.resolvedName)
                                .font(.system(size: 13, weight: .regular))
                                .foregroundStyle(Color(uiColor: ChatUIDesign.Color.black60))
                                .lineLimit(1)
                            Image(systemName: "chevron.up.chevron.down")
                                .font(.system(size: 10))
                                .foregroundStyle(Color(uiColor: ChatUIDesign.Color.black50))
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(Color(uiColor: ChatUIDesign.Color.oatBorder).opacity(0.4))
                        .clipShape(Capsule())
                        .contentShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    .onHover { isHovered in
                        if isHovered {
                            NSCursor.pointingHand.push()
                        } else {
                            NSCursor.pop()
                        }
                    }
                }
            }

            VStack(alignment: .leading, spacing: 12) {
                Text(L10n.tr("agent.onboarding.title"))
                    .font(.system(size: 40, weight: .regular))
                    .tracking(-1.2)
                    .foregroundStyle(Color(uiColor: ChatUIDesign.Color.offBlack))
                    .fixedSize(horizontal: false, vertical: true)

                Text(L10n.tr("agent.onboarding.subtitle"))
                    .font(.system(size: 16, weight: .regular))
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
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(tint.opacity(0.04))
                    .frame(width: 48, height: 48)
                    .overlay {
                        Image(systemName: systemImage)
                            .font(.system(size: 20, weight: .regular))
                            .foregroundStyle(tint)
                    }

                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.system(size: 16, weight: .medium))
                        .foregroundStyle(Color(uiColor: ChatUIDesign.Color.offBlack))

                    Text(subtitle)
                        .font(.system(size: 14, weight: .regular))
                        .foregroundStyle(Color(uiColor: ChatUIDesign.Color.black60))
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: 16)

                Image(systemName: "chevron.right")
                    .font(.system(size: 16, weight: .regular))
                    .foregroundStyle(chevronTint)
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(uiColor: ChatUIDesign.Color.pureWhite))
            .clipShape(RoundedRectangle(cornerRadius: ChatUIDesign.Radius.card, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: ChatUIDesign.Radius.card, style: .continuous)
                    .stroke(Color(uiColor: ChatUIDesign.Color.oatBorder), lineWidth: 1)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(ScaleButtonStyle())
    }
}

// MARK: - Custom Style

struct ScaleButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.96 : 1)
            .animation(.interactiveSpring(response: 0.2, dampingFraction: 0.7, blendDuration: 0.1), value: configuration.isPressed)
    }
}

#Preview {
    AgentOnboardingView(onComplete: {})
        .environment(\.appContainerStore, AppContainerStore(container: .makeDefault()))
}
