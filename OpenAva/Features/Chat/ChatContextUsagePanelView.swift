import ChatClient
import ChatUI
import SwiftUI

struct ChatContextUsagePanelView: View {
    let snapshot: ContextUsageSnapshot
    let modelName: String
    let providerName: String?
    let onClose: () -> Void
    let onManualCompact: () -> Void

    var body: some View {
        ZStack {
            Color(uiColor: ChatUIDesign.Color.warmCream)
                .ignoresSafeArea()

            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 10) {
                    header
                    overviewCard
                    categoriesCard

                    if !snapshot.systemPromptSections.isEmpty {
                        systemPromptSectionsCard
                    }

                    if !snapshot.systemTools.isEmpty {
                        systemToolsCard
                    }

                    if let messageBreakdown = snapshot.messageBreakdown {
                        messageBreakdownCard(messageBreakdown)
                    }

                    if let lastUsage = snapshot.lastUsage {
                        lastUsageCard(lastUsage)
                    }

                    if let lastCompaction = snapshot.lastCompaction {
                        lastCompactionCard(lastCompaction)
                    }
                }
                .padding(12)
            }
        }
        .frame(minWidth: 340, idealWidth: 380, maxWidth: 420, idealHeight: 440, maxHeight: .infinity)
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(L10n.tr("chat.contextUsage.title"))
                    .font(.system(size: 15, weight: .regular))
                    .tracking(-0.2)
                    .foregroundStyle(Color(uiColor: ChatUIDesign.Color.offBlack))

                Text(formattedModelName)
                    .font(.system(size: 10, weight: .regular))
                    .foregroundStyle(Color(uiColor: ChatUIDesign.Color.black60))
            }

            Spacer(minLength: 8)

            HStack(spacing: 8) {
                Button(action: onManualCompact) {
                    Label(L10n.tr("chat.contextUsage.manualCompact"), systemImage: "rectangle.compress.vertical")
                        .font(.system(size: 9, weight: .medium))
                        .foregroundStyle(Color(uiColor: ChatUIDesign.Color.offBlack))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .frame(height: 24)
                        .overlay(
                            RoundedRectangle(cornerRadius: ChatUIDesign.Radius.button, style: .continuous)
                                .stroke(Color(uiColor: ChatUIDesign.Color.oatBorder), lineWidth: 1)
                        )
                }
                .buttonStyle(.plain)

                Button(action: onClose) {
                    Image(systemName: "xmark")
                        .font(.system(size: 9, weight: .medium))
                        .foregroundStyle(Color(uiColor: ChatUIDesign.Color.offBlack))
                        .frame(width: 24, height: 24)
                        .overlay(
                            RoundedRectangle(cornerRadius: ChatUIDesign.Radius.button, style: .continuous)
                                .stroke(Color(uiColor: ChatUIDesign.Color.oatBorder), lineWidth: 1)
                        )
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.bottom, 0)
    }

    private var overviewCard: some View {
        ContextCard(title: L10n.tr("chat.contextUsage.overview")) {
            VStack(spacing: 0) {
                progressBar
                    .padding(.bottom, 10)

                PanelRow(title: L10n.tr("chat.contextUsage.tokens"), value: "\(format(snapshot.estimatedInputTokens)) / \(format(snapshot.contextWindowTokens)) (\(snapshot.usedPercentage)%)")
                PanelDivider()
                PanelRow(title: L10n.tr("chat.contextUsage.remaining"), value: "\(format(snapshot.remainingTokens)) (\(snapshot.remainingPercentage)%)")
                PanelDivider()
                PanelRow(title: L10n.tr("chat.contextUsage.autoCompactTrigger"), value: format(snapshot.autoCompactTriggerTokens))
                PanelDivider()
                PanelRow(title: L10n.tr("chat.contextUsage.blockingLimit"), value: format(snapshot.blockingLimitTokens))
                PanelDivider()
                PanelRow(title: L10n.tr("chat.contextUsage.compactReserve"), value: format(snapshot.compactOutputReserveTokens))
                PanelDivider()
                PanelRow(title: L10n.tr("chat.contextUsage.autoCompact"), value: snapshot.isAutoCompactEnabled ? L10n.tr("settings.skills.enabled") : L10n.tr("settings.skills.disabled"))
            }
        }
    }

    private var categoriesCard: some View {
        ContextCard(title: L10n.tr("chat.contextUsage.categories")) {
            VStack(spacing: 10) {
                ForEach(snapshot.categories, id: \.kind) { category in
                    BreakdownRow(
                        title: categoryTitle(category),
                        subtitle: categorySubtitle(category),
                        value: category.tokens,
                        total: max(snapshot.contextWindowTokens, 1),
                        tintColor: categoryTintColor(category)
                    )
                }
            }
        }
    }

    private var systemPromptSectionsCard: some View {
        ContextCard(title: L10n.tr("chat.contextUsage.systemPromptSections")) {
            VStack(spacing: 0) {
                ForEach(Array(snapshot.systemPromptSections.enumerated()), id: \.offset) { index, section in
                    if index > 0 {
                        PanelDivider()
                    }
                    PanelRow(title: section.name, value: format(section.tokens))
                }
            }
        }
    }

    private var systemToolsCard: some View {
        ContextCard(title: L10n.tr("chat.contextUsage.systemTools")) {
            VStack(spacing: 0) {
                ForEach(Array(snapshot.systemTools.enumerated()), id: \.offset) { index, tool in
                    if index > 0 {
                        PanelDivider()
                    }
                    PanelRow(title: tool.name, value: format(tool.tokens))
                }
            }
        }
    }

    private func messageBreakdownCard(_ breakdown: ContextUsageSnapshot.MessageBreakdown) -> some View {
        ContextCard(title: L10n.tr("chat.contextUsage.messageBreakdown")) {
            VStack(spacing: 0) {
                PanelRow(title: L10n.tr("chat.contextUsage.userMessages"), value: format(breakdown.userMessageTokens))
                PanelDivider()
                PanelRow(title: L10n.tr("chat.contextUsage.assistantMessages"), value: format(breakdown.assistantMessageTokens))
                PanelDivider()
                PanelRow(title: L10n.tr("chat.contextUsage.attachments"), value: format(breakdown.attachmentTokens))
                PanelDivider()
                PanelRow(title: L10n.tr("chat.contextUsage.toolCalls"), value: format(breakdown.toolCallTokens))
                PanelDivider()
                PanelRow(title: L10n.tr("chat.contextUsage.toolResults"), value: format(breakdown.toolResultTokens))

                if !breakdown.attachmentsByType.isEmpty {
                    PanelDivider()
                    DetailSectionHeader(title: L10n.tr("chat.contextUsage.attachmentsByType"))
                    ForEach(Array(breakdown.attachmentsByType.enumerated()), id: \.offset) { index, detail in
                        if index > 0 {
                            PanelDivider()
                        }
                        PanelRow(title: detail.name, value: format(detail.tokens))
                    }
                }

                if !breakdown.toolCallsByType.isEmpty {
                    PanelDivider()
                    DetailSectionHeader(title: L10n.tr("chat.contextUsage.toolCallsByType"))
                    ForEach(Array(breakdown.toolCallsByType.enumerated()), id: \.offset) { index, detail in
                        if index > 0 {
                            PanelDivider()
                        }
                        PanelRow(
                            title: detail.name,
                            value: String(
                                format: L10n.tr("chat.contextUsage.callsAndResults"),
                                format(detail.callTokens),
                                format(detail.resultTokens)
                            )
                        )
                    }
                }
            }
        }
    }

    private func lastUsageCard(_ lastUsage: TokenUsage) -> some View {
        ContextCard(title: L10n.tr("chat.contextUsage.lastUsage")) {
            VStack(spacing: 0) {
                PanelRow(title: L10n.tr("chat.contextUsage.inputTokens"), value: format(lastUsage.inputTokens))
                PanelDivider()
                PanelRow(title: L10n.tr("chat.contextUsage.outputTokens"), value: format(lastUsage.outputTokens))
                PanelDivider()
                PanelRow(title: L10n.tr("chat.contextUsage.totalTokens"), value: format(lastUsage.totalTokens))
            }
        }
    }

    private func lastCompactionCard(_ lastCompaction: ContextUsageSnapshot.LastCompaction) -> some View {
        ContextCard(title: L10n.tr("chat.contextUsage.lastCompaction")) {
            VStack(spacing: 0) {
                PanelRow(title: L10n.tr("chat.contextUsage.trigger"), value: compactionTriggerText(lastCompaction.trigger))
                PanelDivider()
                PanelRow(title: L10n.tr("chat.contextUsage.preTokens"), value: format(lastCompaction.preTokens))
                if let messagesSummarized = lastCompaction.messagesSummarized {
                    PanelDivider()
                    PanelRow(title: L10n.tr("chat.contextUsage.messagesSummarized"), value: format(messagesSummarized))
                }
            }
        }
    }

    private var progressBar: some View {
        GeometryReader { proxy in
            let width = max(0, proxy.size.width)
            let fillWidth = width * progressValue
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .fill(Color(uiColor: ChatUIDesign.Color.oatBorder))
                    .frame(height: 6)
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .fill(accentColor)
                    .frame(width: fillWidth, height: 6)
            }
        }
        .frame(height: 6)
    }

    private var formattedModelName: String {
        let trimmedModel = modelName.trimmingCharacters(in: .whitespacesAndNewlines)
        let resolvedModel = trimmedModel.isEmpty ? "-" : trimmedModel
        guard let providerName, !providerName.isEmpty else { return resolvedModel }
        return "\(resolvedModel) · \(providerName)"
    }

    private var progressValue: Double {
        guard snapshot.contextWindowTokens > 0 else { return 0 }
        return min(1, max(0, Double(snapshot.estimatedInputTokens) / Double(snapshot.contextWindowTokens)))
    }

    private var accentColor: Color {
        if snapshot.isAtBlockingLimit || snapshot.isAboveErrorThreshold {
            return Color(uiColor: ChatUIDesign.Color.brandOrange)
        }
        if snapshot.isAboveWarningThreshold || snapshot.usedPercentage >= 80 {
            return Color(uiColor: ChatUIDesign.Color.brandOrange)
        }
        return Color(uiColor: ChatUIDesign.Color.offBlack)
    }

    private func categoryTitle(_ category: ContextUsageSnapshot.Category) -> String {
        switch category.kind {
        case .systemPrompt:
            L10n.tr("chat.contextUsage.category.systemPrompt")
        case .tools:
            L10n.tr("chat.contextUsage.category.tools")
        case .messages:
            L10n.tr("chat.contextUsage.category.messages")
        case .autoCompactBuffer:
            L10n.tr("chat.contextUsage.category.autoCompactBuffer")
        case .compactBuffer:
            L10n.tr("chat.contextUsage.category.compactBuffer")
        case .freeSpace:
            L10n.tr("chat.contextUsage.category.freeSpace")
        }
    }

    private func categorySubtitle(_ category: ContextUsageSnapshot.Category) -> String? {
        switch category.kind {
        case .systemPrompt:
            guard let entryCount = category.entryCount else { return nil }
            return L10n.tr("chat.contextUsage.systemPromptMessagesCount", entryCount)
        case .tools:
            guard let entryCount = category.entryCount else { return nil }
            return L10n.tr("chat.contextUsage.toolsCount", entryCount)
        case .messages:
            guard let breakdown = category.messageBreakdown else { return nil }
            return L10n.tr(
                "chat.contextUsage.messagesMessageMix",
                breakdown.userMessageCount,
                breakdown.assistantMessageCount,
                breakdown.toolMessageCount
            )
        case .autoCompactBuffer, .compactBuffer, .freeSpace:
            return nil
        }
    }

    private func categoryTintColor(_ category: ContextUsageSnapshot.Category) -> Color {
        switch category.kind {
        case .systemPrompt:
            return Color(uiColor: ChatUIDesign.Color.offBlack).opacity(0.85)
        case .tools:
            return Color(uiColor: ChatUIDesign.Color.black80)
        case .messages:
            return Color(uiColor: ChatUIDesign.Color.offBlack)
        case .autoCompactBuffer, .compactBuffer:
            return Color(uiColor: ChatUIDesign.Color.black60)
        case .freeSpace:
            return Color(uiColor: ChatUIDesign.Color.oatBorder)
        }
    }

    private func format(_ value: Int) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        return formatter.string(from: NSNumber(value: value)) ?? "\(value)"
    }

    private func compactionTriggerText(_ trigger: String) -> String {
        switch trigger {
        case "manual":
            L10n.tr("chat.contextUsage.trigger.manual")
        case "auto":
            L10n.tr("chat.contextUsage.trigger.auto")
        default:
            trigger
        }
    }
}

private struct ContextCard<Content: View>: View {
    let title: String?
    @ViewBuilder var content: Content

    init(title: String? = nil, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let title, !title.isEmpty {
                Text(title)
                    .font(.system(size: 9, weight: .semibold))
                    .tracking(0.6)
                    .foregroundStyle(Color(uiColor: ChatUIDesign.Color.black60))
                    .textCase(.uppercase)
            }

            content
        }
        .padding(12)
        .background(Color(uiColor: ChatUIDesign.Color.warmCream))
        .overlay(
            RoundedRectangle(cornerRadius: ChatUIDesign.Radius.card, style: .continuous)
                .stroke(Color(uiColor: ChatUIDesign.Color.oatBorder), lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: ChatUIDesign.Radius.card, style: .continuous))
    }
}

private struct PanelRow: View {
    let title: String
    let value: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(title)
                .font(.system(size: 11, weight: .regular))
                .foregroundStyle(Color(uiColor: ChatUIDesign.Color.offBlack))
            Spacer(minLength: 8)
            Text(value)
                .font(.system(size: 12, weight: .medium, design: .rounded))
                .foregroundStyle(Color(uiColor: ChatUIDesign.Color.black80))
                .multilineTextAlignment(.trailing)
                .monospacedDigit()
        }
        .padding(.vertical, 6)
    }
}

private struct BreakdownRow: View {
    let title: String
    let subtitle: String?
    let value: Int
    let total: Int
    let tintColor: Color

    private var progressValue: Double {
        guard total > 0 else { return 0 }
        return min(1, max(0, Double(value) / Double(total)))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.system(size: 11, weight: .regular))
                        .foregroundStyle(Color(uiColor: ChatUIDesign.Color.offBlack))
                    if let subtitle, !subtitle.isEmpty {
                        Text(subtitle)
                            .font(.system(size: 9, weight: .regular))
                            .foregroundStyle(Color(uiColor: ChatUIDesign.Color.black60))
                    }
                }

                Spacer(minLength: 8)

                VStack(alignment: .trailing, spacing: 2) {
                    Text(Self.format(value))
                        .font(.system(size: 12, weight: .medium, design: .rounded))
                        .foregroundStyle(Color(uiColor: ChatUIDesign.Color.offBlack))
                        .monospacedDigit()
                    Text(Self.percent(value: value, total: total))
                        .font(.system(size: 9, weight: .regular))
                        .foregroundStyle(Color(uiColor: ChatUIDesign.Color.black60))
                }
            }

            GeometryReader { proxy in
                let width = max(0, proxy.size.width)
                RoundedRectangle(cornerRadius: 3, style: .continuous)
                    .fill(Color(uiColor: ChatUIDesign.Color.oatBorder))
                    .overlay(alignment: .leading) {
                        RoundedRectangle(cornerRadius: 3, style: .continuous)
                            .fill(tintColor)
                            .frame(width: width * progressValue)
                    }
            }
            .frame(height: 5)
        }
    }

    private static func format(_ value: Int) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        return formatter.string(from: NSNumber(value: value)) ?? "\(value)"
    }

    private static func percent(value: Int, total: Int) -> String {
        guard total > 0 else { return "0%" }
        return String(format: "%.1f%%", Double(value) / Double(total) * 100)
    }
}

private struct PanelDivider: View {
    var body: some View {
        Rectangle()
            .fill(Color(uiColor: ChatUIDesign.Color.oatBorder))
            .frame(height: 1)
    }
}

private struct DetailSectionHeader: View {
    let title: String

    var body: some View {
        HStack {
            Text(title)
                .font(.system(size: 9, weight: .semibold))
                .tracking(0.3)
                .foregroundStyle(Color(uiColor: ChatUIDesign.Color.black60))
                .textCase(.uppercase)
            Spacer(minLength: 0)
        }
        .padding(.vertical, 8)
    }
}
