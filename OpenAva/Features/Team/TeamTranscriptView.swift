import ChatUI
import Foundation
import OpenClawKit
import SwiftUI

struct TeamTranscriptView: View {
    @Environment(\.appContainerStore) private var containerStore

    let sessionID: String

    @State private var input = ""
    @State private var messages: [ConversationMessage] = []
    @State private var snapshot: TeamSwarmCoordinator.MemberSnapshot?
    @State private var isSubmitting = false

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            List(messages, id: \.id) { message in
                VStack(alignment: .leading, spacing: 6) {
                    Text(roleLabel(for: message.role))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(message.textContent)
                        .font(.body)
                        .textSelection(.enabled)
                }
                .padding(.vertical, 4)
            }
            composer
        }
        .navigationTitle(snapshot?.member.sessionTitle ?? "Teammate")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear(perform: refresh)
        .onReceive(NotificationCenter.default.publisher(for: .openAvaTeamSwarmDidChange)) { _ in
            refresh()
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let snapshot {
                HStack {
                    Text(snapshot.member.name)
                        .font(.headline)
                    Spacer()
                    Text(statusText(snapshot.member.status))
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(statusColor(snapshot.member.status))
                }
                metadataRow(snapshot: snapshot)
                if let lastPlan = snapshot.member.lastPlan, snapshot.member.awaitingPlanApproval {
                    Text(lastPlan)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .padding(10)
                        .background(Color(uiColor: .secondarySystemBackground), in: RoundedRectangle(cornerRadius: 12))
                }
                if let preview = snapshot.member.lastMailboxPreview, !preview.isEmpty {
                    Text("最近收件：\(preview)")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                if let peer = snapshot.member.lastPeerMessageSummary, !peer.isEmpty {
                    Text(peer)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        if snapshot.member.awaitingPlanApproval {
                            Button("批准计划") {
                                Task { await approvePlan() }
                            }
                            .buttonStyle(.borderedProminent)
                        }
                        Button("停止") {
                            Task { await send(message: "Shutdown requested.", type: "shutdown_request") }
                        }
                        .buttonStyle(.bordered)
                    }
                }
                teammatePanel(snapshot: snapshot)
                taskPanel(snapshot: snapshot)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(Color(.secondarySystemBackground))
    }

    private var composer: some View {
        VStack(spacing: 8) {
            Divider()
            HStack(alignment: .bottom, spacing: 8) {
                TextField("给 teammate 发消息", text: $input, axis: .vertical)
                    .textFieldStyle(.roundedBorder)
                    .lineLimit(1 ... 5)
                Button(isSubmitting ? "发送中…" : "发送") {
                    Task { await sendCurrentInput() }
                }
                .buttonStyle(.borderedProminent)
                .disabled(isSubmitting || input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            .padding()
        }
        .background(Color(.systemBackground))
    }

    private func refresh() {
        snapshot = TeamSwarmCoordinator.shared.memberSnapshot(for: sessionID)
        guard let runtimeRootURL = containerStore.activeAgent?.runtimeURL else {
            messages = []
            return
        }
        let provider = TranscriptStorageProvider.provider(runtimeRootURL: runtimeRootURL)
        messages = provider.messages(in: sessionID)
    }

    private func sendCurrentInput() async {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        input = ""
        await send(message: trimmed, type: "message")
    }

    private func send(message: String, type: String) async {
        guard let snapshot else { return }
        struct Params: Encodable {
            let to: String
            let message: String
            let teamName: String
            let messageType: String

            enum CodingKeys: String, CodingKey {
                case to
                case message
                case teamName = "team_name"
                case messageType = "message_type"
            }
        }
        guard let data = try? JSONEncoder().encode(Params(to: snapshot.member.name, message: message, teamName: snapshot.teamName, messageType: type)),
              let paramsJSON = String(data: data, encoding: .utf8)
        else {
            return
        }
        isSubmitting = true
        defer { isSubmitting = false }
        let request = BridgeInvokeRequest(id: UUID().uuidString, command: "team.message.send", paramsJSON: paramsJSON)
        _ = await containerStore.container.services.localToolInvokeService.handle(request)
        refresh()
    }

    private func approvePlan() async {
        struct Params: Encodable {
            let sessionID: String
            let teamName: String

            enum CodingKeys: String, CodingKey {
                case sessionID = "session_id"
                case teamName = "team_name"
            }
        }
        guard let snapshot,
              let data = try? JSONEncoder().encode(Params(sessionID: sessionID, teamName: snapshot.teamName)),
              let paramsJSON = String(data: data, encoding: .utf8)
        else {
            return
        }
        let request = BridgeInvokeRequest(id: UUID().uuidString, command: "team.plan.approve", paramsJSON: paramsJSON)
        _ = await containerStore.container.services.localToolInvokeService.handle(request)
        refresh()
    }

    private func roleLabel(for role: MessageRole) -> String {
        switch role {
        case .assistant:
            return "Assistant"
        case .system:
            return "System"
        default:
            return "User"
        }
    }

    private func statusText(_ status: TeamSwarmCoordinator.MemberStatus) -> String {
        switch status {
        case .idle:
            return "空闲"
        case .busy:
            return "执行中"
        case .awaitingPlanApproval:
            return "等待计划批准"
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

    private func metadataRow(snapshot: TeamSwarmCoordinator.MemberSnapshot) -> some View {
        HStack(spacing: 8) {
            pill(text: snapshot.member.agentType)
            if let queued = snapshot.member.queuedMessageCount, queued > 0 {
                pill(text: "待处理 \(queued)", tint: .orange)
            }
            if snapshot.member.planModeRequired {
                pill(text: "Plan Mode", tint: .purple)
            }
        }
    }

    private func teammatePanel(snapshot: TeamSwarmCoordinator.MemberSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("队友状态")
                .font(.subheadline.weight(.medium))
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(snapshot.teammates) { teammate in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(teammate.name)
                                .font(.footnote.weight(.semibold))
                            Text(statusText(teammate.status))
                                .font(.caption)
                                .foregroundStyle(statusColor(teammate.status))
                            if let queued = teammate.queuedMessageCount, queued > 0 {
                                Text("待处理 \(queued)")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .padding(8)
                        .background(Color(uiColor: .systemBackground), in: RoundedRectangle(cornerRadius: 10))
                    }
                }
            }
        }
    }

    private func taskPanel(snapshot: TeamSwarmCoordinator.MemberSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("共享任务")
                .font(.subheadline.weight(.medium))
            ForEach(snapshot.tasks.prefix(4)) { task in
                HStack(alignment: .top, spacing: 8) {
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

    private func pill(text: String, tint: Color = .secondary) -> some View {
        Text(text)
            .font(.caption)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(tint.opacity(0.12), in: Capsule())
            .foregroundStyle(tint)
    }
}
