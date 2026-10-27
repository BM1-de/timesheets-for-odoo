// Zeiterfassung für Odoo
// Copyright (C) 2026 Baumgärtner Marketing GmbH
// SPDX-License-Identifier: AGPL-3.0-or-later

import SwiftUI

/// Formular für einen neuen Eintrag. Ein Klick auf einen Eintrag öffnet ihn hier zum Bearbeiten.
struct NewEntrySection: View {
    @Environment(AppModel.self) private var model
    @State private var showsProjectPicker = false
    @FocusState private var focusedField: Field?

    private enum Field: Hashable {
        case description
        case duration
    }

    /// Als `String`: Eine Zahl braucht keine Übersetzung.
    private static let durationPlaceholder = "0:00"

    var body: some View {
        @Bindable var model = model
        let isEditing = model.editingEntry != nil || model.timerEditing != nil
        let fixed = model.editingIsLimited || model.editingIsLocked
        VStack(alignment: .leading, spacing: 6) {
            SectionHeader(title: sectionTitle)
            InsetGroup {
                FormRow(symbol: "folder") {
                    Button { showsProjectPicker = true } label: {
                        VStack(alignment: .leading, spacing: 1) {
                            PopUpLabel(title: model.selectedProjectName ?? String(localized: "Projekt wählen"),
                                       isPlaceholder: model.draft.projectID == nil)
                            if let company = model.selectedProjectCompanyText {
                                Text(company)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                                    .truncationMode(.tail)
                            }
                        }
                    }
                    .buttonStyle(.bordered)
                    .disabled(fixed)
                    .accessibilityLabel("Projekt")
                    .accessibilityValue([model.selectedProjectName ?? String(localized: "keins gewählt"),
                                         model.selectedProjectCompanyText].compactMap { $0 }.joined(separator: ", "))
                    .popover(isPresented: $showsProjectPicker, arrowEdge: .bottom) {
                        ProjectPicker(projects: model.projects, recentIDs: model.recentProjectIDs,
                                      selectedID: model.draft.projectID, isLoading: model.isLoading,
                                      companyName: model.organization == nil ? nil : { model.companyName(of: $0) },
                                      companyOrder: model.organization?.companies.map(\.id) ?? []) { project in
                            model.selectProject(project)
                            showsProjectPicker = false
                            focusedField = .description
                        }
                    }
                }
                .padding(.vertical, model.selectedProjectCompanyText == nil ? 0 : 3)
                Divider().padding(.leading, 40)
                FormRow(symbol: "list.bullet") {
                    TaskChooser()
                        .disabled(fixed)
                }
                Divider().padding(.leading, 40)
                FormRow(symbol: "text.alignleft") {
                    TextField(model.timerEditing == .running ? "Was machst du gerade?" : "Was hast du gemacht?",
                              text: $model.draft.description)
                        .textFieldStyle(.plain)
                        .accessibilityLabel("Beschreibung")
                        .focused($focusedField, equals: .description)
                        .disabled(model.editingIsLocked)
                }
                if model.timerEditing != .running {
                    Divider().padding(.leading, 40)
                    FormRow(symbol: "timer", minHeight: 44) {
                        TextField(Self.durationPlaceholder, text: $model.draft.durationText)
                            .textFieldStyle(.roundedBorder)
                            .multilineTextAlignment(.trailing)
                            .monospacedDigit()
                            .frame(width: 64)
                            .focused($focusedField, equals: .duration)
                            .accessibilityLabel("Dauer in Stunden und Minuten")
                        Text("Std.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                        Spacer(minLength: 8)
                        ControlGroup {
                            Button { model.adjustDuration(by: -1) } label: { Image(systemName: "minus") }
                                .accessibilityLabel(model.preferences.durationRounding.lessLabel)
                            Button { model.adjustDuration(by: 1) } label: { Image(systemName: "plus") }
                                .accessibilityLabel(model.preferences.durationRounding.moreLabel)
                        }
                        .frame(width: 72)
                        .help(model.preferences.durationRounding.stepHelp)
                    }
                    .disabled(fixed)
                }
                if model.editingEntry != nil {
                    Divider().padding(.leading, 40)
                    FormRow(symbol: "calendar") {
                        Picker("Datum", selection: $model.editDay) {
                            ForEach(model.editDayChoices, id: \.self) { choice in
                                Text(model.dayChoiceTitle(choice)).tag(choice)
                            }
                        }
                        .pickerStyle(.menu)
                        .labelsHidden()
                        .fixedSize()
                        .disabled(fixed)
                        Spacer(minLength: 0)
                    }
                }
            }

            if model.editingIsLimited {
                LockNote(text: "Schon abgerechnet: Projekt, Aufgabe, Dauer und Datum stehen fest, löschen geht nicht mehr. Die Beschreibung kannst du noch ändern.")
            } else if model.editingIsLocked {
                LockNote(text: "Schon freigegeben: Ändern kann diesen Eintrag nur noch, wer in Odoo Zeiteinträge freigibt.")
            }

            if let hint = model.durationHint, !fixed {
                Label(hint.text, systemImage: hint.isProblem ? "exclamationmark.circle" : "info.circle")
                    .font(.callout)
                    .foregroundStyle(hint.isProblem ? Color.red : Color.secondary)
                    .padding(.horizontal, 6)
            }

            if let saveError = model.saveError {
                ErrorBanner(title: saveErrorTitle, message: saveError)
            }

            if isEditing {
                editingButtons
            } else {
                HStack(spacing: 8) {
                    Text("für \(model.dayShortDate)")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    Spacer()
                    if model.isSaving {
                        ProgressView().controlSize(.small)
                    }
                    if model.offersTimerStart {
                        Button { Task { await model.startTimer() } } label: {
                            HStack(spacing: 5) {
                                Image(systemName: "play.fill")
                                    .font(.system(size: 9))
                                    .foregroundStyle(model.canStartTimer ? AnyShapeStyle(.tint) : AnyShapeStyle(.tertiary))
                                Text("Starten")
                            }
                        }
                        .disabled(!model.canStartTimer)
                        .help("Ohne Dauer läuft die Zeit ab jetzt, bis du sie stoppst.")
                    }
                    Button(model.saveError == nil ? String(localized: "Eintragen") : String(localized: "Erneut versuchen")) { submit() }
                        .buttonStyle(.borderedProminent)
                        .keyboardShortcut(formShortcut(.defaultAction))
                        .disabled(!model.canSave)
                }
                .padding(.leading, 6)
                .padding(.top, 2)
                if model.offersTimerStart, model.runningTimerLacksProject {
                    Text("Die laufende Zeit braucht erst ein Projekt, dann startet eine neue.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 6)
                } else if model.offersTimerStart, model.runningTimerBlocksStart {
                    Text("Die gestoppte Zeit erst buchen oder verwerfen, dann startet eine neue.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 6)
                } else if model.runningTimer != nil, model.canStartTimer {
                    Text("Starten bucht vorher die laufende Zeit.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 6)
                }
            }
        }
        .onChange(of: focusedField) { oldValue, _ in
            if oldValue == .duration { model.normalizeDuration() }
        }
    }

    private var sectionTitle: LocalizedStringKey {
        switch model.timerEditing {
        case .running?: "Laufende Zeit"
        case .booking?: "Zeit buchen"
        case nil: model.editingEntry == nil ? "Neuer Eintrag" : "Eintrag bearbeiten"
        }
    }

    private var saveErrorTitle: LocalizedStringKey {
        switch model.timerEditing {
        case .booking?: "Projektzeit konnte nicht gebucht werden"
        case .running?: "Änderung konnte nicht gesichert werden"
        case nil: model.editingEntry == nil ? "Eintrag konnte nicht gesichert werden" : "Änderung konnte nicht gesichert werden"
        }
    }

    private var confirmTitle: String {
        if model.saveError != nil { return String(localized: "Erneut versuchen") }
        switch model.timerEditing {
        case .running?: return String(localized: "Sichern")
        case .booking?: return String(localized: "Buchen")
        case nil: return String(localized: "Sichern")
        }
    }

    private var editingButtons: some View {
        HStack(spacing: 8) {
            if model.editingEntry?.lock == nil, let entry = model.editingEntry {
                Button("Löschen …") { model.askToDelete(.entry(entry)) }
                    .buttonStyle(.borderless)
                    .foregroundStyle(.red)
            }
            if model.timerEditing == .booking {
                Text("für \(model.timerDayShortDate)")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if model.isSaving {
                ProgressView().controlSize(.small)
            }
            Button("Abbrechen") { model.cancelEditing() }
                .keyboardShortcut(formShortcut(.cancelAction))
            Button(confirmTitle) { submit() }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(formShortcut(.defaultAction))
                .disabled(!model.canSave)
        }
        .padding(.leading, model.timerEditing == .booking ? 6 : 0)
        .padding(.top, 2)
    }

    /// ↩ und esc gehören dem Formular, solange keine Anwesenheit bearbeitet wird und keine Rückfrage offen ist.
    private func formShortcut(_ shortcut: KeyboardShortcut) -> KeyboardShortcut? {
        model.attendanceEditor == nil && model.pendingDeletion == nil ? shortcut : nil
    }

    private func submit() {
        Task {
            let wasNewEntry = model.editingEntry == nil && model.timerEditing == nil
            await model.save()
            if model.saveError == nil, wasNewEntry { focusedField = .description }
        }
    }
}

/// Warum sich ein Eintrag nicht mehr ganz ändern lässt.
private struct LockNote: View {
    let text: LocalizedStringKey

    var body: some View {
        Label(text, systemImage: "lock")
            .font(.callout)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 8)
            .padding(.horizontal, 12)
            .background(Color.accentColor.opacity(0.08), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}

/// Auswahl der Aufgabe als Aufklappmenü; ohne offene Aufgaben wird aufs Projekt gebucht.
struct TaskChooser: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        switch model.taskChoice {
        case .noProject:
            Text("Erst Projekt wählen")
                .foregroundStyle(.tertiary)
                .frame(maxWidth: .infinity, alignment: .leading)
        case .loading:
            HStack {
                Text("Aufgaben werden geladen …").foregroundStyle(.secondary)
                Spacer()
                ProgressView().controlSize(.small)
            }
        case .noTasks:
            Text("Keine offenen Aufgaben – Buchung auf das Projekt")
                .font(.callout)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
        case .failed(let message):
            HStack {
                Text(message)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                Spacer()
                Button("Erneut laden") { model.retryTasks() }
                    .controlSize(.small)
            }
        case .tasks(let tasks):
            Picker("Aufgabe", selection: $model.draft.taskID) {
                if model.draft.taskID == nil {
                    Text(model.taskIsRequired ? "Aufgabe wählen" : "Ohne Aufgabe").tag(Int?.none)
                }
                ForEach(tasks) { task in
                    Text(task.name).tag(Int?.some(task.id))
                }
            }
            .pickerStyle(.menu)
            .labelsHidden()
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityLabel("Aufgabe")
        }
    }
}
