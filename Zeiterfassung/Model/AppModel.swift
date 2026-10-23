// Zeiterfassung für Odoo
// Copyright (C) 2026 Baumgärtner Marketing GmbH
// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation
import Observation
import OSLog

/// Zustand und Abläufe der App: anmelden, Tag laden, buchen, stempeln.
@MainActor
@Observable
final class AppModel {
    enum Screen: Equatable {
        case starting
        case login
        case main
    }

    struct Draft: Equatable {
        var projectID: Int?
        var taskID: Int?
        var description = ""
        var durationText = ""
    }

    struct Notice: Equatable {
        enum Kind: Equatable {
            case offline
            case signedOut
            case failure
        }

        let kind: Kind
        let message: String
    }

    struct Hint: Equatable {
        let text: String
        let isProblem: Bool
    }

    enum TaskChoice: Equatable {
        case noProject
        case loading
        case noTasks
        case failed(String)
        case tasks([ProjectTask])
    }

    struct MenuBarContent: Equatable {
        var text: String
        var showsDot: Bool
        var isSignedIn: Bool
        var accessibilityLabel: String
    }

    struct AttendanceSummary: Equatable {
        struct Row: Identifiable, Equatable {
            let id: Int
            let range: String
            let duration: String
        }

        var title = ""
        var subtitle = ""
        var isRunning = false
        var buttonTitle: String?
        var rows: [Row] = []
        var unbookedText: String?
        var note: String?
    }

    // MARK: - Abhängigkeiten

    let preferences: Preferences
    @ObservationIgnored private let http: any HTTPClient
    @ObservationIgnored private let secrets: any SecretStore
    @ObservationIgnored private let calendar: Calendar
    @ObservationIgnored private let clock: @Sendable () -> Date
    @ObservationIgnored private var service: OdooService?
    /// Steigt mit jeder An- und Abmeldung. Was danach aus einer älteren Anfrage zurückkommt, wird verworfen.
    @ObservationIgnored private var sessionToken = 0
    @ObservationIgnored private var lastRefresh: Date?
    @ObservationIgnored private var lastRefreshAttempt: Date?
    @ObservationIgnored private var failedRefreshes = 0
    @ObservationIgnored private var lastProjectLoad: Date?
    @ObservationIgnored private var lastPanelClose: Date?
    @ObservationIgnored private var refreshGeneration = 0
    @ObservationIgnored private var appliedGeneration = 0
    @ObservationIgnored private var tickTask: Task<Void, Never>?
    @ObservationIgnored private var entryCache: [CalendarDay: [TimesheetEntry]] = [:]
    @ObservationIgnored private var periodCache: [CalendarDay: [AttendancePeriod]] = [:]
    @ObservationIgnored private var taskLoadDates: [Int: Date] = [:]
    @ObservationIgnored private var uncertainSave: UncertainSave?
    @ObservationIgnored private let logger = Logger(subsystem: "de.bm1.ZeiterfassungFuerOdoo", category: "model")

    /// Ein Eintrag, bei dem die Antwort von Odoo ausblieb: Vielleicht wurde er trotzdem angelegt.
    private struct UncertainSave {
        let request: TimesheetDraft
        /// Gleiche Einträge an diesem Tag vor dem Speichern.
        let matchesBefore: Int
    }

    // MARK: - Zustand

    private(set) var screen: Screen = .starting
    private(set) var session: OdooSession?
    private(set) var capabilities: Capabilities?
    private(set) var day: CalendarDay
    private(set) var now: Date
    private(set) var entries: [TimesheetEntry] = []
    private(set) var todayEntries: [TimesheetEntry] = []
    private(set) var periods: [AttendancePeriod] = []
    private(set) var todayPeriods: [AttendancePeriod] = []
    private(set) var openPeriod: AttendancePeriod?
    private(set) var loadedDays: Set<CalendarDay> = []
    private(set) var isLoading = false
    private(set) var notice: Notice?
    private(set) var projects: [Project] = []
    private(set) var recentProjectIDs: [Int] = []
    private(set) var tasksByProject: [Int: [ProjectTask]] = [:]
    private(set) var taskLoadError: String?
    var draft = Draft()
    private(set) var isSigningIn = false
    private(set) var isSaving = false
    private(set) var saveError: String?
    private(set) var isStamping = false
    private(set) var stampError: String?
    private(set) var isCheckingCapabilities = false

    init(preferences: Preferences, http: any HTTPClient, secrets: any SecretStore, calendar: Calendar = .gregorianLocal,
         clock: @escaping @Sendable () -> Date = { Date() }) {
        self.preferences = preferences
        self.http = http
        self.secrets = secrets
        self.calendar = calendar
        self.clock = clock
        let now = clock()
        self.now = now
        self.day = CalendarDay(date: now, calendar: calendar)
    }

    // MARK: - Start, Anmeldung, Abmeldung

    func start() async {
        startTicking()
        guard let session = preferences.session, let apiKey = secrets.read(account: session.keychainAccount) else {
            screen = .login
            return
        }
        self.session = session
        capabilities = preferences.cachedCapabilities
        service = makeService(session: session, apiKey: apiKey, schema: capabilities?.schema ?? Schema())
        screen = .main
        await refreshCapabilities()
        await refresh(force: true)
    }

    func stop() {
        tickTask?.cancel()
        tickTask = nil
    }

    /// Meldet an, prüft die Funktionen und legt den API-Schlüssel im Schlüsselbund ab.
    /// Die Hauptansicht erscheint erst mit `finishSignIn()`.
    @discardableResult
    func signIn(server: String, apiKey: String, login: String?, database: String?) async throws -> Capabilities {
        guard let url = ServerAddress.normalize(server) else { throw OdooError.invalidServerAddress }
        guard ServerAddress.isSecure(url) else { throw OdooError.insecureServerAddress }
        let key = apiKey.trimmed
        guard !key.isEmpty else { throw OdooError.unauthorized }
        isSigningIn = true
        defer { isSigningIn = false }

        let newSession = try await Connector(http: http).connect(serverURL: url, apiKey: key, login: login, database: database)
        var newService = makeService(session: newSession, apiKey: key, schema: Schema())
        let found = try await newService.discoverCapabilities()
        newService.schema = found.schema

        try secrets.save(key, account: newSession.keychainAccount, label: "\(AppInfo.name) – \(url.host() ?? url.absoluteString)")
        let accountChanged = session?.keychainAccount != newSession.keychainAccount
        if let previous = session, accountChanged {
            secrets.delete(account: previous.keychainAccount)
        }
        preferences.session = newSession
        preferences.cachedCapabilities = found
        // Die Datenbank nur merken, wenn sie eingegeben wurde. Sonst findet die App sie selbst wieder.
        preferences.loginHints = .init(server: url.absoluteString, login: newSession.login,
                                       database: database.flatMap { $0.trimmed.isEmpty ? nil : $0.trimmed })
        preferences.stampingRefused = false
        preferences.timesheetsEnabled = found.timesheets == .available || found.attendance != .available
        preferences.attendanceEnabled = found.attendance == .available

        session = newSession
        capabilities = found
        service = newService
        resetLoadedData()
        if accountChanged { draft = Draft() }
        return found
    }

    /// Nach „Fertig“ im Anmeldefenster.
    func finishSignIn() {
        screen = .main
        notice = nil
        Task { await refresh(force: true) }
    }

    /// Zur Anmeldung, etwa wenn der API-Schlüssel abgelaufen ist. Die Angaben bleiben vorausgefüllt.
    func showSignIn() {
        screen = .login
    }

    /// Aus der Anmeldung zurück geht es nur, wenn noch eine Verbindung besteht und gerade keine neue entsteht.
    var canCancelSignIn: Bool { session != nil && !isSigningIn }

    func cancelSignIn() {
        guard canCancelSignIn else { return }
        screen = .main
    }

    func signOut() {
        if let session { secrets.delete(account: session.keychainAccount) }
        preferences.session = nil
        preferences.cachedCapabilities = nil
        preferences.stampingRefused = false
        session = nil
        capabilities = nil
        service = nil
        resetLoadedData()
        draft = Draft()
        notice = nil
        screen = .login
    }

    // MARK: - Laden

    func panelDidOpen() async {
        now = clock()
        // Nach längerer Pause wieder mit heute beginnen.
        if let lastPanelClose, now.timeIntervalSince(lastPanelClose) > 600, day != today {
            show(today, refreshing: false)
        }
        // Aufgaben des gewählten Projekts auffrischen, falls sie schon älter sind.
        if let projectID = draft.projectID { Task { await loadTasks(projectID: projectID) } }
        await refresh(force: false)
    }

    func panelDidClose() {
        lastPanelClose = clock()
    }

    /// Prüft, welche Funktionen Odoo bietet. Mit `recheck` (auf Wunsch in den Einstellungen) wird
    /// auch ein Stempeln wieder angeboten, das Odoo früher abgelehnt hat.
    func refreshCapabilities(recheck: Bool = false) async {
        guard let service else { return }
        let token = sessionToken
        isCheckingCapabilities = true
        defer { isCheckingCapabilities = false }
        do {
            var found = try await service.discoverCapabilities()
            guard token == sessionToken else { return }
            if recheck { preferences.stampingRefused = false }
            if preferences.stampingRefused { found.canStamp = false }
            capabilities = found
            preferences.cachedCapabilities = found
            self.service?.schema = found.schema
        } catch {
            guard token == sessionToken else { return }
            handle(error)
        }
    }

    func refresh(force: Bool = false) async {
        guard screen == .main, let service else { return }
        now = clock()
        if !force, let lastRefresh, now.timeIntervalSince(lastRefresh) < 15 { return }

        refreshGeneration += 1
        let generation = refreshGeneration
        let request = LoadRequest(
            today: today, viewed: day, timesheets: timesheetsActive, attendance: attendanceActive,
            projects: timesheetsActive && (projects.isEmpty || lastProjectLoad.map { now.timeIntervalSince($0) > 600 } ?? true)
        )
        isLoading = true
        lastRefreshAttempt = now
        let snapshot = await Self.load(request, service: service, calendar: calendar)
        if generation == refreshGeneration { isLoading = false }
        // Ein älteres Ergebnis, das nach einem neueren eintrifft, wird verworfen, ebenso alles
        // von vor einer An- oder Abmeldung.
        guard generation > appliedGeneration else { return }
        appliedGeneration = generation
        let failures = apply(snapshot, for: request)
        if let failure = failures.min(by: { Self.weight(of: $0.error) < Self.weight(of: $1.error) }) {
            failedRefreshes += 1
            handle(failure.error, loading: failures.count < request.partCount ? failure.problem : nil)
        } else {
            failedRefreshes = 0
            lastRefresh = clock()
            if notice?.kind != .signedOut { notice = nil }
        }
    }

    private struct LoadRequest: Sendable {
        let today: CalendarDay
        let viewed: CalendarDay
        let timesheets: Bool
        let attendance: Bool
        let projects: Bool

        var partCount: Int { [timesheets, attendance, projects].filter { $0 }.count }
    }

    /// Geladene Teile; `nil`, wenn nicht angefragt.
    private struct Snapshot: Sendable {
        struct Timesheets: Sendable {
            var today: [TimesheetEntry]
            var viewed: [TimesheetEntry]
        }

        struct Attendance: Sendable {
            var today: [AttendancePeriod]
            var viewed: [AttendancePeriod]
            var open: AttendancePeriod?
        }

        struct Projects: Sendable {
            var list: [Project]
            var recentIDs: [Int]
        }

        var timesheets: Result<Timesheets, any Error>?
        var attendance: Result<Attendance, any Error>?
        var projects: Result<Projects, any Error>?
    }

    private struct LoadFailure {
        /// Was nicht geladen werden konnte, als ganzer Satz: „Anwesenheiten konnten nicht geladen werden.“
        let problem: String
        let error: any Error
    }

    /// Lädt Zeiteinträge, Anwesenheiten und Projekte gleichzeitig, aber getrennt:
    /// Scheitert ein Teil, erscheint der Rest trotzdem.
    private nonisolated static func load(_ request: LoadRequest, service: OdooService, calendar: Calendar) async -> Snapshot {
        let separateDay = request.viewed != request.today

        @Sendable func entries(_ day: CalendarDay, _ wanted: Bool) async throws -> [TimesheetEntry] {
            guard wanted else { return [] }
            return try await service.timesheets(on: day)
        }
        @Sendable func periods(_ day: CalendarDay, _ wanted: Bool) async throws -> [AttendancePeriod] {
            guard wanted else { return [] }
            return try await service.attendances(on: day, calendar: calendar)
        }
        @Sendable func timesheets() async throws -> Snapshot.Timesheets {
            async let today = entries(request.today, true)
            async let viewed = entries(request.viewed, separateDay)
            let todayEntries = try await today
            let viewedEntries = try await viewed
            return Snapshot.Timesheets(today: todayEntries, viewed: separateDay ? viewedEntries : todayEntries)
        }
        @Sendable func attendance() async throws -> Snapshot.Attendance {
            async let today = periods(request.today, true)
            async let viewed = periods(request.viewed, separateDay)
            async let open = service.openAttendance()
            let todayPeriods = try await today
            let viewedPeriods = try await viewed
            let openPeriod = try await open
            return Snapshot.Attendance(today: todayPeriods, viewed: separateDay ? viewedPeriods : todayPeriods,
                                       open: openPeriod)
        }
        @Sendable func projects() async throws -> Snapshot.Projects {
            async let list = service.projects()
            async let recent = service.recentProjectIDs(since: request.today.adding(days: -30, calendar: calendar))
            let projectList = try await list
            let recentIDs = try await recent
            return Snapshot.Projects(list: projectList, recentIDs: recentIDs)
        }

        async let loadedTimesheets = capture(request.timesheets, timesheets)
        async let loadedAttendance = capture(request.attendance, attendance)
        async let loadedProjects = capture(request.projects, projects)
        return await Snapshot(timesheets: loadedTimesheets, attendance: loadedAttendance, projects: loadedProjects)
    }

    private nonisolated static func capture<Value: Sendable>(
        _ wanted: Bool, _ work: @Sendable () async throws -> Value
    ) async -> Result<Value, any Error>? {
        guard wanted else { return nil }
        do {
            return .success(try await work())
        } catch {
            return .failure(error)
        }
    }

    /// Übernimmt, was geladen wurde, und meldet, was nicht.
    private func apply(_ snapshot: Snapshot, for request: LoadRequest) -> [LoadFailure] {
        var failures: [LoadFailure] = []
        let days: Set<CalendarDay> = [request.today, request.viewed]
        switch snapshot.timesheets {
        case .success(let part)?:
            todayEntries = part.today
            entryCache[request.today] = part.today
            entryCache[request.viewed] = part.viewed
            if request.viewed == day { entries = part.viewed }
            loadedDays.formUnion(days)
        case .failure(let error)?:
            failures.append(LoadFailure(problem: String(localized: "Zeiteinträge konnten nicht geladen werden."), error: error))
        case nil:
            break
        }
        switch snapshot.attendance {
        case .success(let part)?:
            todayPeriods = part.today
            openPeriod = part.open
            periodCache[request.today] = part.today
            periodCache[request.viewed] = part.viewed
            if request.viewed == day { periods = part.viewed }
            if !request.timesheets { loadedDays.formUnion(days) }
        case .failure(let error)?:
            failures.append(LoadFailure(problem: String(localized: "Anwesenheiten konnten nicht geladen werden."), error: error))
        case nil:
            break
        }
        switch snapshot.projects {
        case .success(let part)?:
            projects = part.list
            recentProjectIDs = part.recentIDs
            lastProjectLoad = clock()
            // Ein inzwischen geschlossenes Projekt nicht weiter zum Buchen anbieten.
            if let projectID = draft.projectID, !part.list.contains(where: { $0.id == projectID }) {
                draft.projectID = nil
                draft.taskID = nil
            }
        case .failure(let error)?:
            failures.append(LoadFailure(problem: String(localized: "Projekte konnten nicht geladen werden."), error: error))
        case nil:
            break
        }
        return failures
    }

    /// Vergisst alles Geladene, etwa nach einer An- oder Abmeldung. Was noch unterwegs ist, läuft ins Leere.
    private func resetLoadedData() {
        sessionToken += 1
        refreshGeneration += 1
        appliedGeneration = refreshGeneration
        isLoading = false
        isSaving = false
        isStamping = false
        entries = []
        todayEntries = []
        periods = []
        todayPeriods = []
        openPeriod = nil
        loadedDays = []
        entryCache = [:]
        periodCache = [:]
        projects = []
        recentProjectIDs = []
        tasksByProject = [:]
        taskLoadDates = [:]
        taskLoadError = nil
        uncertainSave = nil
        lastRefresh = nil
        lastRefreshAttempt = nil
        failedRefreshes = 0
        lastProjectLoad = nil
        saveError = nil
        stampError = nil
        day = today
    }

    /// Welcher Fehler zählt, wenn mehrere Teile scheitern: abgemeldet vor offline vor dem Rest.
    private static func weight(of error: any Error) -> Int {
        switch error as? OdooError {
        case .unauthorized?: return 0
        case .offline?: return 1
        default: return 2
        }
    }

    /// - Parameter problem: Was nicht geladen werden konnte, wenn der Rest geladen wurde.
    private func handle(_ error: any Error, loading problem: String? = nil) {
        if error is CancellationError { return }
        logger.error("Odoo: \(error.localizedDescription, privacy: .public)")
        switch error as? OdooError {
        case .unauthorized?:
            notice = Notice(kind: .signedOut, message: String(localized: "Die Anmeldung bei Odoo ist abgelaufen oder wurde widerrufen."))
        case .offline?:
            notice = Notice(kind: .offline, message: String(localized: "Odoo ist gerade nicht erreichbar."))
        default:
            let message = error.localizedDescription
            notice = Notice(kind: .failure, message: problem.map { "\($0) \(message)" } ?? message)
        }
    }

    static func message(for error: any Error) -> String {
        switch error as? OdooError {
        case .offline?:
            return String(localized: "Keine Verbindung zu Odoo. Deine Angaben bleiben erhalten.")
        case .some(let odooError):
            return odooError.localizedDescription
        case .none:
            return error.localizedDescription
        }
    }

    // MARK: - Uhr

    private func startTicking() {
        tickTask?.cancel()
        tickTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(20))
                await self?.tick()
            }
        }
    }

    /// Alle 20 Sekunden: Tageswechsel, regelmäßig neu laden, nach Fehlern erneut versuchen.
    func tick() async {
        let previousToday = today
        now = clock()
        if today != previousToday {
            if day == previousToday { show(today, refreshing: false) }
            await refresh(force: true)
        } else if isRefreshDue {
            await refresh(force: true)
        }
    }

    /// Alle fünf Minuten; nach einem Fehler früher, mit wachsendem Abstand (20 s, 40 s, 80 s … bis 5 min).
    /// Eine abgelaufene Anmeldung wird nicht wiederholt, sie braucht einen neuen Schlüssel.
    private var isRefreshDue: Bool {
        guard !isLoading, notice?.kind != .signedOut else { return false }
        if failedRefreshes == 0, let lastRefresh { return now.timeIntervalSince(lastRefresh) >= 300 }
        guard let lastRefreshAttempt else { return true }
        let wait = min(300, 20 << min(max(failedRefreshes - 1, 0), 4))
        return now.timeIntervalSince(lastRefreshAttempt) >= TimeInterval(wait)
    }

    // MARK: - Tage

    var today: CalendarDay { CalendarDay(date: now, calendar: calendar) }
    var isShowingToday: Bool { day == today }
    var isDayLoaded: Bool { loadedDays.contains(day) }

    func showPreviousDay() { show(day.adding(days: -1, calendar: calendar)) }
    func showNextDay() { show(day.adding(days: 1, calendar: calendar)) }
    func showToday() { show(today) }

    private func show(_ newDay: CalendarDay, refreshing: Bool = true) {
        guard newDay != day else { return }
        day = newDay
        entries = entryCache[newDay] ?? []
        periods = periodCache[newDay] ?? []
        saveError = nil
        stampError = nil
        if refreshing { Task { await refresh(force: true) } }
    }

    var dayTitle: String {
        if day == today { return String(localized: "Heute") }
        if day == today.adding(days: -1, calendar: calendar) { return String(localized: "Gestern") }
        if day == today.adding(days: 1, calendar: calendar) { return String(localized: "Morgen") }
        return Formatting.weekday(day)
    }

    var dayLongDate: String { Formatting.longDate(day) }
    var dayShortDate: String { Formatting.shortDate(day) }

    /// „Für heute ist noch nichts erfasst.“ – als ganzer Satz, weil sich die Sätze je Sprache anders bilden.
    var emptyDayMessage: String {
        if day == today { return String(localized: "Für heute ist noch nichts erfasst.") }
        if day == today.adding(days: -1, calendar: calendar) { return String(localized: "Für gestern ist noch nichts erfasst.") }
        return String(localized: "Für \(Formatting.shortDate(day)) ist noch nichts erfasst.")
    }

    // MARK: - Funktionen

    var timesheetsActive: Bool { preferences.timesheetsEnabled && capabilities?.timesheets == .available }
    var attendanceActive: Bool { preferences.attendanceEnabled && capabilities?.attendance == .available }
    var noFeatureActive: Bool { !timesheetsActive && !attendanceActive }

    /// Schaltet die Zeiterfassung. Die letzte aktive Funktion lässt sich nicht ausschalten.
    @discardableResult
    func setTimesheetsEnabled(_ enabled: Bool) -> Bool {
        if !enabled && timesheetsActive && !attendanceActive { return false }
        preferences.timesheetsEnabled = enabled
        Task { await refresh(force: true) }
        return true
    }

    /// Schaltet die Anwesenheit. Die letzte aktive Funktion lässt sich nicht ausschalten.
    @discardableResult
    func setAttendanceEnabled(_ enabled: Bool) -> Bool {
        if !enabled && attendanceActive && !timesheetsActive { return false }
        preferences.attendanceEnabled = enabled
        Task { await refresh(force: true) }
        return true
    }

    // MARK: - Zeiteinträge

    var bookedMinutes: Int { entries.reduce(0) { $0 + $1.minutes } }
    var todayBookedMinutes: Int { todayEntries.reduce(0) { $0 + $1.minutes } }

    var entryCountText: String { String(localized: "\(entries.count) Einträge") }

    func selectProject(_ project: Project) {
        guard draft.projectID != project.id else { return }
        draft.projectID = project.id
        draft.taskID = nil
        saveError = nil
        taskLoadError = nil
        Task { await loadTasks(projectID: project.id) }
    }

    /// Offene Aufgaben eines Projekts. Geladene gelten zehn Minuten, danach wird nachgeladen.
    func loadTasks(projectID: Int) async {
        if let tasks = tasksByProject[projectID] {
            preselect(tasks, for: projectID)
            if let loaded = taskLoadDates[projectID], clock().timeIntervalSince(loaded) < 600 { return }
        }
        guard let service else { return }
        let token = sessionToken
        do {
            let tasks = try await service.tasks(projectID: projectID)
            guard token == sessionToken else { return }
            tasksByProject[projectID] = tasks
            taskLoadDates[projectID] = clock()
            // Eine inzwischen erledigte Aufgabe nicht weiter vorschlagen.
            if draft.projectID == projectID, let taskID = draft.taskID, !tasks.contains(where: { $0.id == taskID }) {
                draft.taskID = nil
            }
            preselect(tasks, for: projectID)
        } catch {
            guard token == sessionToken else { return }
            // Schon geladene Aufgaben bleiben stehen, wenn nur das Nachladen scheitert.
            if draft.projectID == projectID, tasksByProject[projectID] == nil { taskLoadError = Self.message(for: error) }
        }
    }

    func retryTasks() {
        guard let projectID = draft.projectID else { return }
        taskLoadError = nil
        Task { await loadTasks(projectID: projectID) }
    }

    private func preselect(_ tasks: [ProjectTask], for projectID: Int) {
        guard draft.projectID == projectID, draft.taskID == nil, tasks.count == 1 else { return }
        draft.taskID = tasks[0].id
    }

    var taskChoice: TaskChoice {
        guard let projectID = draft.projectID else { return .noProject }
        if let tasks = tasksByProject[projectID] { return tasks.isEmpty ? .noTasks : .tasks(tasks) }
        if let taskLoadError { return .failed(taskLoadError) }
        return .loading
    }

    var selectedProjectName: String? {
        guard let projectID = draft.projectID else { return nil }
        return projects.first { $0.id == projectID }?.name
    }

    var selectedTaskName: String? {
        guard let projectID = draft.projectID, let taskID = draft.taskID else { return nil }
        return tasksByProject[projectID]?.first { $0.id == taskID }?.name
    }

    var durationResult: DurationInput.Result { DurationInput.parse(draft.durationText) }

    /// Minuten, die gebucht würden (ggf. auf Viertelstunden gerundet).
    var draftMinutes: Int? {
        guard case .minutes(let minutes) = durationResult, minutes > 0 else { return nil }
        return preferences.roundsToQuarterHour ? DurationInput.roundedToQuarterHour(minutes) : minutes
    }

    var durationHint: Hint? {
        switch durationResult {
        case .empty:
            return nil
        case .unreadable:
            return Hint(text: String(localized: "Bitte als 1:30, 1,5 oder 90 min eingeben."), isProblem: true)
        case .tooLong:
            return Hint(text: String(localized: "Höchstens 24 Stunden je Eintrag."), isProblem: true)
        case .minutes(let minutes):
            guard let booked = draftMinutes, booked != minutes else { return nil }
            return Hint(text: String(localized: "Wird als \(DurationInput.format(booked)) Std. gebucht."), isProblem: false)
        }
    }

    /// −/+: zur nächsten Viertelstunde in diese Richtung.
    func adjustDuration(by step: Int) {
        let current: Int
        if case .minutes(let minutes) = durationResult { current = minutes } else { current = 0 }
        let quarters = step > 0 ? current / 15 + 1 : (current + 14) / 15 - 1
        let minutes = max(0, quarters * 15)
        draft.durationText = minutes > 0 ? DurationInput.format(minutes) : ""
    }

    func normalizeDuration() {
        if let minutes = draftMinutes { draft.durationText = DurationInput.format(minutes) }
    }

    /// Ohne offene Aufgaben im Projekt darf ohne Aufgabe gebucht werden, wie in Odoo.
    var taskIsRequired: Bool { taskChoice != .noTasks }

    var canSave: Bool {
        timesheetsActive && !isSaving && draft.projectID != nil
            && (!taskIsRequired || draft.taskID != nil) && draftMinutes != nil
    }

    func save() async {
        guard canSave, let service, let projectID = draft.projectID, let minutes = draftMinutes else { return }
        let submitted = draft
        let request = TimesheetDraft(projectID: projectID, taskID: taskIsRequired ? draft.taskID : nil,
                                     description: draft.description.trimmed, minutes: minutes, day: day)
        let token = sessionToken
        isSaving = true
        saveError = nil
        do {
            let earlier = try await countMatches(of: request, service: service)
            var createdID: Int?
            if !earlier.arrivedEarlier {
                uncertainSave = UncertainSave(request: request, matchesBefore: earlier.count)
                createdID = try await service.createTimesheet(request)
            }
            guard token == sessionToken else { return }
            uncertainSave = nil
            if let createdID { insertSaved(createdID, request) }
            // Was während des Speicherns schon für den nächsten Eintrag getippt wurde, bleibt stehen.
            if draft.description == submitted.description { draft.description = "" }
            if draft.durationText == submitted.durationText { draft.durationText = "" }
            recentProjectIDs = [projectID] + recentProjectIDs.filter { $0 != projectID }
            isSaving = false
            await refresh(force: true)
        } catch {
            guard token == sessionToken else { return }
            isSaving = false
            if !Self.mayHaveArrived(error) { uncertainSave = nil }
            saveError = Self.message(for: error)
            if case .unauthorized? = error as? OdooError { handle(error) }
        }
    }

    /// Wie oft der Eintrag an seinem Tag schon vorkommt. Blieb beim letzten Versuch die Antwort von
    /// Odoo aus, wird frisch gezählt: Ist es einer mehr als vorher, kam der Eintrag doch an und wird
    /// nicht ein zweites Mal angelegt.
    private func countMatches(of request: TimesheetDraft,
                              service: OdooService) async throws -> (count: Int, arrivedEarlier: Bool) {
        if let pending = uncertainSave, pending.request == request {
            let current = Self.matches(of: request, in: try await service.timesheets(on: request.day))
            return (current, current > pending.matchesBefore)
        }
        if let cached = entryCache[request.day] { return (Self.matches(of: request, in: cached), false) }
        return (Self.matches(of: request, in: try await service.timesheets(on: request.day)), false)
    }

    private static func matches(of request: TimesheetDraft, in entries: [TimesheetEntry]) -> Int {
        entries.filter { entry in
            entry.project?.id == request.projectID && entry.task?.id == request.taskID
                && entry.description == request.description && abs(entry.minutes - request.minutes) <= 1
        }.count
    }

    /// Fehler, nach denen offen ist, ob Odoo die Anfrage noch ausgeführt hat.
    private static func mayHaveArrived(_ error: any Error) -> Bool {
        switch error as? OdooError {
        case .offline?, .server?, .unexpectedResponse?: return true
        default: return false
        }
    }

    /// Zeigt einen gerade angelegten Eintrag sofort, bis das Neuladen die Liste aus Odoo bringt.
    private func insertSaved(_ id: Int, _ request: TimesheetDraft) {
        guard id > 0, var list = entryCache[request.day] else { return }
        let project = projects.first { $0.id == request.projectID }.map { Reference(id: $0.id, name: $0.name) }
        let task = request.taskID.flatMap { taskID in tasksByProject[request.projectID]?.first { $0.id == taskID } }
            .map { Reference(id: $0.id, name: $0.name) }
        list.append(TimesheetEntry(id: id, description: request.description, project: project, task: task,
                                   minutes: request.minutes))
        entryCache[request.day] = list
        if request.day == day { entries = list }
        if request.day == today { todayEntries = list }
    }

    // MARK: - Anwesenheit

    /// Heutige Anwesenheiten samt einer offenen vom Vortag.
    var todayPeriodsIncludingOpen: [AttendancePeriod] {
        guard let openPeriod, !todayPeriods.contains(where: { $0.id == openPeriod.id }) else { return todayPeriods }
        return [openPeriod] + todayPeriods
    }

    var shownPeriods: [AttendancePeriod] { isShowingToday ? todayPeriodsIncludingOpen : periods }

    func attendanceMinutes(_ periods: [AttendancePeriod]) -> Int {
        periods.reduce(0) { $0 + $1.minutes(until: now) }
    }

    var todayAttendanceMinutes: Int { attendanceMinutes(todayPeriodsIncludingOpen) }

    var attendanceSummary: AttendanceSummary {
        let list = shownPeriods
        let total = attendanceMinutes(list)
        var summary = AttendanceSummary()
        if isShowingToday {
            if let openPeriod {
                summary.isRunning = true
                summary.title = String(localized: "Anwesend seit \(clockTime(openPeriod.checkIn))")
                let pause = pauseMinutes(list)
                let totalText = DurationInput.format(total)
                summary.subtitle = pause > 0
                    ? String(localized: "Heute \(totalText) Std. · Pause \(DurationInput.format(pause))")
                    : String(localized: "Heute \(totalText) Std.")
            } else if let checkOut = list.last?.checkOut {
                summary.title = String(localized: "Ausgestempelt um \(clockTime(checkOut))")
                summary.subtitle = String(localized: "Heute \(DurationInput.format(total)) Std.")
            } else {
                summary.title = String(localized: "Nicht eingestempelt")
                summary.subtitle = String(localized: "Heute noch keine Anwesenheit")
            }
            if capabilities?.canStamp == true {
                summary.buttonTitle = openPeriod == nil ? String(localized: "Einstempeln") : String(localized: "Ausstempeln")
            } else {
                let rights = String(localized: "Stempeln geht hier nur mit dem Odoo-Recht „Sachbearbeiter: Alle Anwesenheiten verwalten“ oder als eigener Anwesenheitsgenehmiger. Bis dahin in Odoo stempeln.")
                summary.note = preferences.stampingRefused ? String(localized: "Odoo hat das Stempeln abgelehnt.") + " " + rights : rights
            }
        } else if let first = list.first {
            summary.title = String(localized: "Anwesend \(clockTime(first.checkIn)) – \(list.last?.checkOut.map(clockTime) ?? String(localized: "jetzt"))")
            summary.subtitle = String(localized: "\(DurationInput.format(total)) Std.")
        } else {
            summary.title = String(localized: "Keine Anwesenheit erfasst")
            summary.subtitle = day > today ? String(localized: "Dieser Tag liegt in der Zukunft.") : String(localized: "An diesem Tag wurde nicht gestempelt.")
        }
        if !timesheetsActive {
            summary.rows = list.map { period in
                AttendanceSummary.Row(
                    id: period.id,
                    range: "\(clockTime(period.checkIn)) – \(period.checkOut.map(clockTime) ?? String(localized: "jetzt"))",
                    duration: String(localized: "\(DurationInput.format(period.minutes(until: now))) Std.")
                )
            }
        }
        if timesheetsActive, total > bookedMinutes {
            summary.unbookedText = String(localized: "\(DurationInput.format(total - bookedMinutes)) Std.")
        }
        return summary
    }

    /// Uhrzeit in der Zeitzone des Kalenders, mit dem die App auch die Tage rechnet.
    private func clockTime(_ date: Date) -> String {
        Formatting.time(date, calendar: calendar)
    }

    private func pauseMinutes(_ periods: [AttendancePeriod]) -> Int {
        zip(periods, periods.dropFirst()).reduce(0) { sum, pair in
            guard let checkOut = pair.0.checkOut else { return sum }
            return sum + max(0, Int(pair.1.checkIn.timeIntervalSince(checkOut) / 60))
        }
    }

    func toggleAttendance() async {
        guard let service, let capabilities, capabilities.canStamp, isShowingToday, !isStamping else { return }
        let token = sessionToken
        isStamping = true
        stampError = nil
        do {
            if let openPeriod {
                try await service.checkOut(attendanceID: openPeriod.id, at: clock())
            } else if let employeeID = capabilities.employeeID {
                try await service.checkIn(employeeID: employeeID, at: clock())
            } else {
                throw OdooError.rejected(String(localized: "Dein Odoo-Benutzer ist in deiner Hauptfirma mit keinem Mitarbeiter verknüpft."))
            }
            guard token == sessionToken else { return }
            isStamping = false
            await refresh(force: true)
        } catch {
            guard token == sessionToken else { return }
            isStamping = false
            switch error as? OdooError {
            case .accessDenied?:
                // Manche Rechte prüft Odoo erst beim Speichern. Der Knopf bleibt dann weg, bis die
                // Rechte in den Einstellungen erneut geprüft werden; der Hinweis erklärt, warum.
                preferences.stampingRefused = true
                self.capabilities?.canStamp = false
                preferences.cachedCapabilities = self.capabilities
            case .unauthorized?:
                stampError = error.localizedDescription
                handle(error)
            case .offline?:
                stampError = error.localizedDescription
            default:
                stampError = error.localizedDescription
                // Odoo hat abgelehnt, etwa weil die Anzeige veraltet war: den Stand aus Odoo holen.
                await refresh(force: true)
            }
        }
    }

    // MARK: - Menüleiste

    var effectiveMenuBarDisplay: Preferences.MenuBarDisplay {
        switch (timesheetsActive, attendanceActive) {
        case (true, true): return preferences.menuBarDisplay
        case (false, true): return .attendance
        default: return .booked
        }
    }

    var menuBarContent: MenuBarContent {
        guard screen == .main, session != nil else {
            return MenuBarContent(text: "", showsDot: false, isSignedIn: false,
                                  accessibilityLabel: String(localized: "\(AppInfo.name), nicht angemeldet"))
        }
        guard !noFeatureActive else {
            return MenuBarContent(text: "–", showsDot: false, isSignedIn: true, accessibilityLabel: AppInfo.name)
        }
        let booked = todayBookedMinutes
        let present = todayAttendanceMinutes
        var spoken: [String] = []
        let text: String
        switch effectiveMenuBarDisplay {
        case .booked:
            text = DurationInput.format(booked)
            spoken.append(String(localized: "heute \(DurationInput.spoken(booked)) gebucht"))
        case .attendance:
            text = DurationInput.format(present)
            spoken.append(String(localized: "heute \(DurationInput.spoken(present)) anwesend"))
        case .both:
            text = "\(DurationInput.format(booked)) · \(DurationInput.format(present))"
            spoken.append(String(localized: "heute \(DurationInput.spoken(booked)) gebucht"))
            spoken.append(String(localized: "\(DurationInput.spoken(present)) anwesend"))
        }
        let checkedIn = attendanceActive && openPeriod != nil
        if checkedIn { spoken.append(String(localized: "eingestempelt")) }
        return MenuBarContent(text: text, showsDot: checkedIn && preferences.showsCheckedInDot, isSignedIn: true,
                              accessibilityLabel: "\(AppInfo.name), " + spoken.joined(separator: ", "))
    }

    // MARK: - Konto

    var userName: String { capabilities?.userName ?? "" }

    var serverDisplay: String { session?.serverURL.host() ?? "" }

    var interfaceDisplay: String {
        guard let session else { return "" }
        let version = session.serverMajorVersion.map { "Odoo \($0)" } ?? "Odoo"
        return session.interface == .json2 ? "\(version) · JSON-2" : "\(version) · JSON-RPC"
    }

    /// Zeiterfassung oder Anwesenheiten im Browser.
    var odooWebURL: URL? {
        guard let session else { return nil }
        let attendanceOnly = attendanceActive && !timesheetsActive
        if (session.serverMajorVersion ?? 19) >= 18 {
            return session.serverURL.appending(path: attendanceOnly ? "odoo/attendances" : "odoo/timesheets")
        }
        let action = attendanceOnly ? "hr_attendance.hr_attendance_action" : "hr_timesheet.act_hr_timesheet_line"
        return URL(string: "\(session.serverURL.absoluteString)/web#action=\(action)")
    }

    private func makeService(session: OdooSession, apiKey: String, schema: Schema) -> OdooService {
        var context: [String: JSONValue] = [:]
        if let language = session.language { context["lang"] = .string(language) }
        return OdooService(transport: session.makeTransport(apiKey: apiKey, http: http), uid: session.uid,
                           context: context, schema: schema)
    }
}
