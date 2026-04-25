import ChatUI
import OpenClawKit
import SwiftUI
import UserNotifications

struct CronListView: View {
    @Environment(\.appContainerStore) private var containerStore
    @State private var jobs: [CronJobPayload] = []
    @State private var isLoading = false
    @State private var isShowingAddSheet = false
    @State private var jobToEdit: CronJobPayload?
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
            .sheet(item: $jobToEdit) { job in
                NavigationStack {
                    CronAddJobSheet(
                        initialJob: job,
                        onCreate: { draft in
                            Task {
                                await updateJob(oldJobID: job.id, draft: draft)
                            }
                        }, onCancel: {
                            jobToEdit = nil
                        }
                    )
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
            VStack(alignment: .leading, spacing: 24) {
                VStack(alignment: .leading, spacing: 12) {
                    Text(L10n.tr("settings.cron.scheduled.header"))
                        .font(.system(size: 20, weight: .regular))
                        .tracking(-0.2)
                        .foregroundStyle(Color(uiColor: ChatUIDesign.Color.offBlack))
                        .padding(.horizontal, 16)

                    VStack(spacing: 12) {
                        cronRows
                    }
                    .padding(.horizontal, 16)

                    if let text = scheduledFooterText {
                        Text(text)
                            .font(.footnote)
                            .foregroundStyle(Color(uiColor: ChatUIDesign.Color.black60))
                            .padding(.horizontal, 16)
                    }
                }
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
                .padding(.vertical, 16)
        } else {
            ForEach(jobs, id: \.id) { job in
                CronJobRow(
                    job: job,
                    agentName: resolvedAgentName(for: job),
                    onEdit: { jobToEdit = job },
                    onDelete: { jobToRemove = job }
                )
                .contentShape(Rectangle())
                .onTapGesture {
                    jobToEdit = job
                }
                .contextMenu {
                    Button {
                        jobToEdit = job
                    } label: {
                        Label(L10n.tr("common.edit"), systemImage: "pencil")
                    }
                    Button(role: .destructive) {
                        jobToRemove = job
                    } label: {
                        Label(L10n.tr("common.delete"), systemImage: "trash")
                    }
                }
            }
        }
    }

    private var scheduledFooterText: String? {
        #if targetEnvironment(macCatalyst)
            nil
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
            isShowingAddSheet = false
            await refreshJobs(force: true)
        } catch {
            showError(error)
        }
    }

    @MainActor
    private func updateJob(oldJobID: String, draft: CronCreateDraft) async {
        do {
            try await ensureNotificationAuthorization()
            let atISO = draft.atDate.map { Self.isoFormatter.string(from: $0) }
            _ = try await cronService.remove(id: oldJobID)
            _ = try await cronService.add(
                message: draft.message,
                atISO: atISO,
                everySeconds: draft.everySeconds,
                kind: draft.kind,
                agentID: draft.agentID
            )
            jobToEdit = nil
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
    @State private var everyMinutesText = "5"

    let initialJob: CronJobPayload?
    let onCreate: (CronCreateDraft) -> Void
    let onCancel: (() -> Void)?
    let presentationStyle: PresentationStyle

    init(
        initialJob: CronJobPayload? = nil,
        onCreate: @escaping (CronCreateDraft) -> Void,
        onCancel: (() -> Void)? = nil,
        presentationStyle: PresentationStyle = .modal
    ) {
        self.initialJob = initialJob
        self.onCreate = onCreate
        self.onCancel = onCancel
        self.presentationStyle = presentationStyle

        if let initialJob {
            _message = State(initialValue: initialJob.message)
            _jobKind = State(initialValue: initialJob.kind == .heartbeat ? .heartbeat : .notify)
            _selectedAgentID = State(initialValue: initialJob.agentID ?? "")

            if let every = initialJob.everySeconds {
                _mode = State(initialValue: .every)
                _everyMinutesText = State(initialValue: "\(every / 60)")
            } else if let atISO = initialJob.at, let date = Self.parseISO(atISO) {
                _mode = State(initialValue: .at)
                _atDate = State(initialValue: date)
            }
        }
    }

    private static func parseISO(_ iso: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = formatter.date(from: iso) { return d }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: iso)
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
                    .navigationTitle(initialJob == nil ? L10n.tr("settings.cron.addJob") : L10n.tr("common.edit"))
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
        .task {
            ensureSelectedAgent()
        }
        .onChange(of: jobKind) { _, newValue in
            if newValue == .heartbeat {
                ensureSelectedAgent()
            }
        }
        .onChange(of: containerStore.activeAgent?.id) { _, _ in
            ensureSelectedAgent()
        }
        .onChange(of: containerStore.agents.map(\.id)) { _, _ in
            ensureSelectedAgent()
        }
        .onChange(of: everyMinutesText) { _, newValue in
            let digits = newValue.filter(\.isNumber)
            if digits != newValue {
                everyMinutesText = digits
            }
        }
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
                        .pickerStyle(.segmented)
                    }
                    .padding(.horizontal, 20)
                }

                if jobKind == .heartbeat {
                    CustomSection {
                        labeledField(L10n.tr("settings.cron.agent.field")) {
                            Picker(selection: $selectedAgentID) {
                                ForEach(containerStore.agents, id: \.id) { agent in
                                    Text(agent.emoji.isEmpty ? agent.name : "\(agent.emoji) \(agent.name)")
                                        .tag(agent.id.uuidString)
                                }
                            } label: {
                                EmptyView()
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .pickerStyle(.menu)
                            .tint(.primary)
                            .settingsInputFieldStyle()
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
                            .pickerStyle(.segmented)
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
                                HStack(spacing: 8) {
                                    TextField(
                                        L10n.tr("settings.cron.schedule.every"),
                                        text: $everyMinutesText
                                    )
                                    .keyboardType(.numberPad)

                                    Text(L10n.tr("common.minutes"))
                                        .foregroundStyle(Color(uiColor: ChatUIDesign.Color.black60))
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
                    Text(initialJob == nil ? L10n.tr("settings.cron.addJob") : L10n.tr("common.edit"))
                        .font(.system(size: 18, weight: .regular))
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
        isDisabled: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Text(title)
        }
        .buttonStyle(PhysicalButtonStyle(role: role == .primary ? PhysicalButtonRole.primary : PhysicalButtonRole.secondary, isDisabled: isDisabled))
        .disabled(isDisabled)
    }

    private var isFormValid: Bool {
        let msg = message.trimmingCharacters(in: .whitespacesAndNewlines)
        if msg.isEmpty { return false }
        if jobKind == .heartbeat {
            if selectedAgentID.isEmpty { return false }
        }
        if mode == .every, resolvedEveryMinutes == nil {
            return false
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

    private var resolvedEveryMinutes: Int? {
        let trimmed = everyMinutesText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let value = Int(trimmed), (1 ... 1440).contains(value) else {
            return nil
        }
        return value
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
                everySeconds: (resolvedEveryMinutes ?? 5) * 60
            )
        }
    }
}

private extension View {
    func settingsInputFieldStyle() -> some View {
        frame(minHeight: 34)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 10)
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
    let onEdit: () -> Void
    let onDelete: () -> Void

    @State private var isHovering = false

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
        HStack(alignment: .center, spacing: 16) {
            jobIcon

            VStack(alignment: .leading, spacing: 4) {
                Text(job.message)
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(Color(uiColor: ChatUIDesign.Color.offBlack))
                    .lineLimit(1)

                HStack(alignment: .center, spacing: 8) {
                    StatusBadge(
                        title: kindTitle,
                        foreground: kindTint,
                        background: kindTint.opacity(0.12)
                    )

                    Text("•")
                        .font(.system(size: 10))
                        .foregroundStyle(Color(uiColor: ChatUIDesign.Color.black50))

                    HStack(spacing: 3) {
                        Image(systemName: "clock")
                            .font(.system(size: 11))
                        Text(scheduleText)
                            .font(.system(size: 13))
                    }
                    .foregroundStyle(Color(uiColor: ChatUIDesign.Color.black60))

                    if let agentName {
                        Text("•")
                            .font(.system(size: 10))
                            .foregroundStyle(Color(uiColor: ChatUIDesign.Color.black50))

                        HStack(spacing: 3) {
                            Image(systemName: "cpu")
                                .font(.system(size: 11))
                            Text(agentName)
                                .font(.system(size: 13))
                                .lineLimit(1)
                        }
                        .foregroundStyle(Color(uiColor: ChatUIDesign.Color.black60))
                    }
                }
            }

            Spacer(minLength: 12)

            HStack(spacing: 16) {
                VStack(alignment: .trailing, spacing: 6) {
                    if job.kind == .heartbeat, let agentID = job.agentID {
                        let isRegistered = HeartbeatRuntimeRegistry.shared.isRuntimeRegistered(for: agentID)
                        if isRegistered {
                            Button {
                                Task {
                                    await HeartbeatRuntimeRegistry.shared.requestRunNow(for: agentID)
                                }
                            } label: {
                                Image(systemName: "play.fill")
                                    .font(.system(size: 12))
                                    .foregroundStyle(Color(uiColor: ChatUIDesign.Color.offBlack))
                                    .padding(8)
                                    .background(Color(uiColor: ChatUIDesign.Color.pureWhite))
                                    .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 4, style: .continuous)
                                            .strokeBorder(Color(uiColor: ChatUIDesign.Color.oatBorder), lineWidth: 1)
                                    )
                            }
                            .buttonStyle(PhysicalRowButtonStyle())
                        } else {
                            nextRunView
                        }
                    } else {
                        nextRunView
                    }
                }

                #if targetEnvironment(macCatalyst)
                    HStack(spacing: 8) {
                        Button(action: onEdit) {
                            Image(systemName: "pencil")
                                .font(.system(size: 13, weight: .medium))
                                .foregroundStyle(Color(uiColor: ChatUIDesign.Color.black60))
                                .frame(width: 28, height: 28)
                                .background(Color(uiColor: ChatUIDesign.Color.black80).opacity(0.04))
                                .clipShape(Circle())
                        }
                        .buttonStyle(.plain)

                        Button(action: onDelete) {
                            Image(systemName: "trash")
                                .font(.system(size: 13, weight: .medium))
                                .foregroundStyle(Color.red.opacity(0.7))
                                .frame(width: 28, height: 28)
                                .background(Color.red.opacity(0.05))
                                .clipShape(Circle())
                        }
                        .buttonStyle(.plain)
                    }
                    .opacity(isHovering ? 1 : 0)
                #endif
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 16)
        .padding(.vertical, 16)
        .background(
            RoundedRectangle(cornerRadius: ChatUIDesign.Radius.card, style: .continuous)
                .fill(Color(uiColor: ChatUIDesign.Color.pureWhite))
        )
        .overlay(
            RoundedRectangle(cornerRadius: ChatUIDesign.Radius.card, style: .continuous)
                .strokeBorder(Color(uiColor: ChatUIDesign.Color.oatBorder), lineWidth: 1)
        )
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.15)) {
                isHovering = hovering
            }
        }
    }

    @ViewBuilder
    private var nextRunView: some View {
        if let nextRunText {
            Text(L10n.tr("settings.cron.nextRun", nextRunText))
                .font(.system(size: 12))
                .foregroundStyle(Color(uiColor: ChatUIDesign.Color.black50))
                .multilineTextAlignment(.trailing)
        }
    }

    private var jobIcon: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color(uiColor: ChatUIDesign.Color.warmCream))
                .frame(width: 36, height: 36)
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(Color(uiColor: ChatUIDesign.Color.oatBorder), lineWidth: 1)
                )

            Image(systemName: job.kind == .heartbeat ? "waveform.path.ecg" : "bell.fill")
                .font(.system(size: 16, weight: .regular))
                .foregroundStyle(job.kind == .heartbeat ? Color(uiColor: ChatUIDesign.Color.brandOrange) : Color(uiColor: ChatUIDesign.Color.black60))
        }
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
            return Color(uiColor: ChatUIDesign.Color.black60)
        case .heartbeat:
            return Color(uiColor: ChatUIDesign.Color.brandOrange)
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
        VStack(spacing: 16) {
            ZStack {
                Circle()
                    .fill(Color(uiColor: ChatUIDesign.Color.pureWhite))
                    .frame(width: 56, height: 56)
                    .overlay(Circle().strokeBorder(Color(uiColor: ChatUIDesign.Color.oatBorder), lineWidth: 1))

                Image(systemName: "calendar.badge.clock")
                    .font(.system(size: 24, weight: .light))
                    .foregroundStyle(Color(uiColor: ChatUIDesign.Color.black60))
            }

            VStack(spacing: 4) {
                Text(L10n.tr("settings.cron.empty.title"))
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(Color(uiColor: ChatUIDesign.Color.offBlack))

                Text(L10n.tr("settings.cron.empty.message"))
                    .font(.system(size: 14, weight: .regular))
                    .foregroundStyle(Color(uiColor: ChatUIDesign.Color.black60))
                    .multilineTextAlignment(.center)
            }
        }
        .frame(maxWidth: .infinity, minHeight: 160)
        .padding(24)
        .background(
            RoundedRectangle(cornerRadius: ChatUIDesign.Radius.card, style: .continuous)
                .fill(Color(uiColor: ChatUIDesign.Color.pureWhite))
        )
        .overlay(
            RoundedRectangle(cornerRadius: ChatUIDesign.Radius.card, style: .continuous)
                .strokeBorder(Color(uiColor: ChatUIDesign.Color.oatBorder), style: StrokeStyle(lineWidth: 1, dash: [4, 4]))
        )
    }
}

private struct StatusBadge: View {
    let title: String
    let foreground: Color
    let background: Color

    var body: some View {
        Text(title)
            .font(.system(size: 10, weight: .regular))
            .foregroundStyle(foreground)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(background)
            .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
    }
}

#Preview {
    NavigationStack {
        CronListView()
    }
}

enum PhysicalButtonRole {
    case primary
    case secondary
    case card
}

struct PhysicalRowButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.96 : 1.0)
            .animation(.interactiveSpring(response: 0.3, dampingFraction: 0.6), value: configuration.isPressed)
            .opacity(configuration.isPressed ? 0.8 : 1.0)
    }
}

struct PhysicalButtonStyle: ButtonStyle {
    let role: PhysicalButtonRole
    var isDisabled: Bool = false
    @State private var isHovered = false

    func makeBody(configuration: Configuration) -> some View {
        let isPressed = configuration.isPressed
        let scale = isPressed ? 0.85 : (isHovered ? 1.1 : 1.0)

        Group {
            switch role {
            case .primary:
                let bg: Color = isPressed ? Color(hex: "#2c6415") : (isHovered ? .white : Color(uiColor: ChatUIDesign.Color.offBlack))
                let fg: Color = isHovered && !isPressed ? Color(uiColor: ChatUIDesign.Color.offBlack) : .white

                configuration.label
                    .font(.system(size: 14, weight: .regular))
                    .foregroundStyle(isDisabled ? Color(uiColor: .systemGray2) : fg)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(isDisabled ? Color(uiColor: .tertiarySystemFill) : bg)
                    .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 4, style: .continuous)
                            .strokeBorder(isDisabled ? .clear : (isHovered && !isPressed ? Color(uiColor: ChatUIDesign.Color.offBlack) : .clear), lineWidth: 1)
                    )
            case .secondary:
                let bg: Color = isPressed ? Color(hex: "#2c6415") : (isHovered ? .white : .clear)
                let fg: Color = isPressed ? .white : Color(uiColor: ChatUIDesign.Color.offBlack)

                configuration.label
                    .font(.system(size: 14, weight: .regular))
                    .foregroundStyle(isDisabled ? Color(uiColor: .systemGray2) : fg)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(bg)
                    .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 4, style: .continuous)
                            .strokeBorder(isDisabled ? Color(uiColor: .systemGray2) : (isPressed ? .clear : Color(uiColor: ChatUIDesign.Color.offBlack)), lineWidth: 1)
                    )
            case .card:
                configuration.label
                    .font(.system(size: 14, weight: .regular))
                    .foregroundStyle(Color(uiColor: ChatUIDesign.Color.offBlack))
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                    .background(Color(uiColor: ChatUIDesign.Color.warmCream))
                    .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 4, style: .continuous)
                            .strokeBorder(Color(uiColor: ChatUIDesign.Color.oatBorder), lineWidth: 1)
                    )
            }
        }
        .scaleEffect(scale)
        .animation(.interactiveSpring(response: 0.3, dampingFraction: 0.6), value: isPressed)
        .animation(.interactiveSpring(response: 0.3, dampingFraction: 0.6), value: isHovered)
        .onHover { hovering in
            isHovered = hovering && !isDisabled
        }
    }
}

extension Color {
    init(hex: String) {
        let hex = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        var int: UInt64 = 0
        Scanner(string: hex).scanHexInt64(&int)
        let a, r, g, b: UInt64
        switch hex.count {
        case 3: // RGB (12-bit)
            (a, r, g, b) = (255, (int >> 8) * 17, (int >> 4 & 0xF) * 17, (int & 0xF) * 17)
        case 6: // RGB (24-bit)
            (a, r, g, b) = (255, int >> 16, int >> 8 & 0xFF, int & 0xFF)
        case 8: // ARGB (32-bit)
            (a, r, g, b) = (int >> 24, int >> 16 & 0xFF, int >> 8 & 0xFF, int & 0xFF)
        default:
            (a, r, g, b) = (1, 1, 1, 0)
        }

        self.init(
            .sRGB,
            red: Double(r) / 255,
            green: Double(g) / 255,
            blue: Double(b) / 255,
            opacity: Double(a) / 255
        )
    }
}
