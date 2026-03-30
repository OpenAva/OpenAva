import ActivityKit
import SwiftUI
import WidgetKit

struct CronLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: CronActivityAttributes.self) { context in
            lockScreenView(context: context)
        } dynamicIsland: { context in
            DynamicIsland {
                // Expanded view
                DynamicIslandExpandedRegion(.leading) {
                    scheduleIcon(scheduleType: context.state.scheduleType)
                }
                DynamicIslandExpandedRegion(.center) {
                    VStack(alignment: .center, spacing: 2) {
                        Text(context.state.jobName)
                            .font(.caption.bold())
                            .lineLimit(1)
                        if let nextDate = parseISODate(context.state.nextRunISO) {
                            Text(nextDate, style: .timer)
                                .font(.caption2)
                                .monospacedDigit()
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                DynamicIslandExpandedRegion(.trailing) {
                    if context.state.totalJobs > 1 {
                        Text("+\(context.state.totalJobs - 1)")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
            } compactLeading: {
                scheduleIcon(scheduleType: context.state.scheduleType)
                    .font(.caption2)
            } compactTrailing: {
                if let nextDate = parseISODate(context.state.nextRunISO) {
                    Text(nextDate, style: .timer)
                        .font(.caption2)
                        .monospacedDigit()
                }
            } minimal: {
                scheduleIcon(scheduleType: context.state.scheduleType)
                    .font(.caption2)
            }
        }
    }

    // MARK: - Lock Screen View

    private func lockScreenView(context: ActivityViewContext<CronActivityAttributes>) -> some View {
        HStack(spacing: 12) {
            // Left: Schedule icon
            scheduleIcon(scheduleType: context.state.scheduleType)
                .font(.title3)
                .foregroundStyle(context.state.isDueSoon ? .orange : .blue)
                .frame(width: 24)

            // Center: Job info
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(context.state.jobName)
                        .font(.subheadline.bold())
                        .lineLimit(1)

                    if context.state.totalJobs > 1 {
                        Text("+\(context.state.totalJobs - 1)")
                            .font(.caption2)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(.secondary.opacity(0.2), in: Capsule())
                    }
                }

                Text(context.state.message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)

                if let nextDate = parseISODate(context.state.nextRunISO) {
                    HStack(spacing: 4) {
                        Image(systemName: "clock")
                            .font(.caption2)
                        Text("Next: \(nextDate, style: .relative)")
                            .font(.caption2)
                    }
                    .foregroundStyle(context.state.isDueSoon ? .orange : .secondary)
                }
            }

            Spacer()
        }
        .padding(.vertical, 8)
    }

    // MARK: - Helper Views

    @ViewBuilder
    private func scheduleIcon(scheduleType: String) -> some View {
        switch scheduleType {
        case "at":
            Image(systemName: "calendar.badge.clock")
        case "every":
            Image(systemName: "arrow.clockwise")
        default:
            Image(systemName: "clock")
        }
    }

    // MARK: - Helpers

    private func parseISODate(_ isoString: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: isoString) {
            return date
        }
        // Try without fractional seconds
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: isoString)
    }
}
