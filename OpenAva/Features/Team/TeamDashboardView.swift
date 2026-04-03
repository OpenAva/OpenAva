import Foundation
import SwiftUI

struct TeamDashboardView: View {
    let snapshot: TeamSwarmCoordinator.TeamSnapshot
    let currentSessionKey: String?
    let onOpenConversation: (String) -> Void
    let onApprovePlan: (String) -> Void
    let onStopTeammate: (String) -> Void

    private var sortedMembers: [TeamSwarmCoordinator.TeamMember] {
        snapshot.team.members.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    private var pendingApprovals: Int {
        sortedMembers.filter(\.awaitingPlanApproval).count
    }

    private var runningMembers: Int {
        sortedMembers.filter { $0.status == .busy }.count
    }

    private var openTasks: Int {
        snapshot.team.tasks.filter { $0.status != .completed }.count
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Team · \(snapshot.team.name)")
                        .font(.headline)
                    if let description = snapshot.team.description, !description.isEmpty {
                        Text(description)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                }
                Spacer()
                HStack(spacing: 8) {
                    statBadge(title: "成员", value: "\(sortedMembers.count)")
                    statBadge(title: "执行中", value: "\(runningMembers)")
                    statBadge(title: "待批", value: "\(pendingApprovals)")
                    statBadge(title: "任务", value: "\(openTasks)")
                }
            }

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(alignment: .top, spacing: 10) {
                    ForEach(sortedMembers) { member in
                        VStack(alignment: .leading, spacing: 8) {
                            HStack {
                                Text(member.name)
                                    .font(.subheadline.weight(.semibold))
                                Spacer(minLength: 8)
                                Text(statusText(member.status))
                                    .font(.caption)
                                    .foregroundStyle(statusColor(member.status))
                            }

                            if let preview = member.lastMailboxPreview, !preview.isEmpty {
                                Text("Inbox: \(preview)")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(2)
                            } else if let idle = member.lastIdleSummary, !idle.isEmpty {
                                Text("Idle: \(idle)")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(2)
                            }

                            if let peer = member.lastPeerMessageSummary, !peer.isEmpty {
                                Text(peer)
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }

                            HStack(spacing: 6) {
                                Button(currentSessionKey == member.sessionID ? "当前会话" : "打开") {
                                    onOpenConversation(member.sessionID)
                                }
                                .buttonStyle(.bordered)
                                .disabled(currentSessionKey == member.sessionID)

                                if member.awaitingPlanApproval {
                                    Button("批准") {
                                        onApprovePlan(member.sessionID)
                                    }
                                    .buttonStyle(.borderedProminent)
                                }

                                Button("停止") {
                                    onStopTeammate(member.name)
                                }
                                .buttonStyle(.bordered)
                            }

                            if let queued = member.queuedMessageCount, queued > 0 {
                                Text("待处理消息 \(queued)")
                                    .font(.caption2)
                                    .foregroundStyle(.orange)
                            }
                        }
                        .padding(12)
                        .frame(width: 240, alignment: .leading)
                        .background(Color(uiColor: .secondarySystemBackground), in: RoundedRectangle(cornerRadius: 14))
                    }
                }
            }

            if !snapshot.team.tasks.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("共享任务")
                        .font(.subheadline.weight(.medium))
                    ForEach(snapshot.team.tasks.sorted { $0.id < $1.id }.prefix(4)) { task in
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Text("#\(task.id)")
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.secondary)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(task.title)
                                    .font(.footnote)
                                Text("\(task.status.rawValue) · \(task.owner ?? "unassigned")")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                        }
                    }
                }
            }
        }
        .padding(12)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 18))
        .padding(.horizontal)
        .padding(.top, 6)
    }

    private func statBadge(title: String, value: String) -> some View {
        VStack(spacing: 2) {
            Text(value)
                .font(.subheadline.weight(.semibold))
            Text(title)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(Color(uiColor: .secondarySystemBackground), in: Capsule())
    }

    private func statusText(_ status: TeamSwarmCoordinator.MemberStatus) -> String {
        switch status {
        case .idle:
            return "空闲"
        case .busy:
            return "执行中"
        case .awaitingPlanApproval:
            return "待批准"
        case .stopped:
            return "已停止"
        case .failed:
            return "失败"
        }
    }

    private func statusColor(_ status: TeamSwarmCoordinator.MemberStatus) -> Color {
        switch status {
        case .idle:
            return .green
        case .busy:
            return .blue
        case .awaitingPlanApproval:
            return .orange
        case .stopped:
            return .secondary
        case .failed:
            return .red
        }
    }
}
