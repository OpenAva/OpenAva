import OpenClawKit
import SwiftUI
import UserNotifications

struct CronListView: View {
    @State private var jobs: [CronJobPayload] = []
    @State private var isLoading = false
    @State private var isShowingAddSheet = false
    #if targetEnvironment(macCatalyst)
        @State private var isShowingInlineEditor = false
    #endif
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
        Group {
            #if targetEnvironment(macCatalyst)
                Group {
                    if isShowingInlineEditor {
                        HStack(spacing: 0) {
                            cronList
                                .frame(minWidth: 300, idealWidth: 340)

                            cronDetail
                                .frame(maxWidth: .infinity, maxHeight: .infinity)
                                .background(Color.white)
                        }
                        .background(Color.white)
                    } else {
                        cronList
                    }
                }
                .navigationTitle(L10n.tr("settings.cron.navigationTitle"))
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .navigationBarTrailing) {
                        Button {
                            isShowingInlineEditor = true
                        } label: {
                            Label(L10n.tr("settings.cron.addJob"), systemImage: "plus")
                        }
                    }
                }
                .background(Color.white)
            #else
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
                            .buttonStyle(.bordered)
                        }
                    }
                    .sheet(isPresented: $isShowingAddSheet) {
                        NavigationStack {
                            CronAddJobSheet { draft in
                                Task {
                                    await createJob(draft)
                                }
                            } onCancel: {
                                isShowingAddSheet = false
                            }
                        }
                    }
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
        List {
            #if targetEnvironment(macCatalyst)
                Text(L10n.tr("settings.cron.scheduled.header"))
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .textCase(nil)
                    .listRowInsets(EdgeInsets(top: 12, leading: 12, bottom: 6, trailing: 12))
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)

                cronRows

                Text(scheduledFooterText)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .listRowInsets(EdgeInsets(top: 8, leading: 12, bottom: 10, trailing: 12))
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
            #else
                Section {
                    cronRows
                } header: {
                    Text(L10n.tr("settings.cron.scheduled.header"))
                } footer: {
                    Text(scheduledFooterText)
                }
            #endif
        }
        #if targetEnvironment(macCatalyst)
        .listStyle(.plain)
        #else
        .listStyle(.insetGrouped)
        #endif
        .scrollContentBackground(.hidden)
        .background(Color.white)
    }

    @ViewBuilder
    private var cronRows: some View {
        if isLoading, jobs.isEmpty {
            HStack {
                Spacer()
                ProgressView()
                Spacer()
            }
            .listRowInsets(EdgeInsets(top: 8, leading: 12, bottom: 8, trailing: 12))
            .listRowBackground(Color.clear)
            .listRowSeparator(.hidden)
        } else if jobs.isEmpty {
            EmptyCronJobsView()
                .listRowInsets(EdgeInsets(top: 8, leading: 12, bottom: 8, trailing: 12))
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
        } else {
            ForEach(jobs, id: \.id) { job in
                CronJobRow(job: job)
                    .listRowInsets(EdgeInsets(top: 6, leading: 12, bottom: 6, trailing: 12))
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
                    .swipeActions(edge: .trailing) {
                        Button(role: .destructive) {
                            jobToRemove = job
                        } label: {
                            Label(L10n.tr("common.delete"), systemImage: "trash")
                        }
                    }
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

    #if targetEnvironment(macCatalyst)
        @ViewBuilder
        private var cronDetail: some View {
            if isShowingInlineEditor {
                CronAddJobSheet(
                    onCreate: { draft in
                        Task {
                            await createJob(draft)
                        }
                    },
                    onCancel: {
                        isShowingInlineEditor = false
                    },
                    presentationStyle: .embedded
                )
            } else {
                ContentUnavailableView(
                    L10n.tr("settings.cron.navigationTitle"),
                    systemImage: "calendar.badge.clock",
                    description: Text(scheduledFooterText)
                )
            }
        }
    #endif

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
                everySeconds: draft.everySeconds
            )
            #if targetEnvironment(macCatalyst)
                isShowingInlineEditor = false
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

    @Environment(\.dismiss) private var dismiss

    @State private var message = ""
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
        Form {
            Section(L10n.tr("settings.cron.message.section")) {
                TextField(L10n.tr("settings.cron.message.placeholder"), text: $message, axis: .vertical)
                    .lineLimit(2 ... 4)
                    .settingsInputFieldStyle()
            }

            Section(L10n.tr("settings.cron.schedule.section")) {
                Picker(L10n.tr("settings.cron.schedule.mode"), selection: $mode) {
                    ForEach(ScheduleMode.allCases) { item in
                        Text(item.title).tag(item)
                    }
                }
                .pickerStyle(.segmented)

                if mode == .at {
                    DatePicker(L10n.tr("settings.cron.schedule.runAt"), selection: $atDate, in: Date().addingTimeInterval(60)..., displayedComponents: [.date, .hourAndMinute])
                        .settingsInputFieldStyle()
                } else {
                    Stepper(value: $everyMinutes, in: 1 ... 1440) {
                        Text(L10n.tr("settings.cron.schedule.everyMinutes", everyMinutes, everyMinutes == 1 ? "" : "s"))
                    }
                    .accessibilityIdentifier("cron_every_minutes")
                    .settingsInputFieldStyle()
                }
            }
        }
        #if targetEnvironment(macCatalyst)
        .scrollContentBackground(.hidden)
        .background(Color.white)
        #endif
        .navigationTitle(L10n.tr("settings.cron.newJob.title"))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button(L10n.tr("common.cancel")) {
                    cancelSheet()
                }
            }

            ToolbarItem(placement: .confirmationAction) {
                Button(L10n.tr("common.add")) {
                    onCreate(makeDraft())
                    cancelSheet()
                }
                .disabled(trimmedMessage.isEmpty)
            }
        }
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

    private func makeDraft() -> CronCreateDraft {
        switch mode {
        case .at:
            return CronCreateDraft(message: trimmedMessage, atDate: atDate, everySeconds: nil)
        case .every:
            return CronCreateDraft(message: trimmedMessage, atDate: nil, everySeconds: everyMinutes * 60)
        }
    }
}

private extension View {
    func settingsInputFieldStyle() -> some View {
        padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(
                Color(uiColor: .secondarySystemBackground),
                in: RoundedRectangle(cornerRadius: 10, style: .continuous)
            )
    }
}

private struct CronJobRow: View {
    let job: CronJobPayload

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
            Text(job.message)
                .font(.headline)
                .lineLimit(2)

            Text(scheduleText)
                .font(.subheadline)
                .foregroundStyle(.secondary)

            if let nextRunText {
                Text(L10n.tr("settings.cron.nextRun", nextRunText))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color(uiColor: .secondarySystemBackground))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.06), lineWidth: 0.6)
        )
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
                .foregroundStyle(.secondary)

            Text(L10n.tr("settings.cron.empty.title"))
                .font(.subheadline.weight(.semibold))

            Text(L10n.tr("settings.cron.empty.message"))
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, minHeight: 120)
        .padding()
    }
}

#Preview {
    NavigationStack {
        CronListView()
    }
}
