import Foundation
import OpenClawKit
import WidgetKit

@MainActor
enum SkillLauncherCatalogPublisher {
    static let widgetKind = "SkillLauncherWidget"

    static func publish(activeAgent: AgentProfile?) {
        let snapshot: SkillLauncherCatalogSnapshot

        if let activeAgent {
            let skills = AgentSkillsLoader.listSkills(
                filterUnavailable: true,
                visibility: .userInvocable,
                workspaceRootURL: activeAgent.workspaceURL
            ).map { skill in
                SkillLauncherSkillSummary(
                    id: skill.name,
                    displayName: skill.displayName,
                    emoji: skill.emoji,
                    iconName: SkillLauncherPresetCatalog.defaultIconName
                )
            }

            snapshot = SkillLauncherCatalogSnapshot(
                generatedAtMs: Int64(Date().timeIntervalSince1970 * 1000),
                agentID: activeAgent.id.uuidString,
                skills: skills
            )
        } else {
            snapshot = SkillLauncherCatalogSnapshot(
                generatedAtMs: Int64(Date().timeIntervalSince1970 * 1000),
                agentID: nil,
                skills: []
            )
        }

        SkillLauncherCatalogStore.save(snapshot)
        guard OpenAvaSharedDefaults.usesSharedAppGroup else {
            return
        }
        WidgetCenter.shared.reloadTimelines(ofKind: widgetKind)
    }
}
