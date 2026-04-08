import SwiftUI

/// List view for managing multiple LLM configurations
struct LLMListView: View {
    @Environment(\.appContainerStore) private var containerStore
    @Environment(\.dismiss) private var dismiss

    @State private var models: [AppConfig.LLMModel] = []
    @State private var selectedModelID: UUID?
    @State private var isShowingAddSheet = false
    @State private var editingModel: AppConfig.LLMModel?
    @State private var modelToDelete: AppConfig.LLMModel?
    @State private var showResetUsageConfirmation = false

    #if targetEnvironment(macCatalyst)
        @State private var editorMode: EditorMode?
    #endif

    #if targetEnvironment(macCatalyst)
        private enum EditorMode {
            case create
            case edit(AppConfig.LLMModel)

            var id: String {
                switch self {
                case .create:
                    return "create"
                case let .edit(model):
                    return "edit-\(model.id.uuidString)"
                }
            }
        }
    #endif

    var body: some View {
        #if targetEnvironment(macCatalyst)
            Group {
                if let editorMode {
                    HStack(spacing: 0) {
                        modelList
                            .frame(minWidth: 300, idealWidth: 340)

                        modelDetail(for: editorMode)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .background(Color(uiColor: .systemBackground))
                    }
                    .background(Color(uiColor: .systemGroupedBackground))
                } else {
                    modelList
                }
            }
            .navigationTitle(L10n.tr("settings.llm.navigationTitle"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button {
                        editorMode = .create
                    } label: {
                        Label(L10n.tr("settings.llmList.addModel"), systemImage: "plus")
                    }
                }
            }
            .alert(L10n.tr("settings.llmList.delete.title"), isPresented: .constant(modelToDelete != nil)) {
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
            .background(Color(uiColor: .systemGroupedBackground))
        #else
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
                        .buttonStyle(.bordered)
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
                }
                .alert(L10n.tr("settings.llmList.delete.title"), isPresented: .constant(modelToDelete != nil)) {
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
        #endif
    }

    private var modelList: some View {
        List {
            #if targetEnvironment(macCatalyst)
                Text(L10n.tr("settings.llmList.configured.header"))
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .textCase(nil)
                    .listRowInsets(EdgeInsets(top: 16, leading: 16, bottom: 8, trailing: 16))
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)

                modelRows

                Text(configuredFooterText)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 12, trailing: 16))
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)

                usageSummarySection
            #else
                Section {
                    modelRows
                } header: {
                    Text(L10n.tr("settings.llmList.configured.header"))
                } footer: {
                    Text(configuredFooterText)
                }

                usageSummarySection
            #endif
        }
        #if targetEnvironment(macCatalyst)
        .listStyle(.plain)
        #else
        .listStyle(.insetGrouped)
        #endif
        .scrollContentBackground(.hidden)
        .background(Color(uiColor: .systemGroupedBackground))
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
            EmptyModelsView()
                .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
        } else {
            ForEach(models) { model in
                ModelRow(
                    model: model,
                    isSelected: model.id == selectedModelID
                )
                .listRowInsets(EdgeInsets(top: 6, leading: 16, bottom: 6, trailing: 16))
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
                .contentShape(Rectangle())
                .onTapGesture {
                    selectModel(model)
                }
                .swipeActions(edge: .trailing) {
                    Button(role: .destructive) {
                        modelToDelete = model
                    } label: {
                        Label(L10n.tr("common.delete"), systemImage: "trash")
                    }
                    Button {
                        openEditor(for: model)
                    } label: {
                        Label(L10n.tr("common.edit"), systemImage: "pencil")
                    }
                    .tint(.blue)
                }
                .contextMenu {
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

    #if targetEnvironment(macCatalyst)
        @ViewBuilder
        private func modelDetail(for mode: EditorMode) -> some View {
            switch mode {
            case .create:
                LLMEditView(
                    mode: .add,
                    onSave: { newModel in
                        containerStore.saveLLMModel(newModel)
                        refreshModels()
                        selectedModelID = newModel.id
                        editorMode = .edit(newModel)
                    },
                    onCancel: {
                        editorMode = nil
                    },
                    presentationStyle: .embedded
                )
            case let .edit(model):
                LLMEditView(
                    mode: .edit(model),
                    onSave: { updatedModel in
                        containerStore.saveLLMModel(updatedModel)
                        refreshModels()
                        selectedModelID = updatedModel.id
                        editorMode = .edit(updatedModel)
                    },
                    onCancel: {
                        editorMode = nil
                    },
                    presentationStyle: .embedded
                )
                .id(model.id)
            }
        }
    #endif

    private func refreshModels() {
        let collection = containerStore.container.config.llmCollection
        models = collection.models
        selectedModelID = containerStore.container.config.selectedLLMModelID
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
            #if targetEnvironment(macCatalyst)
                Text(L10n.tr("settings.usage.navigationTitle"))
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .textCase(nil)
                    .listRowInsets(EdgeInsets(top: 16, leading: 16, bottom: 8, trailing: 16))
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)

                VStack(spacing: 12) {
                    HStack {
                        Text(L10n.tr("settings.usage.totalTokens"))
                        Spacer()
                        Text(formatUsageTokens(snapshot.totalTokens))
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                    if snapshot.totalCostUSD > 0 {
                        Divider()
                        HStack {
                            Text(L10n.tr("settings.usage.totalCost"))
                            Spacer()
                            Text(formatUsageCost(snapshot.totalCostUSD))
                                .foregroundStyle(.secondary)
                                .monospacedDigit()
                        }
                    }
                    Divider()
                    Button(role: .destructive) {
                        showResetUsageConfirmation = true
                    } label: {
                        Text(L10n.tr("settings.usage.reset"))
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
                .background(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(Color(uiColor: .secondarySystemBackground))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(Color.primary.opacity(0.06), lineWidth: 0.6)
                )
                .listRowInsets(EdgeInsets(top: 6, leading: 16, bottom: 20, trailing: 16))
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
            #else
                Section {
                    HStack {
                        Text(L10n.tr("settings.usage.totalTokens"))
                        Spacer()
                        Text(formatUsageTokens(snapshot.totalTokens))
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                    if snapshot.totalCostUSD > 0 {
                        HStack {
                            Text(L10n.tr("settings.usage.totalCost"))
                            Spacer()
                            Text(formatUsageCost(snapshot.totalCostUSD))
                                .foregroundStyle(.secondary)
                                .monospacedDigit()
                        }
                    }
                    Button(role: .destructive) {
                        showResetUsageConfirmation = true
                    } label: {
                        Text(L10n.tr("settings.usage.reset"))
                    }
                } header: {
                    Text(L10n.tr("settings.usage.navigationTitle"))
                }
            #endif
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
        openEditor(for: model)
    }

    private func openEditor(for model: AppConfig.LLMModel) {
        #if targetEnvironment(macCatalyst)
            editorMode = .edit(model)
        #else
            editingModel = model
        #endif
    }

    private func deleteModel(_ model: AppConfig.LLMModel) {
        containerStore.deleteLLMModel(id: model.id)
        refreshModels()
        #if targetEnvironment(macCatalyst)
            if selectedModelID == model.id {
                editorMode = nil
            }
        #endif
        modelToDelete = nil
    }
}

// MARK: - Subviews

private struct EmptyModelsView: View {
    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "cpu")
                .font(.system(size: 32, weight: .light))
                .foregroundStyle(.secondary)
            Text(L10n.tr("settings.llmList.empty.title"))
                .font(.subheadline.weight(.semibold))
            Text(L10n.tr("settings.llmList.empty.message"))
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, minHeight: 120)
        .padding()
    }
}

private struct ModelRow: View {
    let model: AppConfig.LLMModel
    let isSelected: Bool

    @Environment(\.appContainerStore) private var containerStore

    private var usageRecord: ModelUsageRecord? {
        guard let key = model.model else { return nil }
        return containerStore.usageSnapshot.byModel[key]
    }

    private var metadataLine: Text {
        var text = Text(verbatim: model.provider) + Text(" / ") + Text(verbatim: model.model ?? L10n.tr("common.unknown"))

        if let record = usageRecord, record.totalTokens > 0 {
            text = text
                + usageMetricText("settings.usage.input", value: formatTokens(record.inputTokens))
                + usageMetricText("settings.usage.output", value: formatTokens(record.outputTokens))

            if record.cacheReadTokens > 0 {
                text = text + usageMetricText("settings.usage.cacheRead", value: formatTokens(record.cacheReadTokens))
            }

            if record.cacheWriteTokens > 0 {
                text = text + usageMetricText("settings.usage.cacheWrite", value: formatTokens(record.cacheWriteTokens))
            }

            if record.costUSD > 0 {
                text = text + usageMetricText("settings.usage.cost", value: formatCost(record.costUSD))
            }
        }

        return text
    }

    var body: some View {
        HStack(spacing: 12) {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(isSelected ? Color.accentColor.opacity(0.18) : Color(uiColor: .quaternarySystemFill))
                .frame(width: 34, height: 34)
                .overlay(
                    Image(systemName: "cpu")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(isSelected ? Color.accentColor : .secondary)
                )

            VStack(alignment: .leading, spacing: 4) {
                Text(model.name)
                    .font(.headline)

                metadataLine
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            }

            Spacer()

            Image(systemName: model.isConfigured ? "checkmark.seal.fill" : "exclamationmark.triangle.fill")
                .foregroundStyle(model.isConfigured ? .green : .orange)
                .font(.caption)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(isSelected ? Color.accentColor.opacity(0.12) : Color(uiColor: .secondarySystemBackground))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(isSelected ? Color.accentColor.opacity(0.35) : Color.primary.opacity(0.06), lineWidth: 0.6)
        )
        .contentTransition(.opacity)
    }

    private func usageMetricText(_ key: String, value: String) -> Text {
        Text(" · ") + Text(L10n.tr(key)) + Text(" ") + Text(verbatim: value)
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

// MARK: - Preview

#Preview {
    NavigationStack {
        LLMListView()
            .environment(\.appContainerStore, AppContainerStore(container: .makeDefault()))
    }
}
