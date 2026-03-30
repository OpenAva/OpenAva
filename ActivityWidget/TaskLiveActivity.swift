import ActivityKit
import SwiftUI
import WidgetKit

struct TaskLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: TaskActivityAttributes.self) { context in
            lockScreenView(context: context)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Text(context.state.agentEmoji)
                        .font(.title2)
                        .padding(.leading, 4)
                }
                DynamicIslandExpandedRegion(.center) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(context.state.agentName)
                            .font(.headline)
                            .lineLimit(1)
                        Text(context.state.statusMessage)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                DynamicIslandExpandedRegion(.trailing) {
                    if !context.state.isCompleted {
                        Text(timerInterval: context.state.startedAt ... Date.distantFuture, countsDown: false)
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: 60)
                            .padding(.trailing, 4)
                    }
                }
            } compactLeading: {
                Text(context.state.agentEmoji)
            } compactTrailing: {
                if !context.state.isCompleted {
                    Text(timerInterval: context.state.startedAt ... Date.distantFuture, countsDown: false)
                        .font(.caption2.monospacedDigit())
                        .frame(maxWidth: 44)
                }
            } minimal: {
                Text(context.state.agentEmoji)
            }
        }
    }

    private func lockScreenView(context: ActivityViewContext<TaskActivityAttributes>) -> some View {
        HStack(spacing: 12) {
            Text(context.state.agentEmoji)
                .font(.title)

            VStack(alignment: .leading, spacing: 2) {
                Text(context.state.agentName)
                    .font(.subheadline.bold())
                    .lineLimit(1)
                Text(context.state.statusMessage)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer()

            if !context.state.isCompleted {
                Text(timerInterval: context.state.startedAt ... Date.distantFuture, countsDown: false)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        }
        .padding()
    }
}
