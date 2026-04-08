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
                VStack(alignment: .leading, spacing: 16) {
                    header
                    overviewCard
                    breakdownCard

                    if let lastUsage = snapshot.lastUsage {
                        lastUsageCard(lastUsage)
                    }

                    if let lastCompaction = snapshot.lastCompaction {
                        lastCompactionCard(lastCompaction)
                    }
                }
                .padding(16)
            }
        }
        .frame(minWidth: 340, idealWidth: 380, maxWidth: 420, idealHeight: 520, maxHeight: .infinity)
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(L10n.tr("chat.contextUsage.title"))
                    .font(.system(size: 18, weight: .regular))
                    .tracking(-0.2)
                    .foregroundStyle(Color(uiColor: ChatUIDesign.Color.offBlack))

                Text(formattedModelName)
                    .font(.system(size: 13, weight: .regular))
                    .foregroundStyle(Color(uiColor: ChatUIDesign.Color.black60))
            }

            Spacer(minLength: 8)

            HStack(spacing: 8) {
                Button(action: onManualCompact) {
                    Label(L10n.tr("chat.contextUsage.manualCompact"), systemImage: "rectangle.compress.vertical")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(Color(uiColor: ChatUIDesign.Color.offBlack))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .overlay(
                            RoundedRectangle(cornerRadius: ChatUIDesign.Radius.button, style: .continuous)
                                .stroke(Color(uiColor: ChatUIDesign.Color.oatBorder), lineWidth: 1)
                        )
                }
                .buttonStyle(.plain)

                Button(action: onClose) {
                    Image(systemName: "xmark")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(Color(uiColor: ChatUIDesign.Color.offBlack))
                        .frame(width: 28, height: 28)
                        .overlay(
                            RoundedRectangle(cornerRadius: ChatUIDesign.Radius.button, style: .continuous)
                                .stroke(Color(uiColor: ChatUIDesign.Color.oatBorder), lineWidth: 1)
                        )
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.bottom, 4)
    }

    private var overviewCard: some View {
        ContextCard(title: L10n.tr("chat.contextUsage.overview")) {
            VStack(spacing: 0) {
                progressBar
                    .padding(.bottom, 16)

                PanelRow(title: L10n.tr("chat.contextUsage.tokens"), value: "\(format(snapshot.estimatedInputTokens)) / \(format(snapshot.contextLength)) (\(snapshot.usedPercentage)%)")
                PanelDivider()
                PanelRow(title: L10n.tr("chat.contextUsage.remaining"), value: "\(format(snapshot.remainingTokens)) (\(snapshot.remainingPercentage)%)")
                PanelDivider()
                PanelRow(title: L10n.tr("chat.contextUsage.threshold"), value: "\(format(snapshot.autoCompactThresholdTokens)) (80%)")
                PanelDivider()
                PanelRow(title: L10n.tr("chat.contextUsage.trimLimit"), value: format(snapshot.trimLimitTokens))
                PanelDivider()
                PanelRow(title: L10n.tr("chat.contextUsage.responseHeadroom"), value: format(snapshot.responseHeadroomTokens))
                PanelDivider()
                PanelRow(title: L10n.tr("chat.contextUsage.autoCompact"), value: snapshot.autoCompactEnabled ? L10n.tr("settings.skills.enabled") : L10n.tr("settings.skills.disabled"))
            }
        }
    }

    private var breakdownCard: some View {
        ContextCard(title: L10n.tr("chat.contextUsage.breakdown")) {
            VStack(spacing: 16) {
                BreakdownRow(
                    title: L10n.tr("chat.contextUsage.instructions"),
                    subtitle: L10n.tr("chat.contextUsage.requestMessagesCount", snapshot.instructionMessageCount),
                    value: snapshot.instructionTokens,
                    total: max(snapshot.contextLength, 1)
                )
                BreakdownRow(
                    title: L10n.tr("chat.contextUsage.conversation"),
                    subtitle: L10n.tr(
                        "chat.contextUsage.conversationMessageMix",
                        snapshot.userMessageCount,
                        snapshot.assistantMessageCount,
                        snapshot.toolMessageCount
                    ),
                    value: snapshot.conversationTokens,
                    total: max(snapshot.contextLength, 1)
                )
                BreakdownRow(
                    title: L10n.tr("chat.contextUsage.toolDefinitions"),
                    subtitle: L10n.tr("chat.contextUsage.toolDefinitionsCount", snapshot.toolDefinitionCount),
                    value: snapshot.toolDefinitionTokens,
                    total: max(snapshot.contextLength, 1)
                )
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
                    .frame(height: 8)
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .fill(accentColor)
                    .frame(width: fillWidth, height: 8)
            }
        }
        .frame(height: 8)
    }

    private var formattedModelName: String {
        let trimmedModel = modelName.trimmingCharacters(in: .whitespacesAndNewlines)
        let resolvedModel = trimmedModel.isEmpty ? "-" : trimmedModel
        guard let providerName, !providerName.isEmpty else { return resolvedModel }
        return "\(resolvedModel) · \(providerName)"
    }

    private var progressValue: Double {
        guard snapshot.contextLength > 0 else { return 0 }
        return min(1, max(0, Double(snapshot.estimatedInputTokens) / Double(snapshot.contextLength)))
    }

    private var accentColor: Color {
        if snapshot.usedPercentage >= 80 {
            return Color(uiColor: ChatUIDesign.Color.brandOrange)
        }
        return Color(uiColor: ChatUIDesign.Color.offBlack)
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
        VStack(alignment: .leading, spacing: 12) {
            if let title, !title.isEmpty {
                Text(title)
                    .font(.system(size: 12, weight: .semibold))
                    .tracking(0.6)
                    .foregroundStyle(Color(uiColor: ChatUIDesign.Color.black60))
                    .textCase(.uppercase)
            }

            content
        }
        .padding(16)
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
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(title)
                .font(.system(size: 14, weight: .regular))
                .foregroundStyle(Color(uiColor: ChatUIDesign.Color.offBlack))
            Spacer(minLength: 12)
            Text(value)
                .font(.system(size: 14, weight: .medium, design: .rounded))
                .foregroundStyle(Color(uiColor: ChatUIDesign.Color.black80))
                .multilineTextAlignment(.trailing)
                .monospacedDigit()
        }
        .padding(.vertical, 10)
    }
}

private struct BreakdownRow: View {
    let title: String
    let subtitle: String
    let value: Int
    let total: Int

    private var progressValue: Double {
        guard total > 0 else { return 0 }
        return min(1, max(0, Double(value) / Double(total)))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.system(size: 14, weight: .regular))
                        .foregroundStyle(Color(uiColor: ChatUIDesign.Color.offBlack))
                    Text(subtitle)
                        .font(.system(size: 12, weight: .regular))
                        .foregroundStyle(Color(uiColor: ChatUIDesign.Color.black60))
                }

                Spacer(minLength: 8)

                VStack(alignment: .trailing, spacing: 2) {
                    Text(Self.format(value))
                        .font(.system(size: 14, weight: .medium, design: .rounded))
                        .foregroundStyle(Color(uiColor: ChatUIDesign.Color.offBlack))
                        .monospacedDigit()
                    Text(Self.percent(value: value, total: total))
                        .font(.system(size: 12, weight: .regular))
                        .foregroundStyle(Color(uiColor: ChatUIDesign.Color.black60))
                }
            }

            GeometryReader { proxy in
                let width = max(0, proxy.size.width)
                RoundedRectangle(cornerRadius: 3, style: .continuous)
                    .fill(Color(uiColor: ChatUIDesign.Color.oatBorder))
                    .overlay(alignment: .leading) {
                        RoundedRectangle(cornerRadius: 3, style: .continuous)
                            .fill(Color(uiColor: ChatUIDesign.Color.offBlack).opacity(0.8))
                            .frame(width: width * progressValue)
                    }
            }
            .frame(height: 6)
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
