import ChatUI
import SwiftUI

/// List view for managing multiple LLM configurations
struct LLMListView: View {
    @Environment(\.appContainerStore) private var containerStore

    @State private var models: [AppConfig.LLMModel] = []
    @State private var isShowingAddSheet = false
    @State private var editingModel: AppConfig.LLMModel?
    @State private var modelToDelete: AppConfig.LLMModel?
    @State private var showResetUsageConfirmation = false

    @State private var envKeys: [LLMProvider: String] = [:]

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
                fetchEnvKeys()
            }
            .refreshable {
                refreshModels()
                fetchEnvKeys()
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

                    if !envKeys.isEmpty {
                        envKeysBanner
                            .padding(.horizontal, 16)
                    }

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

    private var modelsByProvider: [(String, [AppConfig.LLMModel])] {
        let grouped = Dictionary(grouping: models, by: { $0.provider })
        // Sort providers, putting custom last
        return grouped.sorted(by: {
            if $0.key == "openai-compatible" { return false }
            if $1.key == "openai-compatible" { return true }
            return $0.key < $1.key
        }).map { providerRaw, models in
            let displayName = LLMProvider(rawValue: providerRaw)?.displayName ?? providerRaw
            return (displayName, models)
        }
    }

    private var envKeysBanner: some View {
        HStack(spacing: 12) {
            Image(systemName: "terminal")
                .font(.system(size: 16))
                .foregroundStyle(Color(uiColor: ChatUIDesign.Color.brandOrange))

            VStack(alignment: .leading, spacing: 2) {
                Text(L10n.tr("settings.llmList.envDetected.title"))
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(Color(uiColor: ChatUIDesign.Color.offBlack))

                let providerNames = envKeys.keys.map { $0.displayName }.sorted().joined(separator: ", ")
                Text(L10n.tr("settings.llmList.envDetected.message", providerNames))
                    .font(.system(size: 12))
                    .foregroundStyle(Color(uiColor: ChatUIDesign.Color.black60))
            }

            Spacer()

            Button {
                applyEnvKeys()
            } label: {
                Text(L10n.tr("common.apply"))
                    .font(.system(size: 13, weight: .medium))
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(Color(uiColor: ChatUIDesign.Color.brandOrange))
                    .foregroundStyle(Color(uiColor: ChatUIDesign.Color.pureWhite))
                    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            }
            .buttonStyle(.plain)
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color(uiColor: ChatUIDesign.Color.brandOrange).opacity(0.05))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(Color(uiColor: ChatUIDesign.Color.brandOrange).opacity(0.15), lineWidth: 1)
        )
    }

    @ViewBuilder
    private var modelRows: some View {
        if models.isEmpty {
            EmptyModelsView {
                isShowingAddSheet = true
            }
        } else {
            ForEach(modelsByProvider, id: \.0) { providerName, providerModels in
                VStack(alignment: .leading, spacing: 8) {
                    Text(providerName)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Color(uiColor: ChatUIDesign.Color.black50))
                        .padding(.top, 8)
                        .padding(.bottom, 2)
                        .padding(.horizontal, 4)

                    ForEach(providerModels) { model in
                        ModelRow(
                            model: model,
                            usageRecord: usageRecord(for: model),
                            onEdit: { openEditor(for: model) },
                            onDelete: { modelToDelete = model }
                        )
                        .contentShape(Rectangle())
                        .opacity(model.isConfigured ? 1.0 : 0.6)
                        .onTapGesture {
                            openEditor(for: model)
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
        }
    }

    private func refreshModels() {
        let collection = containerStore.container.config.llmCollection
        models = collection.models
    }

    private func fetchEnvKeys() {
        #if targetEnvironment(macCatalyst) || os(macOS)
            DispatchQueue.global(qos: .userInitiated).async {
                let keys = EnvKeyFetcher.fetchCommonAPIKeys()
                DispatchQueue.main.async {
                    // Only keep keys that are not already configured in any model of that provider
                    var newEnvKeys: [LLMProvider: String] = [:]
                    let collection = self.containerStore.container.config.llmCollection

                    for (provider, key) in keys {
                        let hasConfiguredModel = collection.models.contains { m in
                            m.provider == provider.rawValue && m.apiKey != nil && !m.apiKey!.isEmpty
                        }
                        if !hasConfiguredModel {
                            newEnvKeys[provider] = key
                        }
                    }
                    self.envKeys = newEnvKeys
                }
            }
        #endif
    }

    private func applyEnvKeys() {
        var collection = containerStore.container.config.llmCollection
        var updated = false

        for (provider, apiKey) in envKeys {
            // Find all models for this provider
            var providerUpdated = false
            for i in 0 ..< collection.models.count {
                if collection.models[i].provider == provider.rawValue {
                    if collection.models[i].apiKey == nil || collection.models[i].apiKey!.isEmpty {
                        collection.models[i].apiKey = apiKey
                        providerUpdated = true
                        updated = true
                    }
                }
            }

            // If provider updated, sync keychain
            if providerUpdated {
                // Save any model of this provider to trigger keychain sync in store
                if let firstUpdated = collection.models.first(where: { $0.provider == provider.rawValue }) {
                    containerStore.saveLLMModel(firstUpdated)
                }
            }
        }

        if updated {
            refreshModels()
            envKeys.removeAll()
        }
    }

    private func usageRecord(for model: AppConfig.LLMModel) -> ModelUsageRecord? {
        guard let key = model.model else { return nil }
        return containerStore.usageSnapshot.byModel[key]
    }

    @ViewBuilder
    private var usageSummarySection: some View {
        let snapshot = containerStore.usageSnapshot
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

                TokenUsageHeatmapView(dailyUsage: snapshot.dailyUsage)
                    .padding(.vertical, 8)

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
    let usageRecord: ModelUsageRecord?
    let onEdit: () -> Void
    let onDelete: () -> Void

    @State private var isHovering = false

    var body: some View {
        HStack(alignment: .center, spacing: 16) {
            // Icon
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(model.isConfigured ? Color(uiColor: ChatUIDesign.Color.black80).opacity(0.05) : Color(uiColor: ChatUIDesign.Color.black80).opacity(0.02))
                .frame(width: 40, height: 40)
                .overlay(
                    Group {
                        if let providerType = LLMProvider(rawValue: model.provider) {
                            Image(providerType.iconName)
                                .resizable()
                                .scaledToFit()
                                .frame(width: 24, height: 24)
                                .opacity(model.isConfigured ? 1.0 : 0.4)
                                .grayscale(model.isConfigured ? 0 : 0.8)
                        } else {
                            Image(systemName: "cpu")
                                .font(.system(size: 16, weight: .medium))
                                .foregroundStyle(model.isConfigured ? Color(uiColor: ChatUIDesign.Color.black60) : Color(uiColor: ChatUIDesign.Color.black50))
                        }
                    }
                )

            // Info
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .center, spacing: 8) {
                    Text(model.name)
                        .font(.system(size: 16, weight: .medium))
                        .foregroundStyle(model.isConfigured ? Color(uiColor: ChatUIDesign.Color.offBlack) : Color(uiColor: ChatUIDesign.Color.black60))
                        .lineLimit(1)

                    if !model.isConfigured {
                        CompactTag(text: L10n.tr("settings.llmList.status.incomplete"))
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

            // Trailing actions
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
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color(uiColor: ChatUIDesign.Color.pureWhite))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(
                    Color(uiColor: ChatUIDesign.Color.oatBorder),
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

private struct CompactTag: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(Color(uiColor: ChatUIDesign.Color.black60))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Color(uiColor: ChatUIDesign.Color.black80).opacity(0.05))
            .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
    }
}

private struct TokenUsageHeatmapView: View {
    let dailyUsage: [String: Int]

    private let columns = 52
    private let rows = 7

    // Start week on Monday or Sunday? GitHub usually starts on Sunday. Let's assume Sunday (index 0).
    // Or we can use Calendar's firstWeekday.

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ScrollView(.horizontal, showsIndicators: false) {
                ScrollViewReader { proxy in
                    HStack(alignment: .top, spacing: 4) {
                        // Weekday labels
                        VStack(alignment: .trailing, spacing: 4) {
                            Text("").frame(height: 12) // Top row for months
                            ForEach(0 ..< rows, id: \.self) { row in
                                if row == 1 {
                                    Text("Mon").font(.system(size: 10)).foregroundStyle(Color(uiColor: ChatUIDesign.Color.black50)).frame(height: 12)
                                } else if row == 3 {
                                    Text("Wed").font(.system(size: 10)).foregroundStyle(Color(uiColor: ChatUIDesign.Color.black50)).frame(height: 12)
                                } else if row == 5 {
                                    Text("Fri").font(.system(size: 10)).foregroundStyle(Color(uiColor: ChatUIDesign.Color.black50)).frame(height: 12)
                                } else {
                                    Text("").frame(height: 12)
                                }
                            }
                        }

                        // Grid
                        HStack(spacing: 4) {
                            ForEach(0 ..< columns, id: \.self) { col in
                                VStack(spacing: 4) {
                                    // Month label
                                    if isFirstWeekOfMonth(col: col) {
                                        Color.clear
                                            .frame(width: 12, height: 12)
                                            .overlay(
                                                Text(monthName(for: col))
                                                    .font(.system(size: 10))
                                                    .foregroundStyle(Color(uiColor: ChatUIDesign.Color.black50))
                                                    .fixedSize(),
                                                alignment: .leading
                                            )
                                    } else {
                                        Text("").frame(height: 12)
                                    }

                                    // Days
                                    ForEach(0 ..< rows, id: \.self) { row in
                                        if let date = dateFor(col: col, row: row), date <= Date() {
                                            let tokens = dailyUsage[dateFormatter.string(from: date)] ?? 0
                                            RoundedRectangle(cornerRadius: 2)
                                                .fill(colorFor(tokens: tokens))
                                                .frame(width: 12, height: 12)
                                        } else {
                                            Color.clear.frame(width: 12, height: 12)
                                        }
                                    }
                                }
                                .id(col)
                            }
                        }
                    }
                    .padding(.vertical, 8)
                    .padding(.horizontal, 4)
                    .onAppear {
                        proxy.scrollTo(columns - 1, anchor: .trailing)
                    }
                }
            }

            // Legend
            HStack {
                Spacer()
                HStack(spacing: 10) {
                    legendItem(color: colorEmpty, label: "0")
                    legendItem(color: colorLevel1, label: "<10⁵")
                    legendItem(color: colorLevel2, label: "<10⁶")
                    legendItem(color: colorLevel3, label: "<10⁷")
                    legendItem(color: colorLevel4, label: "<10⁸")
                    legendItem(color: colorLevel5, label: "<10⁹")
                    legendItem(color: colorLevel6, label: "10⁹+")
                }
            }
            .padding(.top, 4)
        }
    }

    private func legendItem(color: Color, label: String) -> some View {
        HStack(spacing: 4) {
            RoundedRectangle(cornerRadius: 2).fill(color).frame(width: 12, height: 12)
            Text(label)
                .font(.system(size: 10))
                .foregroundStyle(Color(uiColor: ChatUIDesign.Color.black50))
        }
    }

    private let calendar = Calendar.current
    private let dateFormatter: DateFormatter = {
        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd"
        return df
    }()

    private func dateFor(col: Int, row: Int) -> Date? {
        let today = Date()
        let currentWeekday = calendar.component(.weekday, from: today) // 1=Sun, 7=Sat

        let daysToSubtract = (columns - 1 - col) * 7 + (currentWeekday - 1 - row)
        // If it's the future in the current week, return nil
        if daysToSubtract < 0 {
            return nil
        }
        return calendar.date(byAdding: .day, value: -daysToSubtract, to: today)
    }

    private func isFirstWeekOfMonth(col: Int) -> Bool {
        guard let sun = dateFor(col: col, row: 0) else { return false }
        let day = calendar.component(.day, from: sun)
        return day <= 7
    }

    private func monthName(for col: Int) -> String {
        guard let sun = dateFor(col: col, row: 0) else { return "" }
        let f = DateFormatter()
        f.dateFormat = "MMM"
        return f.string(from: sun)
    }

    private var colorEmpty: Color {
        Color(uiColor: ChatUIDesign.Color.oatBorder).opacity(0.45)
    }

    private var colorLevel1: Color {
        Color(uiColor: ChatUIDesign.Color.warmSand).opacity(0.45)
    }

    private var colorLevel2: Color {
        Color(uiColor: ChatUIDesign.Color.reportOrange).opacity(0.18)
    }

    private var colorLevel3: Color {
        Color(uiColor: ChatUIDesign.Color.reportOrange).opacity(0.36)
    }

    private var colorLevel4: Color {
        Color(uiColor: ChatUIDesign.Color.reportOrange).opacity(0.62)
    }

    private var colorLevel5: Color {
        Color(uiColor: ChatUIDesign.Color.reportOrange).opacity(0.82)
    }

    private var colorLevel6: Color {
        Color(uiColor: ChatUIDesign.Color.reportOrange)
    }

    private func colorFor(tokens: Int) -> Color {
        if tokens == 0 {
            return colorEmpty
        }

        switch tokens {
        case ..<100_000:
            return colorLevel1
        case ..<1_000_000:
            return colorLevel2
        case ..<10_000_000:
            return colorLevel3
        case ..<100_000_000:
            return colorLevel4
        case ..<1_000_000_000:
            return colorLevel5
        default:
            return colorLevel6
        }
    }
}
