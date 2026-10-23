// Zeiterfassung für Odoo
// Copyright (C) 2026 Baumgärtner Marketing GmbH
// SPDX-License-Identifier: AGPL-3.0-or-later

import SwiftUI

/// Einstellungen im Stil der Systemeinstellungen.
struct SettingsView: View {
    @Environment(AppModel.self) private var model
    @Environment(Updates.self) private var updates: Updates?
    @State private var refusedSwitchOff = false
    @State private var confirmsSignOut = false
    @State private var loginItemEnabled = LoginItem.isEnabled
    @State private var loginItemProblem: String?

    var body: some View {
        @Bindable var preferences = model.preferences
        Form {
            Section {
                FeatureRow(symbol: "clock", tint: .blue, title: "Zeiterfassung",
                           subtitle: "Stunden auf Projekte und Aufgaben buchen",
                           status: FeatureStatus.timesheets(model.capabilities), isOn: timesheetsBinding)
                FeatureRow(symbol: "person.fill", tint: .green, title: "Anwesenheit",
                           subtitle: "Ein- und ausstempeln, Arbeitszeit des Tages",
                           status: FeatureStatus.attendance(model.capabilities), isOn: attendanceBinding)
            } header: {
                Text("Funktionen")
            } footer: {
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    Text(refusedSwitchOff
                         ? String(localized: "Mindestens eine Funktion muss eingeschaltet bleiben.")
                         : String(localized: "Beim Verbinden prüft die App, welche Odoo-Apps installiert sind. Was fehlt, bleibt ausgeschaltet."))
                        .foregroundStyle(refusedSwitchOff ? AnyShapeStyle(Color.red) : AnyShapeStyle(.secondary))
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer()
                    Button(model.isCheckingCapabilities ? String(localized: "Prüfe …") : String(localized: "Erneut prüfen")) {
                        Task {
                            await model.refreshCapabilities(recheck: true)
                            await model.refresh(force: true)
                        }
                    }
                    .disabled(model.session == nil || model.isCheckingCapabilities)
                }
                .font(.callout)
            }

            Section("Menüleiste") {
                Picker("Anzeigen", selection: $preferences.menuBarDisplay) {
                    Text("Gebuchte Stunden").tag(Preferences.MenuBarDisplay.booked)
                    Text("Anwesenheit").tag(Preferences.MenuBarDisplay.attendance)
                    Text("Beides").tag(Preferences.MenuBarDisplay.both)
                }
                .disabled(!(model.timesheetsActive && model.attendanceActive))
                Toggle("Grünen Punkt zeigen, solange ich eingestempelt bin", isOn: $preferences.showsCheckedInDot)
                    .disabled(!model.attendanceActive)
            }

            Section("Konto") {
                if model.session != nil {
                    LabeledContent("Odoo", value: model.serverDisplay)
                    LabeledContent("Schnittstelle", value: model.interfaceDisplay)
                    LabeledContent("Angemeldet als") {
                        HStack(spacing: 12) {
                            Text(model.userName)
                            Button("Abmelden …") { confirmsSignOut = true }
                        }
                    }
                } else {
                    LabeledContent("Status", value: String(localized: "Nicht angemeldet"))
                    Text("Zum Anmelden auf das Uhrsymbol in der Menüleiste klicken.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }

            Section("Allgemein") {
                Toggle("Beim Anmelden am Mac öffnen", isOn: loginItemBinding)
                if let loginItemProblem {
                    HStack(alignment: .firstTextBaseline) {
                        Text(loginItemProblem)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer()
                        Button("Systemeinstellungen …") { LoginItem.openSystemSettings() }
                            .controlSize(.small)
                    }
                }
                Toggle("Dauer auf Viertelstunden runden", isOn: $preferences.roundsToQuarterHour)
            }

            if let updates {
                @Bindable var updates = updates
                Section {
                    Toggle("Automatisch nach Updates suchen", isOn: $updates.automaticallyChecks)
                    LabeledContent("Zuletzt gesucht") {
                        HStack(spacing: 12) {
                            Text(updates.lastCheck.map { $0.formatted(Date.FormatStyle(date: .abbreviated, time: .shortened, locale: Formatting.locale)) } ?? String(localized: "noch nie"))
                            Button("Jetzt suchen") { updates.checkForUpdates() }
                        }
                    }
                } header: {
                    Text("Updates")
                } footer: {
                    Text("Die App lädt dafür einmal am Tag die Versionsliste von GitHub und installiert nur Versionen mit der Signatur des Projekts.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Section {
                LabeledContent("Version", value: AppInfo.version)
                LabeledContent("Quellcode und Lizenz") {
                    HStack(spacing: 14) {
                        Link("GitHub", destination: AppInfo.sourceURL)
                        Link("AGPL-3.0", destination: AppInfo.licenseURL)
                    }
                }
            } header: {
                Text("Über \(AppInfo.name)")
            } footer: {
                Text(AppInfo.legalNotice + " " + AppInfo.thirdPartyNotice)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .formStyle(.grouped)
        .frame(width: 540, height: 720)
        .confirmationDialog("Von Odoo abmelden?", isPresented: $confirmsSignOut) {
            Button("Abmelden", role: .destructive) { model.signOut() }
        } message: {
            Text("Der API-Schlüssel wird aus dem Schlüsselbund gelöscht. Deine Einträge in Odoo bleiben erhalten.")
        }
        .onAppear {
            loginItemEnabled = LoginItem.isEnabled
            loginItemProblem = LoginItem.needsApproval ? approvalHint : nil
        }
    }

    private var approvalHint: String {
        String(localized: "Bitte in den Systemeinstellungen unter Allgemein › Anmeldeobjekte erlauben.")
    }

    private var timesheetsBinding: Binding<Bool> {
        Binding(
            get: { model.timesheetsActive },
            set: { refusedSwitchOff = !model.setTimesheetsEnabled($0) }
        )
    }

    private var attendanceBinding: Binding<Bool> {
        Binding(
            get: { model.attendanceActive },
            set: { refusedSwitchOff = !model.setAttendanceEnabled($0) }
        )
    }

    private var loginItemBinding: Binding<Bool> {
        Binding(
            get: { loginItemEnabled },
            set: { enabled in
                do {
                    try LoginItem.setEnabled(enabled)
                    loginItemProblem = LoginItem.needsApproval ? approvalHint : nil
                } catch {
                    loginItemProblem = String(localized: "Das Anmeldeobjekt ließ sich nicht ändern: \(error.localizedDescription)")
                }
                loginItemEnabled = LoginItem.isEnabled
            }
        )
    }
}

/// Funktion mit farbiger Kachel, Beschreibung, Status und Schalter.
private struct FeatureRow: View {
    let symbol: String
    let tint: Color
    let title: LocalizedStringKey
    let subtitle: LocalizedStringKey
    let status: FeatureStatus
    @Binding var isOn: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            IconTile(symbol: symbol, color: tint)
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .foregroundStyle(status.isAvailable ? .primary : .secondary)
                Text(subtitle)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Label {
                    Text(status.text)
                } icon: {
                    Image(systemName: status.symbol).foregroundStyle(status.color)
                }
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 2)
            }
            Spacer(minLength: 12)
            Toggle(title, isOn: $isOn)
                .toggleStyle(.switch)
                .labelsHidden()
                .disabled(!status.isAvailable)
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .contain)
    }
}
