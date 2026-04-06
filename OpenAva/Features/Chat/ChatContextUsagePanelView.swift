import ChatClient
import ChatUI
import SwiftUI

struct ChatContextUsagePanelView: View {
    let snapshot: ContextUsageSnapshot
    let modelName: String
    let providerName: String?
    let onClose: () -> Void

    var body: some View {
        ZStack {
            Color(uiColor: .systemBackground)
                .ignoresSafeArea()

            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 12) {
                    header
                    summaryCard
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
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(L10n.tr("chat.contextUsage.title"))
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(.primary)

                Text(L10n.tr("chat.contextUsage.usedRemaining", snapshot.usedPercentage, snapshot.remainingPercentage))
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 8)

            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.primary)
                    .frame(width: 28, height: 28)
                    .background(pillBackground)
                    .overlay(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .stroke(pillBorder, lineWidth: 1)
                    )
            }
            .buttonStyle(.plain)
        }
    }

    private var summaryCard: some View {
        ContextCard {
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .center, spacing: 12) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(accentFill)
                            .frame(width: 36, height: 36)
                        Image(systemName: "gauge.with.dots.needle.50percent")
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundStyle(accentColor)
                    }

                    VStack(alignment: .leading, spacing: 2) {
                        Text(formattedModelName)
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(.primary)
                            .lineLimit(1)
                        Text(L10n.tr("chat.contextUsage.tokens"))
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(.secondary)
                    }

                    Spacer(minLength: 8)

                    Text("\(snapshot.usedPercentage)%")
                        .font(.system(size: 34, weight: .bold, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(.primary)
                }

                progressBar

                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 8) {
                        MetaPill(icon: "cpu", text: formattedModelName)
                        MetaPill(
                            icon: snapshot.autoCompactEnabled ? "rectangle.compress.vertical" : "rectangle.compress.vertical.badge.minus",
                            text: snapshot.autoCompactEnabled ? L10n.tr("settings.skills.enabled") : L10n.tr("settings.skills.disabled")
                        )
                    }

                    VStack(alignment: .leading, spacing: 8) {
                        MetaPill(icon: "cpu", text: formattedModelName)
                        MetaPill(
                            icon: snapshot.autoCompactEnabled ? "rectangle.compress.vertical" : "rectangle.compress.vertical.badge.minus",
                            text: snapshot.autoCompactEnabled ? L10n.tr("settings.skills.enabled") : L10n.tr("settings.skills.disabled")
                        )
                    }
                }

                LazyVGrid(
                    columns: [GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8)],
                    spacing: 8
                ) {
                    MetricTile(title: L10n.tr("chat.contextUsage.tokens"), value: compactFormat(snapshot.estimatedInputTokens))
                    MetricTile(title: L10n.tr("chat.contextUsage.remaining"), value: compactFormat(snapshot.remainingTokens))
                    MetricTile(title: L10n.tr("chat.contextUsage.threshold"), value: "80%")
                    MetricTile(title: L10n.tr("chat.contextUsage.responseHeadroom"), value: compactFormat(snapshot.responseHeadroomTokens))
                }
            }
        }
    }

    private var overviewCard: some View {
        ContextCard(title: L10n.tr("chat.contextUsage.overview")) {
            VStack(spacing: 0) {
                PanelRow(title: L10n.tr("chat.contextUsage.tokens"), value: "\(format(snapshot.estimatedInputTokens)) / \(format(snapshot.contextLength))")
                PanelDivider()
                PanelRow(title: L10n.tr("chat.contextUsage.remaining"), value: "\(format(snapshot.remainingTokens)) (\(snapshot.remainingPercentage)%)")
                PanelDivider()
                PanelRow(title: L10n.tr("chat.contextUsage.autoCompact"), value: snapshot.autoCompactEnabled ? L10n.tr("settings.skills.enabled") : L10n.tr("settings.skills.disabled"))
                PanelDivider()
                PanelRow(title: L10n.tr("chat.contextUsage.threshold"), value: "\(format(snapshot.autoCompactThresholdTokens)) (80%)")
                PanelDivider()
                PanelRow(title: L10n.tr("chat.contextUsage.trimLimit"), value: format(snapshot.trimLimitTokens))
                PanelDivider()
                PanelRow(title: L10n.tr("chat.contextUsage.responseHeadroom"), value: format(snapshot.responseHeadroomTokens))
            }
        }
    }

    private var breakdownCard: some View {
        ContextCard(title: L10n.tr("chat.contextUsage.breakdown")) {
            VStack(spacing: 10) {
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
            HStack(spacing: 8) {
                MetricTile(title: L10n.tr("chat.contextUsage.inputTokens"), value: compactFormat(lastUsage.inputTokens))
                MetricTile(title: L10n.tr("chat.contextUsage.outputTokens"), value: compactFormat(lastUsage.outputTokens))
                MetricTile(title: L10n.tr("chat.contextUsage.totalTokens"), value: compactFormat(lastUsage.totalTokens))
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
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(trackColor)
                    .frame(height: 10)
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(progressTint)
                    .frame(width: fillWidth, height: 10)
            }
        }
        .frame(height: 10)
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
        switch snapshot.usedPercentage {
        case 80...:
            Color.orange
        case 60...:
            Color.yellow
        default:
            Color.accentColor
        }
    }

    private var progressTint: LinearGradient {
        LinearGradient(
            colors: [accentColor.opacity(0.82), accentColor],
            startPoint: .leading,
            endPoint: .trailing
        )
    }

    private var accentFill: Color {
        accentColor.opacity(0.14)
    }

    private var trackColor: Color {
        Color(uiColor: UIColor.label.withAlphaComponent(0.08))
    }

    private var pillBackground: Color {
        Color.clear
    }

    private var pillBorder: Color {
        Color(uiColor: UIColor.label.withAlphaComponent(0.10))
    }

    private func compactFormat(_ value: Int) -> String {
        if value >= 1_000_000 {
            return String(format: "%.1fM", Double(value) / 1_000_000)
        }
        if value >= 1000 {
            return String(format: "%.1fK", Double(value) / 1000)
        }
        return format(value)
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
        VStack(alignment: .leading, spacing: 10) {
            if let title, !title.isEmpty {
                Text(title)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .textCase(.uppercase)
            }

            content
        }
        .padding(14)
        .background(cardBackground)
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(cardBorder, lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private var cardBackground: some ShapeStyle {
        Color(uiColor: UIColor { trait in
            if trait.userInterfaceStyle == .dark {
                return UIColor(red: 0.10, green: 0.11, blue: 0.14, alpha: 0.86)
            }
            return UIColor(red: 0.97, green: 0.98, blue: 0.995, alpha: 0.98)
        })
    }

    private var cardBorder: Color {
        Color(uiColor: UIColor.separator).opacity(0.42)
    }
}

private struct MetaPill: View {
    let icon: String
    let text: String

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: icon)
                .font(.system(size: 11, weight: .semibold))
            Text(text)
                .font(.system(size: 12, weight: .semibold))
                .lineLimit(1)
        }
        .foregroundStyle(.primary)
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(Color.clear)
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(Color(uiColor: UIColor.label.withAlphaComponent(0.10)), lineWidth: 1)
        )
    }
}

private struct MetricTile: View {
    let title: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Text(value)
                .font(.system(size: 16, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(.primary)
                .lineLimit(1)
                .minimumScaleFactor(0.85)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(Color(uiColor: UIColor.label.withAlphaComponent(0.035)))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(Color(uiColor: UIColor.label.withAlphaComponent(0.08)), lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}

private struct PanelRow: View {
    let title: String
    let value: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(title)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(.primary)
            Spacer(minLength: 12)
            Text(value)
                .font(.system(size: 14, weight: .semibold, design: .rounded))
                .foregroundStyle(.secondary)
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
                VStack(alignment: .leading, spacing: 3) {
                    Text(title)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(.primary)
                    Text(subtitle)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.secondary)
                }

                Spacer(minLength: 8)

                VStack(alignment: .trailing, spacing: 2) {
                    Text(Self.format(value))
                        .font(.system(size: 15, weight: .semibold, design: .rounded))
                        .foregroundStyle(.primary)
                        .monospacedDigit()
                    Text(Self.percent(value: value, total: total))
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.secondary)
                }
            }

            GeometryReader { proxy in
                let width = max(0, proxy.size.width)
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(Color(uiColor: UIColor.label.withAlphaComponent(0.08)))
                    .overlay(alignment: .leading) {
                        RoundedRectangle(cornerRadius: 5, style: .continuous)
                            .fill(Color.accentColor.opacity(0.88))
                            .frame(width: width * progressValue)
                    }
            }
            .frame(height: 8)
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
            .fill(Color(uiColor: UIColor.label.withAlphaComponent(0.08)))
            .frame(height: 1)
    }
}
