import ChatUI
import Foundation
import OpenClawKit
import SwiftUI

struct ToolListItem: Identifiable, Equatable {
    let id: String
    let definition: ToolDefinition
    let isEnabled: Bool

    static func == (lhs: ToolListItem, rhs: ToolListItem) -> Bool {
        lhs.id == rhs.id && lhs.isEnabled == rhs.isEnabled
    }
}

struct ToolListView: View {
    @Environment(\.appContainerStore) private var containerStore
    @State private var tools: [ToolListItem] = []
    @State private var isLoading = false

    var body: some View {
        toolList
            .navigationTitle(L10n.tr("settings.tools.navigationTitle"))
            .navigationBarTitleDisplayMode(.inline)
            .refreshable {
                refreshTools()
            }
            .task {
                refreshTools()
            }
            .onChange(of: containerStore.activeAgent?.id ?? "") { _, _ in
                refreshTools()
            }
    }

    private var toolList: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                if isLoading && tools.isEmpty {
                    ProgressView()
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 28)
                } else {
                    SkillRowsCard {
                        ForEach(Array(tools.enumerated()), id: \.element.id) { index, tool in
                            ToolRow(
                                tool: tool,
                                isEnabled: toolEnabledBinding(for: tool)
                            )
                            if index < tools.count - 1 {
                                SkillRowDivider()
                            }
                        }
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 24)
        }
        .scrollContentBackground(.hidden)
        .background(Color(uiColor: ChatUIDesign.Color.warmCream).ignoresSafeArea())
    }

    private func toolEnabledBinding(for tool: ToolListItem) -> Binding<Bool> {
        Binding(
            get: {
                guard let currentTool = tools.first(where: { $0.id == tool.id }) else { return false }
                return currentTool.isEnabled
            },
            set: { newValue in
                AgentToolToggleStore.setEnabled(
                    newValue,
                    for: tool.definition,
                    workspaceRootURL: containerStore.activeAgent?.workspaceURL
                )
                if let index = tools.firstIndex(where: { $0.id == tool.id }) {
                    tools[index] = ToolListItem(
                        id: tool.id,
                        definition: tool.definition,
                        isEnabled: newValue
                    )
                }
            }
        )
    }

    private func refreshTools() {
        isLoading = true
        let workspaceURL = containerStore.activeAgent?.workspaceURL

        Task {
            let definitions = ToolRegistry.shared.allDefinitions()
            let items = definitions.map { definition in
                ToolListItem(
                    id: definition.functionName,
                    definition: definition,
                    isEnabled: AgentToolToggleStore.isEnabled(definition, workspaceRootURL: workspaceURL)
                )
            }.sorted { $0.definition.displayName < $1.definition.displayName }

            await MainActor.run {
                self.tools = items
                self.isLoading = false
            }
        }
    }
}

private struct ToolRow: View {
    let tool: ToolListItem
    @Binding var isEnabled: Bool

    var body: some View {
        HStack(alignment: .center, spacing: 14) {
            tappableContent

            HStack(alignment: .center, spacing: 12) {
                Toggle(L10n.tr("settings.skills.enabled"), isOn: $isEnabled)
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .tint(Color(uiColor: ChatUIDesign.Color.brandOrange))
                    .scaleEffect(0.85)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .animation(.easeInOut(duration: 0.2), value: isEnabled)
    }

    private var tappableContent: some View {
        HStack(alignment: .center, spacing: 14) {
            toolIcon
            toolSummary
            Spacer(minLength: 8)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .opacity(isEnabled ? 1.0 : 0.6)
    }

    private var toolIcon: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color(uiColor: ChatUIDesign.Color.black60).opacity(0.06))
            Image(systemName: "hammer")
                .font(.system(size: 20))
        }
        .frame(width: 44, height: 44)
    }

    private var toolSummary: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(tool.definition.displayName)
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(Color(uiColor: ChatUIDesign.Color.offBlack))
                .lineLimit(1)

            Text(tool.definition.description)
                .font(.system(size: 13))
                .foregroundStyle(Color(uiColor: ChatUIDesign.Color.contentTertiary))
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
