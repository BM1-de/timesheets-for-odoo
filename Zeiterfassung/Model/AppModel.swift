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
        /// Eine Anwesenheit oder die Pause zwischen zwei Anwesenheiten.
        struct Row: Identifiable, Equatable {
            enum Kind: Equatable {
                case period(AttendancePeriod)
                case gap(before: AttendancePeriod, after: AttendancePeriod)
            }

            let id: String
            let kind: Kind
            let range: String
            let duration: String
            /// Odoo hat selbst ausgestempelt; die echte Zeit sollte jemand eintragen.
            var isAutoCheckOut = false
            /// Pause, die das Modul Arbeitszeitgesetz eingefügt hat.
            var isInsertedBreak = false
        }

        var title = ""
        var subtitle = ""
        var isRunning = false
        var buttonTitle: String?
        var rows: [Row] = []
        var unbookedText: String?
        var note: String?
        /// Was in den Zeiten des Tages Aufmerksamkeit braucht, für die zugeklappte Liste.
        var attention: String?
        /// Zeiten lassen sich korrigieren, nachtragen und löschen.
        var canEdit = false
        /// Vergangener Tag ohne Anwesenheit: „Nachtragen …“ im Kopf.
        var offersAdding = false
    }

    /// Bearbeiten einer Anwesenheit direkt in der Liste.
    struct AttendanceEditor: Equatable {
        enum Kind: Equatable {
            /// Beginn und Ende einer Anwesenheit
            case period(AttendancePeriod)
            /// Pause zwischen zwei Anwesenheiten: das Ende der ersten und der Beginn der zweiten
            case gap(before: AttendancePeriod, after: AttendancePeriod)
            /// Vergessene Anwesenheit nachtragen
            case add
        }

        var kind: Kind
        var from: String
        var to: String
        var error: String?
    }

    /// Ergebnis nach dem Sichern einer Anwesenheit, unter der Liste.
    struct AttendanceNotice: Equatable {
        enum Kind: Equatable {
            case done
            /// Odoo hat danach selbst etwas geändert, etwa eine Pause eingefügt.
            case info
            case warning
        }

        let kind: Kind
        let text: String
    }

    /// Wartet auf die Bestätigung im Fenster.
    enum Deletion: Equatable {
        case entry(TimesheetEntry)
        case period(AttendancePeriod)
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
    /// Was im Formular für einen neuen Eintrag stand, bevor ein bestehender zum Bearbeiten geöffnet wurde.
    @ObservationIgnored private var draftBeforeEditing: Draft?
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
    /// Eintrag, der gerade im Formular bearbeitet wird; `nil` beim Anlegen eines neuen.
    private(set) var editingEntry: TimesheetEntry?
    /// Tag, auf den der bearbeitete Eintrag gebucht ist; lässt sich ändern.
    var editDay: CalendarDay
    var attendanceEditor: AttendanceEditor?
    private(set) var isSavingAttendance = false
    private(set) var attendanceNotice: AttendanceNotice?
    /// Auf- oder zugeklappt von Hand; `nil` heißt: aufklappen, wenn etwas zu prüfen ist.
    private(set) var isAttendanceListExpanded: Bool?
    private(set) var pendingDeletion: Deletion?
    private(set) var isDeleting = false

    init(preferences: Preferences, http: any HTTPClient, secrets: any SecretStore, calendar: Calendar = .gregorianLocal,
         clock: @escaping @Sendable () -> Date = { Date() }) {
        self.preferences = preferences
        self.http = http
        self.secrets = secrets
        self.calendar = calendar
        self.clock = clock
        let now = clock()
        let today = CalendarDay(date: now, calendar: calendar)
        self.now = now
        self.day = today
        self.editDay = today
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
        // „demo“ führt zum Demo-Server im Arbeitsspeicher, mit dessen festem Schlüssel.
        let isDemo = DemoServer.isRequested(server)
        guard let url = isDemo ? DemoServer.url : ServerAddress.normalize(server) else { throw OdooError.invalidServerAddress }
        guard ServerAddress.isSecure(url) else { throw OdooError.insecureServerAddress }
        let key = isDemo ? DemoServer.apiKey : apiKey.trimmed
        guard !key.isEmpty else { throw OdooError.unauthorized }
        let database = isDemo ? nil : database
        isSigningIn = true
        defer { isSigningIn = false }

        let newSession = try await Connector(http: http).connect(serverURL: url, apiKey: key, login: isDemo ? nil : login,
                                                                  database: database)
        var newService = makeService(session: newSession, apiKey: key, schema: Schema())
        let accountChanged = session?.keychainAccount != newSession.keychainAccount
        let found = try await newService.discoverCapabilities(
            attendanceEmployeeID: accountChanged ? nil : preferences.attendanceEmployeeID
        )
        newService.schema = found.schema

        try secrets.save(key, account: newSession.keychainAccount, label: "\(AppInfo.name) – \(url.host() ?? url.absoluteString)")
        if accountChanged { preferences.attendanceEmployeeID = nil }
        if let previous = session, accountChanged {
            secrets.delete(account: previous.keychainAccount)
        }
        preferences.session = newSession
        preferences.cachedCapabilities = found
        // Die Datenbank nur merken, wenn sie eingegeben wurde. Sonst findet die App sie selbst wieder.
        preferences.loginHints = .init(server: isDemo ? "demo" : url.absoluteString, login: newSession.login,
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
        preferences.attendanceEmployeeID = nil
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
            var found = try await service.discoverCapabilities(attendanceEmployeeID: preferences.attendanceEmployeeID)
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
            projects: timesheetsActive && (projects.isEmpty || lastProjectLoad.map { now.timeIntervalSince($0) > 600 } ?? true),
            attendanceEmployeeID: capabilities?.employeeID
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
        /// Mit Mitarbeitern in mehreren Firmen nur die Anwesenheiten dessen, mit dem gestempelt wird.
        let attendanceEmployeeID: Int?

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
            return try await service.attendances(on: day, employeeID: request.attendanceEmployeeID, calendar: calendar)
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
            async let open = service.openAttendance(employeeID: request.attendanceEmployeeID)
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
            // Ein inzwischen geschlossenes Projekt nicht weiter zum Buchen anbieten. Ein bearbeiteter Eintrag
            // behält sein Projekt.
            if let projectID = draft.projectID, !part.list.contains(where: { $0.id == projectID }),
               editingEntry?.project?.id != projectID {
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
        if editingEntry != nil { draft = draftBeforeEditing ?? Draft() }
        editingEntry = nil
        draftBeforeEditing = nil
        attendanceEditor = nil
        attendanceNotice = nil
        isAttendanceListExpanded = nil
        isSavingAttendance = false
        pendingDeletion = nil
        isDeleting = false
        day = today
        editDay = today
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

    /// Ein anderer Tag beendet, was gerade bearbeitet wird.
    private func show(_ newDay: CalendarDay, refreshing: Bool = true) {
        guard newDay != day else { return }
        cancelEditing()
        attendanceEditor = nil
        attendanceNotice = nil
        isAttendanceListExpanded = nil
        pendingDeletion = nil
        day = newDay
        editDay = newDay
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
            // Eine inzwischen erledigte Aufgabe nicht weiter vorschlagen, außer beim Bearbeiten des Eintrags,
            // der auf ihr steht.
            if draft.projectID == projectID, let taskID = draft.taskID, !tasks.contains(where: { $0.id == taskID }),
               !(editingEntry?.project?.id == projectID && editingEntry?.task?.id == taskID) {
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

    /// Die einzige Aufgabe gleich wählen. Ein bearbeiteter Eintrag behält, was er hat.
    private func preselect(_ tasks: [ProjectTask], for projectID: Int) {
        guard draft.projectID == projectID, draft.taskID == nil, tasks.count == 1,
              editingEntry?.project?.id != projectID else { return }
        draft.taskID = tasks[0].id
    }

    var taskChoice: TaskChoice {
        guard let projectID = draft.projectID else { return .noProject }
        if var tasks = tasksByProject[projectID] {
            // Beim Bearbeiten bleibt die Aufgabe des Eintrags wählbar, auch wenn sie inzwischen erledigt ist.
            if let entry = editingEntry, entry.project?.id == projectID, let task = entry.task,
               !tasks.contains(where: { $0.id == task.id }) {
                tasks.insert(ProjectTask(id: task.id, name: task.name), at: 0)
            }
            return tasks.isEmpty ? .noTasks : .tasks(tasks)
        }
        if let taskLoadError { return .failed(taskLoadError) }
        return .loading
    }

    /// Name des gewählten Projekts. Beim Bearbeiten auch dann, wenn das Projekt des Eintrags nicht mehr
    /// zum Buchen angeboten wird, etwa weil es archiviert ist.
    var selectedProjectName: String? {
        guard let projectID = draft.projectID else { return nil }
        if let project = projects.first(where: { $0.id == projectID }) { return project.name }
        if let entry = editingEntry, entry.project?.id == projectID { return entry.project?.name }
        return nil
    }

    var selectedTaskName: String? {
        guard let projectID = draft.projectID, let taskID = draft.taskID else { return nil }
        if let task = tasksByProject[projectID]?.first(where: { $0.id == taskID }) { return task.name }
        if let entry = editingEntry, entry.task?.id == taskID { return entry.task?.name }
        return nil
    }

    var durationResult: DurationInput.Result { DurationInput.parse(draft.durationText) }

    /// Minuten, die gebucht würden (ggf. gerundet, siehe Einstellungen). Beim Bearbeiten bleibt eine
    /// unveränderte Dauer minutengenau, wie sie in Odoo steht.
    var draftMinutes: Int? {
        guard case .minutes(let minutes) = durationResult, minutes > 0 else { return nil }
        if let editingEntry, draft.durationText == DurationInput.format(editingEntry.minutes) { return editingEntry.minutes }
        guard let unit = preferences.durationRounding.minutes else { return minutes }
        return DurationInput.rounded(minutes, toNearest: unit)
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

    /// −/+: zur nächsten Stufe in diese Richtung; die Stufe ist die Einheit der Rundung, ohne Rundung
    /// eine Viertelstunde.
    func adjustDuration(by direction: Int) {
        let current: Int
        if case .minutes(let minutes) = durationResult { current = minutes } else { current = 0 }
        let minutes = DurationInput.stepped(current, by: direction, unit: preferences.durationRounding.step)
        draft.durationText = minutes > 0 ? DurationInput.format(minutes) : ""
    }

    func normalizeDuration() {
        if let minutes = draftMinutes { draft.durationText = DurationInput.format(minutes) }
    }

    /// Ohne offene Aufgaben im Projekt darf ohne Aufgabe gebucht werden, wie in Odoo. Ein Eintrag, der
    /// schon ohne Aufgabe gebucht ist, darf so bleiben.
    var taskIsRequired: Bool {
        if let entry = editingEntry, entry.task == nil, draft.projectID == entry.project?.id { return false }
        return taskChoice != .noTasks
    }

    var canSave: Bool {
        guard timesheetsActive, !isSaving else { return false }
        switch editingEntry?.lock {
        case .validated?: return false
        case .invoiced?: return true
        case nil: break
        }
        return draft.projectID != nil && (!taskIsRequired || draft.taskID != nil) && draftMinutes != nil
    }

    func save() async {
        if editingEntry != nil {
            await saveEditing()
            return
        }
        guard canSave, let service, let projectID = draft.projectID, let minutes = draftMinutes else { return }
        if let organization, let project = projects.first(where: { $0.id == projectID }), organization.lacksEmployee(for: project) {
            saveError = missingEmployeeMessage(for: project)
            return
        }
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
        let project = projects.first { $0.id == request.projectID }
        let task = request.taskID.flatMap { taskID in tasksByProject[request.projectID]?.first { $0.id == taskID } }
            .map { Reference(id: $0.id, name: $0.name) }
        list.append(TimesheetEntry(id: id, description: request.description,
                                   project: project.map { Reference(id: $0.id, name: $0.name) }, task: task,
                                   minutes: request.minutes, day: request.day,
                                   companyID: project?.companyID ?? organization?.mainCompanyID))
        entryCache[request.day] = list
        if request.day == day { entries = list }
        if request.day == today { todayEntries = list }
    }

    // MARK: - Bearbeiten

    /// Öffnet einen Eintrag im Formular. Was dort für einen neuen Eintrag stand, kommt danach zurück.
    func beginEditing(_ entry: TimesheetEntry) {
        guard timesheetsActive, !isSaving, editingEntry?.id != entry.id else { return }
        if editingEntry == nil { draftBeforeEditing = draft }
        editingEntry = entry
        editDay = entry.day ?? day
        draft = Draft(projectID: entry.project?.id, taskID: entry.task?.id, description: entry.description,
                      durationText: DurationInput.format(entry.minutes))
        saveError = nil
        taskLoadError = nil
        if let projectID = entry.project?.id { Task { await loadTasks(projectID: projectID) } }
    }

    func cancelEditing() {
        guard editingEntry != nil else { return }
        finishEditing()
    }

    private func finishEditing() {
        editingEntry = nil
        draft = draftBeforeEditing ?? Draft()
        draftBeforeEditing = nil
        editDay = day
        saveError = nil
        taskLoadError = nil
    }

    /// Abgerechnet: Nur die Beschreibung lässt sich noch ändern.
    var editingIsLimited: Bool { editingEntry?.lock == .invoiced }
    /// Freigegeben: Nichts lässt sich mehr ändern.
    var editingIsLocked: Bool { editingEntry?.lock == .validated }

    /// Tage, auf die sich ein Eintrag legen lässt: die letzte Woche und sein eigener Tag.
    var editDayChoices: [CalendarDay] {
        var days = (0...6).map { today.adding(days: -$0, calendar: calendar) }
        for extra in [editingEntry?.day, editDay].compactMap({ $0 }) where !days.contains(extra) { days.append(extra) }
        return days.sorted(by: >)
    }

    func dayChoiceTitle(_ choice: CalendarDay) -> String {
        if choice == today { return String(localized: "Heute, \(Formatting.shortDate(choice))") }
        if choice == today.adding(days: -1, calendar: calendar) { return String(localized: "Gestern, \(Formatting.shortDate(choice))") }
        return Formatting.shortDate(choice)
    }

    private func saveEditing() async {
        guard let entry = editingEntry, let service, canSave else { return }
        let limited = editingIsLimited
        let projectID = limited ? entry.project?.id ?? 0 : draft.projectID ?? 0
        let request = TimesheetDraft(
            projectID: projectID,
            taskID: limited ? entry.task?.id : (taskChoice == .noTasks ? nil : draft.taskID),
            description: draft.description.trimmed,
            minutes: limited ? entry.minutes : draftMinutes ?? entry.minutes,
            day: limited ? entry.day ?? editDay : editDay
        )
        var employeeID: Int?
        if !limited, let organization, projectID != entry.project?.id, let project = projects.first(where: { $0.id == projectID }) {
            if organization.lacksEmployee(for: project) {
                saveError = missingEmployeeMessage(for: project)
                return
            }
            // Wechselt das Projekt die Firma, gehört der Eintrag dem Mitarbeiter der neuen Firma, wie beim
            // Anlegen. Bei einem Projekt ohne Firma bleibt der Eintrag in seiner Firma.
            if let employee = organization.employee(in: project.companyID ?? entry.companyID), employee.id != entry.employeeID {
                employeeID = employee.id
            }
        }
        let token = sessionToken
        isSaving = true
        saveError = nil
        do {
            try await service.updateTimesheet(id: entry.id, to: request, descriptionOnly: limited, employeeID: employeeID)
            guard token == sessionToken else { return }
            isSaving = false
            replaceEntry(entry, with: request)
            if request.projectID != entry.project?.id {
                recentProjectIDs = [request.projectID] + recentProjectIDs.filter { $0 != request.projectID }
            }
            finishEditing()
            await refresh(force: true)
        } catch {
            guard token == sessionToken else { return }
            isSaving = false
            saveError = Self.message(for: error)
            if case .unauthorized? = error as? OdooError { handle(error) }
        }
    }

    /// Zeigt eine Änderung sofort, bis das Neuladen den Stand aus Odoo bringt. Mit neuem Datum
    /// wandert der Eintrag auf den anderen Tag.
    private func replaceEntry(_ entry: TimesheetEntry, with request: TimesheetDraft) {
        let project = projects.first { $0.id == request.projectID }
        let projectReference = project.map { Reference(id: $0.id, name: $0.name) } ?? entry.project
        let task = request.taskID.flatMap { taskID in
            tasksByProject[request.projectID]?.first { $0.id == taskID }.map { Reference(id: $0.id, name: $0.name) }
                ?? (entry.task?.id == taskID ? entry.task : nil)
        }
        let companyID = request.projectID == entry.project?.id ? entry.companyID : project?.companyID ?? entry.companyID
        let updated = TimesheetEntry(id: entry.id, description: request.description, project: projectReference, task: task,
                                     minutes: request.minutes, day: request.day, lock: entry.lock, companyID: companyID,
                                     employeeID: entry.employeeID)
        for (cachedDay, list) in entryCache {
            guard let index = list.firstIndex(where: { $0.id == entry.id }) else { continue }
            var changed = list
            if cachedDay == request.day { changed[index] = updated } else { changed.remove(at: index) }
            entryCache[cachedDay] = changed
        }
        if var target = entryCache[request.day], !target.contains(where: { $0.id == entry.id }) {
            target.append(updated)
            entryCache[request.day] = target
        }
        entries = entryCache[day] ?? entries
        todayEntries = entryCache[today] ?? todayEntries
    }

    private func removeEntry(_ id: Int) {
        for (cachedDay, list) in entryCache { entryCache[cachedDay] = list.filter { $0.id != id } }
        entries.removeAll { $0.id == id }
        todayEntries.removeAll { $0.id == id }
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
        summary.canEdit = canEditAttendance
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
                let rights = String(localized: "Stempeln geht hier nur mit dem Odoo-Recht „Sachbearbeiter: Alle Anwesenheiten verwalten“ oder als eigener Anwesenheitsgenehmiger. Bis dahin in Odoo stempeln; Korrekturen trägt die für Anwesenheiten zuständige Person ein.")
                summary.note = preferences.stampingRefused ? String(localized: "Odoo hat das Stempeln abgelehnt.") + " " + rights : rights
            }
        } else if let first = list.first {
            summary.title = String(localized: "Anwesend \(clockTime(first.checkIn)) – \(list.last?.checkOut.map(clockTime) ?? String(localized: "jetzt"))")
            summary.subtitle = String(localized: "\(DurationInput.format(total)) Std.")
            if !summary.canEdit {
                summary.note = String(localized: "Deine Anwesenheiten kannst du hier nicht ändern. Korrekturen trägt die für Anwesenheiten zuständige Person in Odoo ein.")
            }
        } else {
            summary.title = String(localized: "Keine Anwesenheit erfasst")
            summary.subtitle = day > today ? String(localized: "Dieser Tag liegt in der Zukunft.") : String(localized: "An diesem Tag wurde nicht gestempelt.")
            summary.offersAdding = summary.canEdit && day < today
        }
        summary.rows = attendanceRows(list)
        if summary.rows.contains(where: \.isAutoCheckOut) {
            summary.attention = String(localized: "Automatisch beendet")
        } else if summary.rows.contains(where: \.isInsertedBreak) {
            summary.attention = String(localized: "Pause eingefügt")
        }
        if timesheetsActive, total > bookedMinutes {
            summary.unbookedText = String(localized: "\(DurationInput.format(total - bookedMinutes)) Std.")
        }
        return summary
    }

    /// Anwesenheiten ändern, nachtragen und löschen darf, wer auch stempeln darf.
    var canEditAttendance: Bool { attendanceActive && capabilities?.canStamp == true }

    /// „Zeiten des Tages“: aufgeklappt, wenn gewünscht oder wenn etwas zu prüfen ist.
    var showsAttendanceList: Bool {
        isAttendanceListExpanded ?? (attendanceSummary.attention != nil)
    }

    func setAttendanceListExpanded(_ expanded: Bool) {
        isAttendanceListExpanded = expanded
        if !expanded { attendanceEditor = nil }
    }

    /// Die Anwesenheiten des Tages und dazwischen die Pausen.
    private func attendanceRows(_ list: [AttendancePeriod]) -> [AttendanceSummary.Row] {
        let hasBreakModule = capabilities?.schema.breakRules != nil
        var rows: [AttendanceSummary.Row] = []
        for (index, period) in list.enumerated() {
            if index > 0, let checkOut = list[index - 1].checkOut {
                let minutes = Int(period.checkIn.timeIntervalSince(checkOut) / 60)
                if minutes > 0 {
                    rows.append(AttendanceSummary.Row(
                        id: "pause-\(list[index - 1].id)-\(period.id)", kind: .gap(before: list[index - 1], after: period),
                        range: String(localized: "Pause \(clockTime(checkOut)) – \(clockTime(period.checkIn))"),
                        duration: DurationInput.format(minutes),
                        isInsertedBreak: hasBreakModule && period.isTechnical
                    ))
                }
            }
            rows.append(AttendanceSummary.Row(
                id: "zeit-\(period.id)", kind: .period(period),
                range: "\(clockTime(period.checkIn)) – \(period.checkOut.map(clockTime) ?? String(localized: "jetzt"))",
                duration: DurationInput.format(period.minutes(until: now)),
                isAutoCheckOut: period.isAutoCheckOut
            ))
        }
        return rows
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
                markStampingRefused()
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

    /// Manche Rechte prüft Odoo erst beim Speichern. Stempeln und Korrigieren bleiben dann weg, bis
    /// die Rechte in den Einstellungen erneut geprüft werden; der Hinweis erklärt, warum.
    private func markStampingRefused() {
        preferences.stampingRefused = true
        capabilities?.canStamp = false
        preferences.cachedCapabilities = capabilities
        attendanceEditor = nil
    }

    // MARK: - Anwesenheit korrigieren

    func editPeriod(_ period: AttendancePeriod) {
        guard canEditAttendance else { return }
        openAttendanceEditor(AttendanceEditor(kind: .period(period), from: clockTime(period.checkIn),
                                              to: period.checkOut.map(clockTime) ?? ""))
    }

    func editGap(before: AttendancePeriod, after: AttendancePeriod) {
        guard canEditAttendance, let checkOut = before.checkOut else { return }
        openAttendanceEditor(AttendanceEditor(kind: .gap(before: before, after: after), from: clockTime(checkOut),
                                              to: clockTime(after.checkIn)))
    }

    /// Eine vergessene Anwesenheit nachtragen, auch an Tagen ganz ohne.
    func addAttendancePeriod() {
        guard canEditAttendance, day <= today else { return }
        openAttendanceEditor(AttendanceEditor(kind: .add, from: "", to: ""))
    }

    private func openAttendanceEditor(_ editor: AttendanceEditor) {
        attendanceEditor = editor
        attendanceNotice = nil
        isAttendanceListExpanded = true
    }

    func cancelAttendanceEditing() {
        attendanceEditor = nil
    }

    func dismissAttendanceNotice() {
        attendanceNotice = nil
    }

    /// Was Sichern in Odoo schreibt, in dieser Reihenfolge.
    private enum AttendanceWrite {
        case update(id: Int, checkIn: Date?, checkOut: Date?, confirmsCheckIn: Bool, confirmsCheckOut: Bool)
        case add(from: Date, to: Date)
    }

    private struct AttendanceProblem: Error {
        let message: String
    }

    /// Prüft die Eingaben wie Odoo und plant das Schreiben. Eine Pause zu verschieben ändert zwei
    /// Anwesenheiten; zuerst die, die Platz macht, sonst lehnt Odoo die Überschneidung ab.
    private func attendancePlan(for editor: AttendanceEditor) -> Result<[AttendanceWrite], AttendanceProblem> {
        let unreadable = AttendanceProblem(message: String(localized: "Bitte Uhrzeiten wie 8:30 oder 830 eingeben."))
        switch editor.kind {
        case .period(let period):
            guard let from = resolveTime(editor.from, original: period.checkIn) else { return .failure(unreadable) }
            var to: Date?
            if !period.isOpen {
                guard let end = resolveTime(editor.to, original: period.checkOut) else { return .failure(unreadable) }
                to = end
            }
            if let problem = problem(from: from, to: to, excluding: period.id) { return .failure(problem) }
            let movesCheckIn = from != period.checkIn
            let movesCheckOut = to != period.checkOut
            guard movesCheckIn || movesCheckOut || period.isAutoCheckOut else { return .success([]) }
            return .success([.update(id: period.id, checkIn: movesCheckIn ? from : nil, checkOut: movesCheckOut ? to : nil,
                                     confirmsCheckIn: movesCheckIn && period.isTechnical,
                                     confirmsCheckOut: period.isAutoCheckOut)])
        case .gap(let before, let after):
            guard let start = before.checkOut, let from = resolveTime(editor.from, original: start),
                  let to = resolveTime(editor.to, original: after.checkIn) else { return .failure(unreadable) }
            guard to > from else {
                return .failure(AttendanceProblem(message: String(localized: "Das Ende der Pause muss nach dem Beginn liegen.")))
            }
            guard from > before.checkIn, to < (after.checkOut ?? now) else {
                let end = after.checkOut.map(clockTime) ?? String(localized: "jetzt")
                return .failure(AttendanceProblem(message: String(localized: "Die Pause muss zwischen \(clockTime(before.checkIn)) und \(end) liegen.")))
            }
            var first: [AttendanceWrite] = []
            var second: [AttendanceWrite] = []
            if from != start {
                first.append(.update(id: before.id, checkIn: nil, checkOut: from, confirmsCheckIn: false,
                                     confirmsCheckOut: before.outMode == "technical"))
            }
            if to != after.checkIn {
                second.append(.update(id: after.id, checkIn: to, checkOut: nil, confirmsCheckIn: after.isTechnical,
                                      confirmsCheckOut: false))
            }
            return .success(to > after.checkIn ? second + first : first + second)
        case .add:
            guard let from = resolveTime(editor.from, original: nil), let to = resolveTime(editor.to, original: nil) else {
                return .failure(unreadable)
            }
            if let problem = problem(from: from, to: to, excluding: nil) { return .failure(problem) }
            return .success([.add(from: from, to: to)])
        }
    }

    /// Reihenfolge, Zukunft und Überschneidung mit den anderen Anwesenheiten des Tages.
    private func problem(from: Date, to: Date?, excluding id: Int?) -> AttendanceProblem? {
        if let to, to <= from { return AttendanceProblem(message: String(localized: "Das Ende muss nach dem Beginn liegen.")) }
        if from > now || (to ?? from) > now { return AttendanceProblem(message: String(localized: "Die Zeit liegt in der Zukunft.")) }
        let end = to ?? now
        if let other = shownPeriods.first(where: { $0.id != id && from < ($0.checkOut ?? now) && end > $0.checkIn }) {
            let range = "\(clockTime(other.checkIn)) – \(other.checkOut.map(clockTime) ?? String(localized: "jetzt"))"
            return AttendanceProblem(message: String(localized: "Überschneidet sich mit \(range)."))
        }
        return nil
    }

    /// Uhrzeit aus dem Feld am angezeigten Tag. Unverändert bleibt die Zeit aus Odoo, sekundengenau
    /// und auch dann, wenn sie an einem anderen Tag liegt, etwa nach Mitternacht.
    private func resolveTime(_ text: String, original: Date?) -> Date? {
        if let original, text.trimmed == clockTime(original) { return original }
        guard let minutes = ClockInput.minutes(from: text) else { return nil }
        return calendar.date(bySettingHour: minutes / 60, minute: minutes % 60, second: 0,
                             of: day.startDate(calendar: calendar))
    }

    /// Unter den Feldern einer Pause: was Sichern bewirkt, mit dem Modul Arbeitszeitgesetz auch, ob
    /// die Pause reicht. Was gilt, entscheidet Odoo beim Speichern.
    var attendanceEditorHint: Hint? {
        guard let editor = attendanceEditor, case .gap(let before, let after) = editor.kind else { return nil }
        guard let rules = capabilities?.schema.breakRules else {
            return Hint(text: String(localized: "Sichern ändert das Ende des Zeitraums davor und den Beginn des Zeitraums danach."),
                        isProblem: false)
        }
        guard case .success = attendancePlan(for: editor), let start = before.checkOut,
              let from = resolveTime(editor.from, original: start), let to = resolveTime(editor.to, original: after.checkIn) else {
            return Hint(text: String(localized: "Nötig sind \(rules.firstBreak) Min. bei über \(Self.hours(rules.firstThreshold)) Std. und \(rules.secondBreak) Min. bei über \(Self.hours(rules.secondThreshold)) Std. Arbeit."),
                        isProblem: false)
        }
        let list = shownPeriods.map { period -> AttendancePeriod in
            if period.id == before.id {
                return AttendancePeriod(id: period.id, checkIn: period.checkIn, checkOut: from, inMode: period.inMode, outMode: period.outMode)
            }
            if period.id == after.id {
                return AttendancePeriod(id: period.id, checkIn: to, checkOut: period.checkOut, inMode: period.inMode, outMode: period.outMode)
            }
            return period
        }
        let work = attendanceMinutes(list)
        let breaks = zip(list, list.dropFirst()).reduce(0) { sum, pair in
            guard let checkOut = pair.0.checkOut else { return sum }
            let gap = max(0, Int(pair.1.checkIn.timeIntervalSince(checkOut) / 60))
            return gap >= rules.minimumGap || pair.1.isTechnical ? sum + gap : sum
        }
        let result = rules.missingBreak(work: work, breaks: breaks)
        let workText = DurationInput.format(work)
        if result.missing > 0 {
            return Hint(text: String(localized: "Bei \(workText) Std. Arbeit sind \(result.required) Min. Pause nötig. Odoo ergänzt beim Sichern \(result.missing) Min."),
                        isProblem: true)
        }
        if result.required > 0 {
            return Hint(text: String(localized: "Passt: Bei \(workText) Std. Arbeit sind \(result.required) Min. Pause nötig."), isProblem: false)
        }
        return Hint(text: String(localized: "Unter \(Self.hours(rules.firstThreshold)) Std. Arbeit ist keine Pause vorgeschrieben."),
                    isProblem: false)
    }

    /// 360 → „6“, 390 → „6:30“
    private static func hours(_ minutes: Int) -> String {
        minutes % 60 == 0 ? String(minutes / 60) : DurationInput.format(minutes)
    }

    /// Dauer, die gerade im Bearbeiten steht, etwa „4:15 Std.“ oder „30 Min.“ bei einer Pause.
    var attendanceEditorDuration: String? {
        guard let editor = attendanceEditor else { return nil }
        switch editor.kind {
        case .period(let period):
            guard let from = resolveTime(editor.from, original: period.checkIn) else { return nil }
            let to = period.isOpen ? now : resolveTime(editor.to, original: period.checkOut)
            guard let to, to > from else { return nil }
            return String(localized: "\(DurationInput.format(Int(to.timeIntervalSince(from) / 60))) Std.")
        case .gap(let before, let after):
            guard let start = before.checkOut, let from = resolveTime(editor.from, original: start),
                  let to = resolveTime(editor.to, original: after.checkIn), to > from else { return nil }
            return String(localized: "\(Int(to.timeIntervalSince(from) / 60)) Min.")
        case .add:
            guard let from = resolveTime(editor.from, original: nil), let to = resolveTime(editor.to, original: nil),
                  to > from else { return nil }
            return String(localized: "\(DurationInput.format(Int(to.timeIntervalSince(from) / 60))) Std.")
        }
    }

    func saveAttendance() async {
        guard var editor = attendanceEditor, let service, !isSavingAttendance else { return }
        let writes: [AttendanceWrite]
        switch attendancePlan(for: editor) {
        case .failure(let problem):
            editor.error = problem.message
            attendanceEditor = editor
            return
        case .success(let plan):
            writes = plan
        }
        guard !writes.isEmpty else {
            attendanceEditor = nil
            return
        }
        let token = sessionToken
        let insertedBefore = Set(shownPeriods.filter(\.isTechnical).map(\.id))
        isSavingAttendance = true
        editor.error = nil
        attendanceEditor = editor
        do {
            for write in writes {
                switch write {
                case .update(let id, let checkIn, let checkOut, let confirmsCheckIn, let confirmsCheckOut):
                    try await service.updateAttendance(id: id, checkIn: checkIn, checkOut: checkOut,
                                                       confirmsCheckIn: confirmsCheckIn, confirmsCheckOut: confirmsCheckOut)
                case .add(let from, let to):
                    guard let employeeID = capabilities?.employeeID else {
                        throw OdooError.rejected(String(localized: "Dein Odoo-Benutzer ist in deiner Hauptfirma mit keinem Mitarbeiter verknüpft."))
                    }
                    try await service.addAttendance(employeeID: employeeID, from: from, to: to)
                }
            }
            guard token == sessionToken else { return }
            await refresh(force: true)
            guard token == sessionToken else { return }
            isSavingAttendance = false
            attendanceEditor = nil
            attendanceNotice = notice(afterSaving: editor.kind, insertedBefore: insertedBefore)
        } catch {
            guard token == sessionToken else { return }
            isSavingAttendance = false
            if case .accessDenied? = error as? OdooError {
                markStampingRefused()
                attendanceNotice = AttendanceNotice(kind: .warning, text: Self.message(for: error))
            } else {
                attendanceEditor?.error = Self.message(for: error)
                if case .unauthorized? = error as? OdooError { handle(error) }
            }
            // Bei einer Pause kann die erste Hälfte schon gesichert sein: den Stand aus Odoo zeigen.
            if writes.count > 1 { await refresh(force: true) }
        }
    }

    /// Hat Odoo nach dem Sichern selbst etwas geändert? Das Modul Arbeitszeitgesetz fügt fehlende
    /// Pausen ein und meldet zu lange Tage.
    private func notice(afterSaving kind: AttendanceEditor.Kind, insertedBefore: Set<Int>) -> AttendanceNotice {
        let list = shownPeriods
        if let rules = capabilities?.schema.breakRules {
            if let index = list.firstIndex(where: { $0.isTechnical && !insertedBefore.contains($0.id) }), index > 0,
               let start = list[index - 1].checkOut {
                let minutes = Int(list[index].checkIn.timeIntervalSince(start) / 60)
                return AttendanceNotice(kind: .info, text: String(localized: "Gesichert. Odoo hat \(minutes) Min. Pause eingefügt (\(clockTime(start)) – \(clockTime(list[index].checkIn)))."))
            }
            if attendanceMinutes(list) > rules.maximumWork {
                return AttendanceNotice(kind: .warning, text: String(localized: "Gesichert. Mehr als \(Self.hours(rules.maximumWork)) Std. Arbeit am Tag erlaubt das Arbeitszeitgesetz nicht."))
            }
        }
        switch kind {
        case .period: return AttendanceNotice(kind: .done, text: String(localized: "Zeitraum gesichert."))
        case .gap: return AttendanceNotice(kind: .done, text: String(localized: "Pause verschoben."))
        case .add: return AttendanceNotice(kind: .done, text: String(localized: "Zeitraum nachgetragen."))
        }
    }

    // MARK: - Löschen

    func askToDelete(_ deletion: Deletion) {
        if case .entry(let entry) = deletion, entry.lock != nil { return }
        pendingDeletion = deletion
    }

    func cancelDeletion() {
        pendingDeletion = nil
    }

    var deletionTitle: String {
        switch pendingDeletion {
        case .period?: return String(localized: "Zeitraum löschen?")
        default: return String(localized: "Eintrag löschen?")
        }
    }

    var deletionMessage: String {
        switch pendingDeletion {
        case .entry(let entry)?:
            let duration = DurationInput.format(entry.minutes)
            return entry.description.isEmpty
                ? String(localized: "Der Eintrag über \(duration) Std. wird in Odoo gelöscht.")
                : String(localized: "„\(entry.description)“ (\(duration) Std.) wird in Odoo gelöscht.")
        case .period(let period)?:
            let range = "\(clockTime(period.checkIn)) – \(period.checkOut.map(clockTime) ?? String(localized: "jetzt"))"
            return String(localized: "\(range) wird in Odoo gelöscht.")
        case nil:
            return ""
        }
    }

    func confirmDeletion() async {
        guard let deletion = pendingDeletion, let service, !isDeleting else { return }
        let token = sessionToken
        isDeleting = true
        do {
            switch deletion {
            case .entry(let entry):
                try await service.deleteTimesheet(id: entry.id)
            case .period(let period):
                try await service.deleteAttendance(id: period.id)
            }
            guard token == sessionToken else { return }
            isDeleting = false
            pendingDeletion = nil
            switch deletion {
            case .entry(let entry):
                if editingEntry?.id == entry.id { finishEditing() }
                removeEntry(entry.id)
            case .period:
                attendanceEditor = nil
                attendanceNotice = AttendanceNotice(kind: .done, text: String(localized: "Zeitraum gelöscht."))
            }
            await refresh(force: true)
        } catch {
            guard token == sessionToken else { return }
            isDeleting = false
            pendingDeletion = nil
            let message = Self.message(for: error)
            switch deletion {
            case .entry: saveError = message
            case .period:
                if case .accessDenied? = error as? OdooError { markStampingRefused() }
                if attendanceEditor != nil { attendanceEditor?.error = message } else {
                    attendanceNotice = AttendanceNotice(kind: .warning, text: message)
                }
            }
            if case .unauthorized? = error as? OdooError { handle(error) }
        }
    }

    // MARK: - Mehrere Firmen

    var organization: Organization? { capabilities?.organization }

    /// Einträge eines Tages, nach Firma geordnet, wenn sie aus mehreren Firmen stammen.
    struct EntryGroup: Identifiable, Equatable {
        let id: Int
        /// Name der Firma; `nil`, wenn alle Einträge aus einer Firma stammen.
        let title: String?
        let minutes: Int
        let entries: [TimesheetEntry]
    }

    var entryGroups: [EntryGroup] {
        let single = [EntryGroup(id: 0, title: nil, minutes: bookedMinutes, entries: entries)]
        guard let organization, let mainID = organization.mainCompanyID else { return single }
        let byCompany = Dictionary(grouping: entries) { $0.companyID ?? mainID }
        guard byCompany.count > 1 else { return single }
        let known = organization.companies.map(\.id)
        let order = known + byCompany.keys.filter { !known.contains($0) }.sorted()
        return order.compactMap { id in
            guard let list = byCompany[id] else { return nil }
            return EntryGroup(id: id, title: organization.company(id)?.name ?? String(localized: "Andere Firma"),
                              minutes: list.reduce(0) { $0 + $1.minutes }, entries: list)
        }
    }

    /// Unter dem Projekt im Formular: in welcher Firma Odoo bucht.
    var selectedProjectCompanyText: String? {
        guard let organization, let projectID = draft.projectID else { return nil }
        if let entry = editingEntry, entry.project?.id == projectID, let company = organization.company(entry.companyID) {
            return company.name
        }
        guard let project = projects.first(where: { $0.id == projectID }) else { return nil }
        return companyText(for: project, in: organization)
    }

    /// Firma eines Projekts für die Projektauswahl.
    func companyName(of project: Project) -> String? {
        guard let organization else { return nil }
        return organization.company(project.companyID)?.name ?? String(localized: "Ohne Firma")
    }

    private func companyText(for project: Project, in organization: Organization) -> String? {
        if let company = organization.company(project.companyID) { return company.name }
        guard let main = organization.company(organization.mainCompanyID) else { return nil }
        return String(localized: "Ohne Firma · gebucht in \(main.name)")
    }

    private func missingEmployeeMessage(for project: Project) -> String {
        let company = organization?.company(project.companyID)?.name ?? ""
        return String(localized: "Für „\(company)“ gibt es keinen Mitarbeiter zu deinem Odoo-Benutzer. Wähle ein anderes Projekt oder lass dir in Odoo einen Mitarbeiter anlegen.")
    }

    /// Firmen, in denen der Benutzer einen Mitarbeiter hat und damit stempeln kann.
    var attendanceCompanies: [Organization.Company] {
        guard let organization else { return [] }
        return organization.companies.filter { organization.employee(in: $0.id) != nil }
    }

    /// Firma des Mitarbeiters, mit dem die App stempelt.
    var attendanceCompanyID: Int? {
        guard let organization else { return nil }
        return organization.employees.first { $0.id == capabilities?.employeeID }?.companyID ?? organization.mainCompanyID
    }

    func setAttendanceCompany(_ companyID: Int) async {
        guard let organization, let employee = organization.employee(in: companyID),
              employee.id != capabilities?.employeeID else { return }
        preferences.attendanceEmployeeID = companyID == organization.mainCompanyID ? nil : employee.id
        attendanceEditor = nil
        attendanceNotice = nil
        periodCache = [:]
        await refreshCapabilities()
        await refresh(force: true)
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

    var serverDisplay: String {
        guard let url = session?.serverURL else { return "" }
        return DemoServer.isDemo(url) ? String(localized: "Demo") : url.host() ?? ""
    }

    var interfaceDisplay: String {
        guard let session else { return "" }
        let version = session.serverMajorVersion.map { "Odoo \($0)" } ?? "Odoo"
        return session.interface == .json2 ? "\(version) · JSON-2" : "\(version) · JSON-RPC"
    }

    /// Zeiterfassung oder Anwesenheiten im Browser.
    var odooWebURL: URL? {
        guard let session, !DemoServer.isDemo(session.serverURL) else { return nil }
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
