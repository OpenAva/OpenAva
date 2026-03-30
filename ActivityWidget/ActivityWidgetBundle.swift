import SwiftUI
import WidgetKit

@main
struct ActivityWidgetBundle: WidgetBundle {
    var body: some Widget {
        CronLiveActivity()
        TaskLiveActivity()
        SkillLauncherWidget()
    }
}
