import ChatUI
import OpenClawKit
import SwiftUI
import UserNotifications

struct CronListView: View {
    @Environment(\.appContainerStore) private var containerStore
    @State private var jobs: [CronJobPayload] = []
    @State private var isLoading = false
    @State private var isShowingAddSheet = false
    @State private var jobToRemove: CronJobPayload?
    @State private var errorMessage: String?
    @State private var isShowingNotificationDeniedAlert = false

    private let cronService: any CronServicing = CronService()

    private static let isoFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    var body: some View {
        cronList
            .navigationTitle(L10n.tr("settings.cron.navigationTitle"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button {
                        isShowingAddSheet = true
                    } label: {
                        Label(L10n.tr("settings.cron.addJob"), systemImage: "plus")
                    }
                }
            }
            .sheet(isPresented: $isShowingAddSheet) {
                NavigationStack {
                    CronAddJobSheet(onCreate: { draft in
                        Task {
                            await createJob(draft)
                        }
                    }, onCancel: {
                        isShowingAddSheet = false
                    })
                }
                #if targetEnvironment(macCatalyst)
                .frame(width: 640, height: 600)
                #endif
            }
            .confirmationDialog(
                L10n.tr("settings.cron.delete.confirmTitle"),
                isPresented: deleteDialogBinding,
                titleVisibility: .visible,
                presenting: jobToRemove
            ) { job in
                Button(L10n.tr("common.delete"), role: .destructive) {
                    Task {
                        await removeJob(job)
                    }
                }
                Button(L10n.tr("common.cancel"), role: .cancel) {
                    jobToRemove = nil
                }
            } message: { job in
                Text(L10n.tr("settings.cron.delete.message", job.message))
            }
            .alert(L10n.tr("settings.cron.error.title"), isPresented: errorAlertBinding) {
                Button(L10n.tr("common.ok"), role: .cancel) {
                    errorMessage = nil
                }
            } message: {
                Text(errorMessage ?? L10n.tr("common.unknownError"))
            }
            .alert(L10n.tr("settings.cron.error.title"), isPresented: $isShowingNotificationDeniedAlert) {
                Button(L10n.tr("settings.cron.error.openSettings")) {
                    if let url = URL(string: UIApplication.openSettingsURLString) {
                        UIApplication.shared.open(url)
                    }
                }
                Button(L10n.tr("common.cancel"), role: .cancel) {}
            } message: {
                Text(L10n.tr("settings.cron.error.notificationsDenied"))
            }
            .refreshable {
                await refreshJobs(force: true)
            }
            .task {
                await refreshJobs(force: false)
            }
    }

    private var cronList: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text(L10n.tr("settings.cron.scheduled.header"))
                    .font(.system(size: 16, weight: .semibold))
                    .tracking(-0.3)
                    .foregroundStyle(Color(uiColor: ChatUIDesign.Color.offBlack))
                    .padding(.horizontal, 16)

                VStack(spacing: 12) {
                    cronRows
                }
                .padding(.horizontal, 16)

                Text(scheduledFooterText)
                    .font(.footnote)
                    .foregroundStyle(Color(uiColor: ChatUIDesign.Color.black60))
                    .padding(.horizontal, 16)
            }
            .padding(.vertical, 24)
        }
        .scrollContentBackground(.hidden)
        .background(Color(uiColor: ChatUIDesign.Color.warmCream).ignoresSafeArea())
    }

    @ViewBuilder
    private var cronRows: some View {
        if isLoading, jobs.isEmpty {
            ProgressView()
                .frame(maxWidth: .infinity)
                .padding(.vertical, 24)
        } else if jobs.isEmpty {
            EmptyCronJobsView()
        } else {
            ForEach(jobs, id: \.id) { job in
                VStack(alignment: .leading, spacing: 0) {
                    CronJobRow(job: job, agentName: resolvedAgentName(for: job))

                    if job.kind == .heartbeat, let agentID = job.agentID {
                        let isRegistered = HeartbeatRuntimeRegistry.shared.isRuntimeRegistered(for: agentID)
                        if isRegistered {
                            HStack {
                                Spacer()
                                Button {
                                    Task {
                                        await HeartbeatRuntimeRegistry.shared.requestRunNow(for: agentID)
                                    }
                                } label: {
                                    Label(L10n.tr("chat.command.runHeartbeatNow"), systemImage: "waveform.path.ecg")
                                        .font(.system(size: 14, weight: .regular))
                                        .foregroundStyle(Color(uiColor: ChatUIDesign.Color.offBlack))
                                }
                                .padding(.horizontal, 14)
                                .padding(.vertical, 8)
                                .background(Color(uiColor: ChatUIDesign.Color.pureWhite))
                                .clipShape(RoundedRectangle(cornerRadius: ChatUIDesign.Radius.button, style: .continuous))
                                .overlay(
                                    RoundedRectangle(cornerRadius: ChatUIDesign.Radius.button, style: .continuous)
                                        .strokeBorder(Color(uiColor: ChatUIDesign.Color.oatBorder), lineWidth: 1)
                                )
                            }
                            .padding(.top, 12)
                            .padding(.horizontal, 16)
                            .padding(.bottom, 12)
                        }
                    }
                }
                .background(
                    RoundedRectangle(cornerRadius: ChatUIDesign.Radius.card, style: .continuous)
                        .fill(Color(uiColor: ChatUIDesign.Color.warmCream))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: ChatUIDesign.Radius.card, style: .continuous)
                        .strokeBorder(Color(uiColor: ChatUIDesign.Color.oatBorder), lineWidth: 1)
                )
                .contextMenu {
                    Button(role: .destructive) {
                        jobToRemove = job
                    } label: {
                        Label(L10n.tr("common.delete"), systemImage: "trash")
                    }
                }
            }
        }
    }

    private var scheduledFooterText: String {
        #if targetEnvironment(macCatalyst)
            L10n.tr("settings.cron.scheduled.footer.mac")
        #else
            L10n.tr("settings.cron.scheduled.footer")
        #endif
    }

    private var deleteDialogBinding: Binding<Bool> {
        Binding(
            get: { jobToRemove != nil },
            set: { isPresented in
                if !isPresented {
                    jobToRemove = nil
                }
            }
        )
    }

    private var errorAlertBinding: Binding<Bool> {
        Binding(
            get: { errorMessage != nil },
            set: { isPresented in
                if !isPresented {
                    errorMessage = nil
                }
            }
        )
    }

    private func resolvedAgentName(for job: CronJobPayload) -> String? {
        guard job.kind == .heartbeat else { return nil }
        guard let rawAgentID = AppConfig.nonEmpty(job.agentID),
              let agentUUID = UUID(uuidString: rawAgentID),
              let agent = containerStore.agents.first(where: { $0.id == agentUUID })
        else {
            return L10n.tr("settings.cron.agent.unknown")
        }

        return agent.emoji.isEmpty ? agent.name : "\(agent.emoji) \(agent.name)"
    }

    @MainActor
    private func refreshJobs(force: Bool) async {
        if isLoading, !force {
            return
        }

        isLoading = true
        defer { self.isLoading = false }

        do {
            let payload = try await cronService.list()
            jobs = payload.jobs
        } catch {
            showError(error)
        }
    }

    @MainActor
    private func createJob(_ draft: CronCreateDraft) async {
        do {
            try await ensureNotificationAuthorization()
            let atISO = draft.atDate.map { Self.isoFormatter.string(from: $0) }
            _ = try await cronService.add(
                message: draft.message,
                atISO: atISO,
                everySeconds: draft.everySeconds,
                kind: draft.kind,
                agentID: draft.agentID
            )
            #if targetEnvironment(macCatalyst)
                isShowingAddSheet = false
            #endif
            await refreshJobs(force: true)
        } catch {
            showError(error)
        }
    }

    @MainActor
    private func removeJob(_ job: CronJobPayload) async {
        do {
            _ = try await cronService.remove(id: job.id)
            jobToRemove = nil
            await refreshJobs(force: true)
        } catch {
            showError(error)
        }
    }

    private func ensureNotificationAuthorization() async throws {
        let center = UNUserNotificationCenter.current()
        let settings = await center.notificationSettings()

        switch settings.authorizationStatus {
        case .authorized, .provisional, .ephemeral:
            return
        case .denied:
            throw CronViewError.notificationsDenied
        case .notDetermined:
            let granted = try await center.requestAuthorization(options: [.alert, .sound, .badge])
            if !granted {
                throw CronViewError.notificationsDenied
            }
        @unknown default:
            throw CronViewError.notificationsDenied
        }
    }

    @MainActor
    private func showError(_ error: Error) {
        if let cronError = error as? CronViewError, case .notificationsDenied = cronError {
            isShowingNotificationDeniedAlert = true
        } else {
            errorMessage = error.localizedDescription
        }
    }
}

private enum CronViewError: LocalizedError {
    case notificationsDenied

    var errorDescription: String? {
        switch self {
        case .notificationsDenied:
            return L10n.tr("settings.cron.error.notificationsDenied")
        }
    }
}

private struct CronCreateDraft {
    var message: String
    var kind: CronJobKind
    var agentID: String?
    var atDate: Date?
    var everySeconds: Int?
}

private struct CronAddJobSheet: View {
    enum PresentationStyle {
        case modal
        case embedded
    }

    enum ScheduleMode: String, CaseIterable, Identifiable {
        case at
        case every

        var id: String {
            rawValue
        }

        var title: String {
            switch self {
            case .at:
                return L10n.tr("settings.cron.schedule.atTime")
            case .every:
                return L10n.tr("settings.cron.schedule.every")
            }
        }
    }

    enum JobKindOption: String, CaseIterable, Identifiable {
        case notify
        case heartbeat

        var id: String {
            rawValue
        }

        var cronKind: CronJobKind {
            switch self {
            case .notify:
                return .notify
            case .heartbeat:
                return .heartbeat
            }
        }

        var title: String {
            switch self {
            case .notify:
                return L10n.tr("settings.cron.kind.notify")
            case .heartbeat:
                return L10n.tr("settings.cron.kind.heartbeat")
            }
        }
    }

    @Environment(\.appContainerStore) private var containerStore
    @Environment(\.dismiss) private var dismiss

    @State private var message = ""
    @State private var jobKind: JobKindOption = .notify
    @State private var selectedAgentID = ""
    @State private var mode: ScheduleMode = .at
    @State private var atDate = Date().addingTimeInterval(300)
    @State private var everyMinutes = 5

    let onCreate: (CronCreateDraft) -> Void
    let onCancel: (() -> Void)?
    let presentationStyle: PresentationStyle

    init(
        onCreate: @escaping (CronCreateDraft) -> Void,
        onCancel: (() -> Void)? = nil,
        presentationStyle: PresentationStyle = .modal
    ) {
        self.onCreate = onCreate
        self.onCancel = onCancel
        self.presentationStyle = presentationStyle
    }

    var body: some View {
        Group {
            #if targetEnvironment(macCatalyst)
                VStack(spacing: 0) {
                    sheetTopBar()
                    formContent
                }
            #else
                formContent
                    .navigationTitle(L10n.tr("settings.cron.addJob"))
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button(L10n.tr("common.cancel")) {
                                onCancel?()
                                if presentationStyle == .modal {
                                    dismiss()
                                }
                            }
                        }
                        ToolbarItem(placement: .confirmationAction) {
                            Button(L10n.tr("common.save")) {
                                onCreate(makeDraft())
                            }
                            .disabled(!isFormValid)
                        }
                    }
            #endif
        }
        .background(Color(uiColor: ChatUIDesign.Color.warmCream))
    }

    private var formContent: some View {
        ScrollView {
            VStack(spacing: 24) {
                CustomSection {
                    labeledField(L10n.tr("settings.cron.kind.field")) {
                        Picker(selection: $jobKind) {
                            ForEach(JobKindOption.allCases) { item in
                                Text(item.title).tag(item)
                            }
                        } label: {
                            EmptyView()
                        }
                        .pickerStyle(.menu)
                        .tint(.primary)
                    }
                    .padding(.horizontal, 20)
                }

                if jobKind == .heartbeat {
                    CustomSection {
                        labeledField(L10n.tr("settings.cron.agent.field")) {
                            Picker(selection: $selectedAgentID) {
                                Text(L10n.tr("settings.cron.agent.none")).tag("")
                                ForEach(containerStore.agents, id: \.id) { agent in
                                    Text(agent.emoji.isEmpty ? agent.name : "\(agent.emoji) \(agent.name)")
                                        .tag(agent.id.uuidString)
                                }
                            } label: {
                                EmptyView()
                            }
                            .pickerStyle(.menu)
                            .tint(.primary)
                        }
                        .padding(.horizontal, 20)
                    }
                }

                CustomSection {
                    labeledField(L10n.tr("settings.cron.message.section")) {
                        TextField(jobKind == .heartbeat ? L10n.tr("settings.cron.message.placeholder.heartbeat") : L10n.tr("settings.cron.message.placeholder"), text: $message, axis: .vertical)
                            .lineLimit(2 ... 6)
                            .settingsInputFieldStyle()
                    }
                    .padding(.horizontal, 20)
                }

                CustomSection {
                    VStack(alignment: .leading, spacing: 16) {
                        labeledField(L10n.tr("settings.cron.schedule.mode")) {
                            Picker(selection: $mode) {
                                ForEach(ScheduleMode.allCases) { m in
                                    Text(m.title).tag(m)
                                }
                            } label: {
                                EmptyView()
                            }
                            .pickerStyle(.menu)
                            .tint(.primary)
                        }

                        if mode == .at {
                            labeledField(L10n.tr("settings.cron.schedule.atTime")) {
                                DatePicker("", selection: $atDate, in: Date()..., displayedComponents: [.date, .hourAndMinute])
                                    .labelsHidden()
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .settingsInputFieldStyle()
                            }
                        } else {
                            labeledField(L10n.tr("settings.cron.schedule.every")) {
                                Stepper(value: $everyMinutes, in: 1 ... 1440) {
                                    Text("\(everyMinutes) \(L10n.tr("common.minutes"))")
                                }
                                .settingsInputFieldStyle()
                            }
                        }
                    }
                    .padding(.horizontal, 20)
                }
            }
            .padding(.vertical, 24)
        }
        #if !targetEnvironment(macCatalyst)
        .scrollDismissesKeyboard(.interactively)
        #endif
    }

    #if targetEnvironment(macCatalyst)
        private func sheetTopBar() -> some View {
            VStack(spacing: 0) {
                ZStack {
                    Text(L10n.tr("settings.cron.addJob"))
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(Color(uiColor: ChatUIDesign.Color.offBlack))

                    HStack {
                        actionButton(
                            title: L10n.tr("common.cancel"),
                            role: .secondary,
                            action: {
                                onCancel?()
                                if presentationStyle == .modal {
                                    dismiss()
                                }
                            }
                        )
                        Spacer(minLength: 0)
                        actionButton(
                            title: L10n.tr("common.save"),
                            role: .primary,
                            action: { onCreate(makeDraft()) }
                        )
                        .disabled(!isFormValid)
                    }
                }
                .padding(.horizontal, 20)
                .padding(.top, 16)
                .padding(.bottom, 12)

                Rectangle()
                    .fill(Color(uiColor: ChatUIDesign.Color.oatBorder))
                    .frame(height: 1)
            }
        }
    #endif

    private enum InlineActionRole {
        case primary
        case secondary
    }

    private func actionButton(
        title: String,
        role: InlineActionRole,
        action: @escaping () -> Void
    ) -> some View {
        let foregroundColor: UIColor = switch role {
        case .primary:
            ChatUIDesign.Color.pureWhite
        case .secondary:
            ChatUIDesign.Color.offBlack
        }
        let backgroundColor: Color = switch role {
        case .primary:
            Color(uiColor: ChatUIDesign.Color.offBlack)
        case .secondary:
            .clear
        }

        return Button(action: action) {
            Text(title)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(Color(uiColor: foregroundColor))
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(backgroundColor)
                .clipShape(RoundedRectangle(cornerRadius: ChatUIDesign.Radius.button, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: ChatUIDesign.Radius.button, style: .continuous)
                        .strokeBorder(Color(uiColor: ChatUIDesign.Color.oatBorder), lineWidth: role == .secondary ? 1 : 0)
                )
        }
        .buttonStyle(.plain)
    }

    private struct CustomSection<Content: View, Footer: View>: View {
        let title: String?
        let footer: Footer?
        @ViewBuilder let content: () -> Content

        init(title: String? = nil, @ViewBuilder footer: () -> Footer, @ViewBuilder content: @escaping () -> Content) {
            self.title = title
            self.footer = footer()
            self.content = content
        }

        init(title: String? = nil, @ViewBuilder content: @escaping () -> Content) where Footer == EmptyView {
            self.title = title
            self.footer = nil
            self.content = content
        }

        var body: some View {
            VStack(alignment: .leading, spacing: 12) {
                if let title {
                    Text(title)
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(Color(uiColor: ChatUIDesign.Color.black60))
                        .padding(.horizontal, 20)
                }

                content()

                if let footer {
                    footer
                        .font(.system(size: 13))
                        .foregroundStyle(Color(uiColor: ChatUIDesign.Color.black50))
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.horizontal, 20)
                }
            }
        }
    }

    private func labeledField<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(Color(uiColor: ChatUIDesign.Color.black80))
            content()
        }
    }

    private enum ActionButtonRole {
        case primary
        case secondary
    }

    private func actionButton(
        title: String,
        role: ActionButtonRole,
        isDisabled: Bool,
        action: @escaping () -> Void
    ) -> some View {
        let foregroundColor: UIColor = switch role {
        case .primary:
            isDisabled ? UIColor.systemGray2 : ChatUIDesign.Color.pureWhite
        case .secondary:
            isDisabled ? UIColor.systemGray2 : ChatUIDesign.Color.offBlack
        }
        let backgroundColor: Color = switch role {
        case .primary:
            Color(uiColor: isDisabled ? UIColor.tertiarySystemFill : ChatUIDesign.Color.offBlack)
        case .secondary:
            .clear
        }

        return Button(action: action) {
            Text(title)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(Color(uiColor: foregroundColor))
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(backgroundColor)
                .clipShape(RoundedRectangle(cornerRadius: ChatUIDesign.Radius.button, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: ChatUIDesign.Radius.button, style: .continuous)
                        .strokeBorder(Color(uiColor: ChatUIDesign.Color.oatBorder), lineWidth: role == .secondary ? 1 : 0)
                )
        }
        .buttonStyle(.plain)
        .disabled(isDisabled)
    }

    private var isFormValid: Bool {
        let msg = message.trimmingCharacters(in: .whitespacesAndNewlines)
        if msg.isEmpty { return false }
        if jobKind == .heartbeat {
            if selectedAgentID.isEmpty { return false }
        }
        return true
    }

    private func cancelSheet() {
        onCancel?()
        if presentationStyle == .modal {
            dismiss()
        }
    }

    private var trimmedMessage: String {
        message.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var messagePlaceholder: String {
        switch jobKind {
        case .notify:
            return L10n.tr("settings.cron.message.placeholder")
        case .heartbeat:
            return L10n.tr("settings.cron.message.placeholder.heartbeat")
        }
    }

    private var canCreateJob: Bool {
        switch jobKind {
        case .notify:
            return !trimmedMessage.isEmpty
        case .heartbeat:
            return resolvedSelectedAgentID != nil
        }
    }

    private var resolvedSelectedAgentID: String? {
        let trimmed = selectedAgentID.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private func ensureSelectedAgent() {
        guard jobKind == .heartbeat else { return }
        if let selected = resolvedSelectedAgentID,
           containerStore.agents.contains(where: { $0.id.uuidString == selected })
        {
            return
        }

        selectedAgentID = containerStore.activeAgent?.id.uuidString
            ?? containerStore.agents.first?.id.uuidString
            ?? ""
    }

    private func agentDisplayName(_ agent: AgentProfile) -> String {
        agent.emoji.isEmpty ? agent.name : "\(agent.emoji) \(agent.name)"
    }

    private func makeDraft() -> CronCreateDraft {
        switch mode {
        case .at:
            return CronCreateDraft(
                message: trimmedMessage,
                kind: jobKind.cronKind,
                agentID: resolvedSelectedAgentID,
                atDate: atDate,
                everySeconds: nil
            )
        case .every:
            return CronCreateDraft(
                message: trimmedMessage,
                kind: jobKind.cronKind,
                agentID: resolvedSelectedAgentID,
                atDate: nil,
                everySeconds: everyMinutes * 60
            )
        }
    }
}

private extension View {
    func settingsInputFieldStyle() -> some View {
        padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(
                Color(uiColor: ChatUIDesign.Color.pureWhite),
                in: RoundedRectangle(cornerRadius: ChatUIDesign.Radius.card, style: .continuous)
            )
            .overlay(
                RoundedRectangle(cornerRadius: ChatUIDesign.Radius.card, style: .continuous)
                    .strokeBorder(Color(uiColor: ChatUIDesign.Color.oatBorder), lineWidth: 1)
            )
    }
}

private struct CronJobRow: View {
    let job: CronJobPayload
    let agentName: String?

    private static let parseWithFractionalSeconds: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    private static let parseWithoutFractionalSeconds: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    private static let intervalFormatter: DateComponentsFormatter = {
        let formatter = DateComponentsFormatter()
        formatter.unitsStyle = .full
        formatter.maximumUnitCount = 2
        return formatter
    }()

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .top, spacing: 8) {
                Text(job.message)
                    .font(.headline)
                    .lineLimit(2)

                Spacer(minLength: 8)

                Text(kindTitle)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(kindTint)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(kindTint.opacity(0.14), in: Capsule())
            }

            Text(scheduleText)
                .font(.subheadline)
                .foregroundStyle(.secondary)

            if let agentName {
                Label(agentName, systemImage: "person.crop.circle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            if let nextRunText {
                Text(L10n.tr("settings.cron.nextRun", nextRunText))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private var kindTitle: String {
        switch job.kind {
        case .notify:
            return L10n.tr("settings.cron.kind.notify")
        case .heartbeat:
            return L10n.tr("settings.cron.kind.heartbeat")
        }
    }

    private var kindTint: Color {
        switch job.kind {
        case .notify:
            return .blue
        case .heartbeat:
            return .orange
        }
    }

    private var scheduleText: String {
        if let every = job.everySeconds, job.schedule == "every" {
            let intervalText = Self.intervalFormatter.string(from: TimeInterval(every)) ?? "\(every)s"
            return L10n.tr("settings.cron.schedule.everyInterval", intervalText)
        }

        if let at = formattedDate(from: job.at) {
            return L10n.tr("settings.cron.schedule.at", at)
        }

        if let cron = job.cron, !cron.isEmpty {
            return cron
        }

        return job.schedule.capitalized
    }

    private var nextRunText: String? {
        formattedDate(from: job.nextRunISO)
    }

    private func formattedDate(from iso: String?) -> String? {
        guard let iso, !iso.isEmpty else { return nil }
        guard let date = Self.parseWithFractionalSeconds.date(from: iso)
            ?? Self.parseWithoutFractionalSeconds.date(from: iso)
        else {
            return iso
        }
        return date.formatted(date: .abbreviated, time: .shortened)
    }
}

private struct EmptyCronJobsView: View {
    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "clock.badge")
                .font(.system(size: 32, weight: .light))
                .foregroundStyle(Color(uiColor: ChatUIDesign.Color.black60))

            Text(L10n.tr("settings.cron.empty.title"))
                .font(.subheadline.weight(.regular))
                .foregroundStyle(Color(uiColor: ChatUIDesign.Color.offBlack))

            Text(L10n.tr("settings.cron.empty.message"))
                .font(.footnote)
                .foregroundStyle(Color(uiColor: ChatUIDesign.Color.black60))
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, minHeight: 120)
        .padding()
        .background(
            RoundedRectangle(cornerRadius: ChatUIDesign.Radius.card, style: .continuous)
                .fill(Color(uiColor: ChatUIDesign.Color.warmCream))
        )
        .overlay(
            RoundedRectangle(cornerRadius: ChatUIDesign.Radius.card, style: .continuous)
                .strokeBorder(Color(uiColor: ChatUIDesign.Color.oatBorder), lineWidth: 1)
        )
    }
}

#Preview {
    NavigationStack {
        CronListView()
    }
}
