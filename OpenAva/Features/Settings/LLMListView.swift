import ChatUI
import SwiftUI

/// List view for managing multiple LLM configurations
struct LLMListView: View {
    @Environment(\.appContainerStore) private var containerStore

    @State private var models: [AppConfig.LLMModel] = []
    @State private var selectedModelID: UUID?
    @State private var isShowingAddSheet = false
    @State private var editingModel: AppConfig.LLMModel?
    @State private var modelToDelete: AppConfig.LLMModel?
    @State private var showResetUsageConfirmation = false

    private var selectedModel: AppConfig.LLMModel? {
        models.first(where: { $0.id == selectedModelID }) ?? models.first
    }

    private var deleteAlertBinding: Binding<Bool> {
        Binding(
            get: { modelToDelete != nil },
            set: { isPresented in
                if !isPresented {
                    modelToDelete = nil
                }
            }
        )
    }

    var body: some View {
        modelList
            .navigationTitle(L10n.tr("settings.llm.navigationTitle"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button {
                        isShowingAddSheet = true
                    } label: {
                        Label(L10n.tr("settings.llmList.addModel"), systemImage: "plus")
                    }
                }
            }
            .sheet(isPresented: $isShowingAddSheet) {
                NavigationStack {
                    LLMEditView(
                        mode: .add,
                        onSave: { newModel in
                            containerStore.saveLLMModel(newModel)
                            refreshModels()
                            isShowingAddSheet = false
                        },
                        onCancel: {
                            isShowingAddSheet = false
                        }
                    )
                }
                #if targetEnvironment(macCatalyst)
                .frame(minWidth: 640, idealWidth: 640, minHeight: 600, idealHeight: 600)
                #endif
            }
            .sheet(item: $editingModel) { model in
                NavigationStack {
                    LLMEditView(
                        mode: .edit(model),
                        onSave: { updatedModel in
                            containerStore.saveLLMModel(updatedModel)
                            refreshModels()
                            editingModel = nil
                        },
                        onCancel: {
                            editingModel = nil
                        }
                    )
                }
                #if targetEnvironment(macCatalyst)
                .frame(minWidth: 640, idealWidth: 640, minHeight: 600, idealHeight: 600)
                #endif
            }
            .alert(L10n.tr("settings.llmList.delete.title"), isPresented: deleteAlertBinding) {
                Button(L10n.tr("common.cancel"), role: .cancel) {
                    modelToDelete = nil
                }
                Button(L10n.tr("common.delete"), role: .destructive) {
                    if let model = modelToDelete {
                        deleteModel(model)
                    }
                }
            } message: {
                if let model = modelToDelete {
                    Text(L10n.tr("settings.llmList.delete.message", model.name))
                }
            }
            .onAppear {
                refreshModels()
            }
            .refreshable {
                refreshModels()
            }
    }

    private var modelList: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                VStack(alignment: .leading, spacing: 16) {
                    HStack(alignment: .center, spacing: 8) {
                        Text(L10n.tr("settings.llmList.configured.header"))
                            .font(.system(size: 20, weight: .regular))
                            .tracking(-0.2)
                            .foregroundStyle(Color(uiColor: ChatUIDesign.Color.offBlack))

                        if !models.isEmpty {
                            CountBadge(text: "\(models.count)")
                        }

                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 16)

                    VStack(spacing: 8) {
                        modelRows
                    }
                    .padding(.horizontal, 16)
                }

                usageSummarySection
                    .padding(.horizontal, 16)
            }
            .padding(.vertical, 24)
        }
        .scrollContentBackground(.hidden)
        .background(Color(uiColor: ChatUIDesign.Color.warmCream).ignoresSafeArea())
        .confirmationDialog(
            L10n.tr("settings.usage.reset.confirmTitle"),
            isPresented: $showResetUsageConfirmation,
            titleVisibility: .visible
        ) {
            Button(L10n.tr("settings.usage.reset.confirm"), role: .destructive) {
                containerStore.resetUsageStats()
            }
            Button(L10n.tr("common.cancel"), role: .cancel) {}
        } message: {
            Text(L10n.tr("settings.usage.reset.message"))
        }
    }

    @ViewBuilder
    private var modelRows: some View {
        if models.isEmpty {
            EmptyModelsView {
                isShowingAddSheet = true
            }
        } else {
            ForEach(models) { model in
                ModelRow(
                    model: model,
                    isSelected: model.id == selectedModelID,
                    usageRecord: usageRecord(for: model),
                    onSelect: { selectModel(model) },
                    onEdit: { openEditor(for: model) },
                    onDelete: { modelToDelete = model }
                )
                .contentShape(Rectangle())
                .onTapGesture {
                    selectModel(model)
                }
                .contextMenu {
                    Button {
                        selectModel(model)
                    } label: {
                        Label(L10n.tr("settings.llmList.action.use"), systemImage: "checkmark.circle")
                    }

                    Button {
                        openEditor(for: model)
                    } label: {
                        Label(L10n.tr("common.edit"), systemImage: "pencil")
                    }

                    Button(role: .destructive) {
                        modelToDelete = model
                    } label: {
                        Label(L10n.tr("common.delete"), systemImage: "trash")
                    }
                }
            }
        }
    }

    private func refreshModels() {
        let collection = containerStore.container.config.llmCollection
        models = collection.models
        selectedModelID = containerStore.container.config.selectedLLMModelID
    }

    private func usageRecord(for model: AppConfig.LLMModel) -> ModelUsageRecord? {
        guard let key = model.model else { return nil }
        return containerStore.usageSnapshot.byModel[key]
    }

    private var configuredFooterText: String {
        #if targetEnvironment(macCatalyst)
            L10n.tr("settings.llmList.configured.footer.mac")
        #else
            L10n.tr("settings.llmList.configured.footer")
        #endif
    }

    @ViewBuilder
    private var usageSummarySection: some View {
        let snapshot = containerStore.usageSnapshot
        if !snapshot.byModel.isEmpty {
            VStack(alignment: .leading, spacing: 16) {
                Text(L10n.tr("settings.usage.navigationTitle"))
                    .font(.system(size: 20, weight: .regular))
                    .tracking(-0.2)
                    .foregroundStyle(Color(uiColor: ChatUIDesign.Color.offBlack))

                VStack(spacing: 12) {
                    HStack {
                        Text(L10n.tr("settings.usage.totalTokens"))
                            .foregroundStyle(Color(uiColor: ChatUIDesign.Color.offBlack))
                        Spacer()
                        Text(formatUsageTokens(snapshot.totalTokens))
                            .foregroundStyle(Color(uiColor: ChatUIDesign.Color.black60))
                            .monospacedDigit()
                    }
                    if snapshot.totalCostUSD > 0 {
                        Rectangle().fill(Color(uiColor: ChatUIDesign.Color.warmSand)).frame(height: 1)
                        HStack {
                            Text(L10n.tr("settings.usage.totalCost"))
                                .foregroundStyle(Color(uiColor: ChatUIDesign.Color.offBlack))
                            Spacer()
                            Text(formatUsageCost(snapshot.totalCostUSD))
                                .foregroundStyle(Color(uiColor: ChatUIDesign.Color.black60))
                                .monospacedDigit()
                        }
                    }
                    Rectangle().fill(Color(uiColor: ChatUIDesign.Color.warmSand)).frame(height: 1)
                    Button {
                        showResetUsageConfirmation = true
                    } label: {
                        Text(L10n.tr("settings.usage.reset"))
                            .font(.system(size: 14, weight: .medium))
                            .foregroundStyle(Color(uiColor: ChatUIDesign.Color.black60))
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 16)
                .background(
                    RoundedRectangle(cornerRadius: ChatUIDesign.Radius.card, style: .continuous)
                        .fill(Color(uiColor: ChatUIDesign.Color.pureWhite))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: ChatUIDesign.Radius.card, style: .continuous)
                        .strokeBorder(Color(uiColor: ChatUIDesign.Color.oatBorder), lineWidth: 1)
                )
            }
        }
    }

    private func formatUsageTokens(_ n: Int) -> String {
        switch n {
        case 1_000_000...: return String(format: "%.2fM", Double(n) / 1_000_000)
        case 1000...: return String(format: "%.1fK", Double(n) / 1000)
        default: return "\(n)"
        }
    }

    private func formatUsageCost(_ usd: Double) -> String {
        if usd < 0.001 { return "< $0.001" }
        return String(format: "$%.4f", usd)
    }

    private func selectModel(_ model: AppConfig.LLMModel) {
        containerStore.selectLLMModel(id: model.id)
        selectedModelID = model.id
    }

    private func openEditor(for model: AppConfig.LLMModel) {
        editingModel = model
    }

    private func deleteModel(_ model: AppConfig.LLMModel) {
        containerStore.deleteLLMModel(id: model.id)
        refreshModels()
        modelToDelete = nil
    }
}

// MARK: - Subviews

private struct EmptyModelsView: View {
    let onAdd: () -> Void

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "cpu")
                .font(.system(size: 28, weight: .light))
                .foregroundStyle(Color(uiColor: ChatUIDesign.Color.black50))

            VStack(spacing: 8) {
                Text(L10n.tr("settings.llmList.empty.title"))
                    .font(.system(size: 18, weight: .medium))
                    .foregroundStyle(Color(uiColor: ChatUIDesign.Color.offBlack))

                Text(L10n.tr("settings.llmList.empty.message"))
                    .font(.footnote)
                    .foregroundStyle(Color(uiColor: ChatUIDesign.Color.black60))
                    .multilineTextAlignment(.center)
            }

            Button(action: onAdd) {
                Text(L10n.tr("settings.llmList.addModel"))
                    .font(.system(size: 14, weight: .medium))
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                    .background(Color(uiColor: ChatUIDesign.Color.black80).opacity(0.05))
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            }
            .buttonStyle(.plain)
        }
        .frame(maxWidth: .infinity, minHeight: 120)
        .padding(20)
        .background(
            RoundedRectangle(cornerRadius: ChatUIDesign.Radius.card, style: .continuous)
                .fill(Color(uiColor: ChatUIDesign.Color.pureWhite))
        )
        .overlay(
            RoundedRectangle(cornerRadius: ChatUIDesign.Radius.card, style: .continuous)
                .strokeBorder(Color(uiColor: ChatUIDesign.Color.oatBorder), style: StrokeStyle(lineWidth: 1, dash: [4, 4]))
        )
    }
}

private struct ModelRow: View {
    let model: AppConfig.LLMModel
    let isSelected: Bool
    let usageRecord: ModelUsageRecord?
    let onSelect: () -> Void
    let onEdit: () -> Void
    let onDelete: () -> Void

    @State private var isHovering = false

    var body: some View {
        HStack(alignment: .center, spacing: 16) {
            // Icon
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(
                    isSelected
                        ? Color(uiColor: ChatUIDesign.Color.brandOrange).opacity(0.10)
                        : Color(uiColor: ChatUIDesign.Color.black80).opacity(0.05)
                )
                .frame(width: 40, height: 40)
                .overlay(
                    Image(systemName: "cpu")
                        .font(.system(size: 16, weight: .medium))
                        .foregroundStyle(
                            isSelected
                                ? Color(uiColor: ChatUIDesign.Color.brandOrange)
                                : Color(uiColor: ChatUIDesign.Color.black60)
                        )
                )

            // Info
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .center, spacing: 8) {
                    Text(model.name)
                        .font(.system(size: 16, weight: .medium))
                        .foregroundStyle(Color(uiColor: ChatUIDesign.Color.offBlack))
                        .lineLimit(1)

                    if !model.isConfigured {
                        CompactTag(text: L10n.tr("settings.llmList.status.incomplete"), tone: .warning)
                    } else if isSelected {
                        CompactTag(text: L10n.tr("settings.llmList.status.active"), tone: .accent)
                    }
                }

                HStack(spacing: 6) {
                    Text(model.provider)
                        .font(.system(size: 13))
                        .foregroundStyle(Color(uiColor: ChatUIDesign.Color.black60))

                    Text("·")
                        .font(.system(size: 13))
                        .foregroundStyle(Color(uiColor: ChatUIDesign.Color.black50))

                    Text(model.model ?? L10n.tr("common.unknown"))
                        .font(.system(size: 13))
                        .foregroundStyle(Color(uiColor: ChatUIDesign.Color.black60))
                        .lineLimit(1)
                }

                if let record = usageRecord, record.totalTokens > 0 {
                    usageLine(record: record)
                }
            }

            Spacer(minLength: 16)

            // Trailing actions and selected indicator
            HStack(spacing: 16) {
                // Actions (Edit / Delete) - Only show on hover for Mac, always hidden for iOS (use swipe/context menu)
                #if targetEnvironment(macCatalyst)
                    HStack(spacing: 8) {
                        Button(action: onEdit) {
                            Image(systemName: "pencil")
                                .font(.system(size: 13, weight: .medium))
                                .foregroundStyle(Color(uiColor: ChatUIDesign.Color.black60))
                                .frame(width: 28, height: 28)
                                .background(Color(uiColor: ChatUIDesign.Color.black80).opacity(0.04))
                                .clipShape(Circle())
                        }
                        .buttonStyle(.plain)

                        Button(action: onDelete) {
                            Image(systemName: "trash")
                                .font(.system(size: 13, weight: .medium))
                                .foregroundStyle(Color.red.opacity(0.7))
                                .frame(width: 28, height: 28)
                                .background(Color.red.opacity(0.05))
                                .clipShape(Circle())
                        }
                        .buttonStyle(.plain)
                    }
                    .opacity(isHovering ? 1 : 0)
                #endif

                if isSelected {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 20, weight: .medium))
                        .foregroundStyle(Color(uiColor: ChatUIDesign.Color.brandOrange))
                } else {
                    Image(systemName: "circle")
                        .font(.system(size: 20, weight: .light))
                        .foregroundStyle(Color(uiColor: ChatUIDesign.Color.black80).opacity(0.1))
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(isSelected ? Color(uiColor: ChatUIDesign.Color.pureWhite) : Color(uiColor: ChatUIDesign.Color.pureWhite).opacity(0.6))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(
                    isSelected ? Color(uiColor: ChatUIDesign.Color.brandOrange).opacity(0.5) : Color(uiColor: ChatUIDesign.Color.oatBorder),
                    lineWidth: 1
                )
        )
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.15)) {
                isHovering = hovering
            }
        }
    }

    private func usageLine(record: ModelUsageRecord) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "chart.bar.fill")
                .font(.system(size: 10))
                .foregroundStyle(Color(uiColor: ChatUIDesign.Color.black50))

            ScrollView(.horizontal, showsIndicators: false) {
                metadataText(record: record)
                    .font(.system(size: 12))
                    .foregroundStyle(Color(uiColor: ChatUIDesign.Color.black50))
                    .monospacedDigit()
            }
        }
        .padding(.top, 2)
    }

    private func metadataText(record: ModelUsageRecord) -> Text {
        var text = usageMetricText("settings.usage.input", value: formatTokens(record.inputTokens))
            + Text("  ") + usageMetricText("settings.usage.output", value: formatTokens(record.outputTokens))

        if record.cacheReadTokens > 0 {
            text = text + Text("  ") + usageMetricText("settings.usage.cacheRead", value: formatTokens(record.cacheReadTokens))
        }

        if record.cacheWriteTokens > 0 {
            text = text + Text("  ") + usageMetricText("settings.usage.cacheWrite", value: formatTokens(record.cacheWriteTokens))
        }

        if record.costUSD > 0 {
            text = text + Text("  ") + usageMetricText("settings.usage.cost", value: formatCost(record.costUSD))
        }

        return text
    }

    private func usageMetricText(_ key: String, value: String) -> Text {
        Text(L10n.tr(key)) + Text(" ") + Text(verbatim: value)
    }

    private func formatTokens(_ n: Int) -> String {
        switch n {
        case 1_000_000...: return String(format: "%.1fM", Double(n) / 1_000_000)
        case 1000...: return String(format: "%.1fK", Double(n) / 1000)
        default: return "\(n)"
        }
    }

    private func formatCost(_ usd: Double) -> String {
        if usd < 0.001 { return "<$0.001" }
        if usd < 0.01 { return String(format: "$%.4f", usd) }
        return String(format: "$%.3f", usd)
    }
}

private struct CountBadge: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(Color(uiColor: ChatUIDesign.Color.black60))
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(Color(uiColor: ChatUIDesign.Color.pureWhite))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .strokeBorder(Color(uiColor: ChatUIDesign.Color.oatBorder), lineWidth: 1)
            )
    }
}

enum CompactTagTone {
    case accent, success, warning, neutral

    var foreground: Color {
        switch self {
        case .accent: return Color(uiColor: ChatUIDesign.Color.brandOrange)
        case .success: return .green
        case .warning: return .orange
        case .neutral: return Color(uiColor: ChatUIDesign.Color.black60)
        }
    }

    var background: Color {
        switch self {
        case .accent: return Color(uiColor: ChatUIDesign.Color.brandOrange).opacity(0.1)
        case .success: return .green.opacity(0.1)
        case .warning: return .orange.opacity(0.1)
        case .neutral: return Color(uiColor: ChatUIDesign.Color.black80).opacity(0.05)
        }
    }
}

struct CompactTag: View {
    let text: String
    let tone: CompactTagTone

    var body: some View {
        Text(text)
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(tone.foreground)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(tone.background)
            .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
    }
}
