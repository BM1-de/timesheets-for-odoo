// Zeiterfassung für Odoo
// Copyright (C) 2026 Baumgärtner Marketing GmbH
// SPDX-License-Identifier: AGPL-3.0-or-later

import SwiftUI

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
        VStack(alignment: .leading, spacing: 6) {
            SectionHeader(title: "Neuer Eintrag")
            InsetGroup {
                FormRow(symbol: "folder") {
                    Button { showsProjectPicker = true } label: {
                        PopUpLabel(title: model.selectedProjectName ?? String(localized: "Projekt wählen"),
                                   isPlaceholder: model.draft.projectID == nil)
                    }
                    .buttonStyle(.bordered)
                    .accessibilityLabel("Projekt")
                    .accessibilityValue(model.selectedProjectName ?? String(localized: "keins gewählt"))
                    .popover(isPresented: $showsProjectPicker, arrowEdge: .bottom) {
                        ProjectPicker(projects: model.projects, recentIDs: model.recentProjectIDs,
                                      selectedID: model.draft.projectID, isLoading: model.isLoading) { project in
                            model.selectProject(project)
                            showsProjectPicker = false
                            focusedField = .description
                        }
                    }
                }
                Divider().padding(.leading, 40)
                FormRow(symbol: "list.bullet") {
                    TaskChooser()
                }
                Divider().padding(.leading, 40)
                FormRow(symbol: "text.alignleft") {
                    TextField("Was hast du gemacht?", text: $model.draft.description)
                        .textFieldStyle(.plain)
                        .accessibilityLabel("Beschreibung")
                        .focused($focusedField, equals: .description)
                }
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
                        Button { model.adjustDuration(by: -15) } label: { Image(systemName: "minus") }
                            .accessibilityLabel("15 Minuten weniger")
                        Button { model.adjustDuration(by: 15) } label: { Image(systemName: "plus") }
                            .accessibilityLabel("15 Minuten mehr")
                    }
                    .frame(width: 72)
                    .help("Dauer in Viertelstunden ändern")
                }
            }

            if let hint = model.durationHint {
                Label(hint.text, systemImage: hint.isProblem ? "exclamationmark.circle" : "info.circle")
                    .font(.callout)
                    .foregroundStyle(hint.isProblem ? Color.red : Color.secondary)
                    .padding(.horizontal, 6)
            }

            if let saveError = model.saveError {
                ErrorBanner(title: "Eintrag konnte nicht gesichert werden", message: saveError)
            }

            HStack(spacing: 8) {
                Text("für \(model.dayShortDate)")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Spacer()
                if model.isSaving {
                    ProgressView().controlSize(.small)
                }
                Button(model.saveError == nil ? String(localized: "Eintragen") : String(localized: "Erneut versuchen")) { submit() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!model.canSave)
            }
            .padding(.leading, 6)
            .padding(.top, 2)
        }
        .onChange(of: focusedField) { oldValue, _ in
            if oldValue == .duration { model.normalizeDuration() }
        }
    }

    private func submit() {
        Task {
            await model.save()
            if model.saveError == nil { focusedField = .description }
        }
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
                    Text("Aufgabe wählen").tag(Int?.none)
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
