// Zeiterfassung für Odoo
// Copyright (C) 2026 Baumgärtner Marketing GmbH
// SPDX-License-Identifier: AGPL-3.0-or-later

import SwiftUI

struct AttendanceSection: View {
    @Environment(AppModel.self) private var model

    private var isAdding: Bool {
        if case .add? = model.attendanceEditor?.kind { return true }
        return false
    }

    var body: some View {
        let summary = model.attendanceSummary
        // Ohne Zeiterfassung stehen die Zeiten immer da, sonst unter „Zeiten des Tages“.
        let showsList = !model.timesheetsActive || model.showsAttendanceList || isAdding
        VStack(alignment: .leading, spacing: 6) {
            SectionHeader(title: "Anwesenheit")
            InsetGroup {
                header(summary)

                if model.timesheetsActive, !summary.rows.isEmpty {
                    Divider()
                    toggleRow(summary)
                }

                if showsList {
                    ForEach(summary.rows) { row in
                        Divider().padding(.leading, 34)
                        AttendanceRow(row: row, canEdit: summary.canEdit)
                    }
                    if isAdding {
                        Divider().padding(.leading, summary.rows.isEmpty ? 0 : 34)
                        if let editor = model.attendanceEditor { AttendanceEditorView(editor: editor) }
                    } else if summary.canEdit, model.day <= model.today, !summary.rows.isEmpty {
                        Divider().padding(.leading, 34)
                        Button { model.addAttendancePeriod() } label: {
                            Label("Zeitraum nachtragen", systemImage: "plus")
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.borderless)
                        .font(.callout.weight(.medium))
                        .padding(.vertical, 7)
                        .padding(.leading, 34)
                        .padding(.trailing, 12)
                    }
                }

                if let notice = model.attendanceNotice {
                    Divider()
                    NoticeRow(notice: notice) { model.dismissAttendanceNotice() }
                }

                if let unbooked = summary.unbookedText {
                    Divider()
                    HStack {
                        Text("Noch nicht auf Projekte gebucht").foregroundStyle(.secondary)
                        Spacer()
                        Text(unbooked).fontWeight(.semibold).monospacedDigit()
                    }
                    .font(.callout)
                    .padding(.vertical, 7)
                    .padding(.horizontal, 12)
                    .background(Color.groupFooterFill)
                    .accessibilityElement(children: .combine)
                }

                if let note = summary.note {
                    Divider()
                    Label(note, systemImage: "info.circle")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.vertical, 7)
                        .padding(.horizontal, 12)
                }

                if let stampError = model.stampError {
                    Divider()
                    Label(stampError, systemImage: "exclamationmark.triangle.fill")
                        .font(.callout)
                        .foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.vertical, 7)
                        .padding(.horizontal, 12)
                }
            }
        }
    }

    private func header(_ summary: AppModel.AttendanceSummary) -> some View {
        HStack(spacing: 10) {
            StatusDot(isRunning: summary.isRunning)
            VStack(alignment: .leading, spacing: 2) {
                Text(summary.title)
                    .fontWeight(.semibold)
                Text(summary.subtitle)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            .accessibilityElement(children: .combine)
            Spacer(minLength: 8)
            if let buttonTitle = summary.buttonTitle {
                if model.isStamping {
                    ProgressView().controlSize(.small)
                }
                Button(buttonTitle) { Task { await model.toggleAttendance() } }
                    .disabled(model.isStamping)
            } else if summary.offersAdding, !isAdding {
                Button("Nachtragen …") { model.addAttendancePeriod() }
            }
        }
        .padding(.vertical, 10)
        .padding(.leading, 10)
        .padding(.trailing, 10)
    }

    private func toggleRow(_ summary: AppModel.AttendanceSummary) -> some View {
        let expanded = model.showsAttendanceList
        let periods = summary.rows.filter { if case .period = $0.kind { true } else { false } }.count
        return Button { model.setAttendanceListExpanded(!expanded) } label: {
            HStack(spacing: 8) {
                Text("Zeiten des Tages")
                    .lineLimit(1)
                Spacer(minLength: 8)
                if let attention = summary.attention {
                    HStack(spacing: 5) {
                        Circle().fill(Color.orange).frame(width: 6, height: 6)
                        Text(attention).fontWeight(.medium)
                    }
                    .foregroundStyle(.orange)
                    .fixedSize()
                } else {
                    Text("\(periods) Zeiträume").foregroundStyle(.secondary)
                }
                Image(systemName: "chevron.right")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .rotationEffect(.degrees(expanded ? 90 : 0))
                    .accessibilityHidden(true)
            }
            .font(.callout)
            .padding(.vertical, 7)
            .padding(.leading, 34)
            .padding(.trailing, 12)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .modifier(HoverHighlight())
        .accessibilityValue(expanded ? String(localized: "aufgeklappt") : String(localized: "zugeklappt"))
    }
}

/// Eine Anwesenheit oder Pause; ein Klick öffnet sie zum Korrigieren, an ihrer Stelle.
private struct AttendanceRow: View {
    @Environment(AppModel.self) private var model
    let row: AppModel.AttendanceSummary.Row
    let canEdit: Bool

    private var editor: AppModel.AttendanceEditor? {
        guard let editor = model.attendanceEditor else { return nil }
        switch (editor.kind, row.kind) {
        case (.period(let edited), .period(let shown)) where edited.id == shown.id:
            return editor
        case (.gap(let editedBefore, let editedAfter), .gap(let before, let after))
            where editedBefore.id == before.id && editedAfter.id == after.id:
            return editor
        default:
            return nil
        }
    }

    var body: some View {
        if let editor {
            AttendanceEditorView(editor: editor)
        } else {
            switch row.kind {
            case .period(let period):
                EditableRow(canEdit: canEdit, action: { model.editPeriod(period) }) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(row.range)
                        if row.isAutoCheckOut {
                            Text("Automatisch beendet")
                                .foregroundStyle(.orange)
                                .fontWeight(.medium)
                        }
                    }
                    Spacer(minLength: 8)
                    Text(row.duration).foregroundStyle(.secondary).fixedSize()
                }
            case .gap(let before, let after):
                if row.isInsertedBreak {
                    HStack(spacing: 8) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(row.range)
                            Text("Von Odoo eingefügt").foregroundStyle(.orange).fontWeight(.medium)
                        }
                        Spacer(minLength: 8)
                        Text(row.duration).foregroundStyle(.secondary)
                        if canEdit {
                            Button("Verschieben") { model.editGap(before: before, after: after) }
                                .controlSize(.small)
                        }
                    }
                    .font(.callout)
                    .monospacedDigit()
                    .padding(.vertical, 6)
                    .padding(.leading, 34)
                    .padding(.trailing, 12)
                    .background(Color.orange.opacity(0.09))
                    .accessibilityElement(children: .combine)
                } else {
                    EditableRow(canEdit: canEdit, action: { model.editGap(before: before, after: after) }) {
                        Text(row.range).foregroundStyle(.secondary)
                        Spacer(minLength: 8)
                        Text(row.duration).foregroundStyle(.secondary)
                    }
                }
            }
        }
    }
}

/// Zeile, die sich zum Korrigieren öffnen lässt; der Stift erscheint beim Überfahren.
private struct EditableRow<Content: View>: View {
    let canEdit: Bool
    let action: () -> Void
    @ViewBuilder var content: Content
    @State private var isHovering = false

    var body: some View {
        let line = HStack(spacing: 8) {
            content
            if canEdit {
                Image(systemName: "pencil")
                    .foregroundStyle(.secondary)
                    .opacity(isHovering ? 1 : 0)
                    .accessibilityHidden(true)
            }
        }
        .font(.callout)
        .monospacedDigit()
        .padding(.vertical, 7)
        .padding(.leading, 34)
        .padding(.trailing, 12)
        .contentShape(Rectangle())

        if canEdit {
            Button(action: action) { line }
                .buttonStyle(.plain)
                .background(isHovering ? Color.primary.opacity(0.04) : .clear)
                .onHover { isHovering = $0 }
                .accessibilityElement(children: .combine)
                .accessibilityHint("Zum Korrigieren öffnen")
        } else {
            line.accessibilityElement(children: .combine)
        }
    }
}

/// Felder „von“ und „bis“ an der Stelle der Anwesenheit oder Pause.
private struct AttendanceEditorView: View {
    @Environment(AppModel.self) private var model
    let editor: AppModel.AttendanceEditor
    @FocusState private var focus: Field?

    private enum Field: Hashable {
        case from
        case to
    }

    private var openPeriod: Bool {
        if case .period(let period) = editor.kind { return period.isOpen }
        return false
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            switch editor.kind {
            case .gap:
                Text("Wann war deine Pause?").font(.callout.weight(.semibold))
            case .add:
                Text("Zeitraum nachtragen").font(.callout.weight(.semibold))
            case .period(let period) where period.isAutoCheckOut:
                Text("Odoo hat dich automatisch ausgestempelt. Trag ein, wann du wirklich gegangen bist.")
                    .font(.callout)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            case .period:
                EmptyView()
            }
            HStack(spacing: 6) {
                Text("von").foregroundStyle(.secondary)
                timeField(text: binding(\.from), placeholder: "8:00", field: .from, label: "Beginn")
                Text("bis").foregroundStyle(.secondary)
                if openPeriod {
                    Text("jetzt").foregroundStyle(.secondary)
                } else {
                    timeField(text: binding(\.to), placeholder: "12:00", field: .to, label: "Ende")
                }
                Spacer(minLength: 6)
                if let duration = model.attendanceEditorDuration {
                    Text(duration).foregroundStyle(.secondary).monospacedDigit()
                }
            }
            .font(.callout)
            if let hint = model.attendanceEditorHint {
                Text(hint.text)
                    .font(.callout)
                    .foregroundStyle(hint.isProblem ? Color.orange : Color.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let error = editor.error {
                Label(error, systemImage: "exclamationmark.circle")
                    .font(.callout)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 6) {
                if case .period(let period) = editor.kind {
                    Button { model.askToDelete(.period(period)) } label: { Image(systemName: "trash") }
                        .buttonStyle(.borderless)
                        .foregroundStyle(.red)
                        .help("Zeitraum löschen")
                        .accessibilityLabel("Zeitraum löschen")
                }
                Spacer()
                if model.isSavingAttendance {
                    ProgressView().controlSize(.small)
                }
                Button("Abbrechen") { model.cancelAttendanceEditing() }
                    .keyboardShortcut(model.pendingDeletion == nil ? .cancelAction : nil)
                Button(isAdding ? String(localized: "Nachtragen") : String(localized: "Sichern")) {
                    Task { await model.saveAttendance() }
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(model.pendingDeletion == nil ? .defaultAction : nil)
                .disabled(model.isSavingAttendance)
            }
            .controlSize(.small)
        }
        .padding(.vertical, 9)
        .padding(.leading, 34)
        .padding(.trailing, 12)
        .background(Color.groupFooterFill)
        .onAppear {
            // Nach dem automatischen Ausstempeln zählt das Ende, sonst der Beginn.
            let startAtEnd: Bool
            if case .period(let period) = editor.kind { startAtEnd = period.isAutoCheckOut } else { startAtEnd = false }
            Task { @MainActor in focus = startAtEnd ? .to : .from }
        }
    }

    private var isAdding: Bool {
        if case .add = editor.kind { return true }
        return false
    }

    private func binding(_ keyPath: WritableKeyPath<AppModel.AttendanceEditor, String>) -> Binding<String> {
        Binding(
            get: { model.attendanceEditor?[keyPath: keyPath] ?? "" },
            set: { value in
                model.attendanceEditor?[keyPath: keyPath] = value
                model.attendanceEditor?.error = nil
            }
        )
    }

    private func timeField(text: Binding<String>, placeholder: String, field: Field, label: LocalizedStringKey) -> some View {
        TextField(placeholder, text: text)
            .textFieldStyle(.roundedBorder)
            .multilineTextAlignment(.center)
            .monospacedDigit()
            .frame(width: 62)
            .focused($focus, equals: field)
            .accessibilityLabel(label)
            .onSubmit { Task { await model.saveAttendance() } }
    }
}

/// Ergebnis nach dem Sichern, mit Knopf zum Schließen.
private struct NoticeRow: View {
    let notice: AppModel.AttendanceNotice
    let onClose: () -> Void

    private var symbol: String {
        switch notice.kind {
        case .done: "checkmark.circle.fill"
        case .info: "info.circle.fill"
        case .warning: "exclamationmark.triangle.fill"
        }
    }

    private var color: Color {
        switch notice.kind {
        case .done: .green
        case .info: .accentColor
        case .warning: .orange
        }
    }

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: symbol)
                .foregroundStyle(color)
                .accessibilityHidden(true)
            Text(notice.text)
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 4)
            Button(action: onClose) {
                Image(systemName: "xmark").font(.system(size: 9, weight: .bold))
            }
            .buttonStyle(IconButtonStyle())
            .accessibilityLabel("Hinweis schließen")
        }
        .padding(.vertical, 6)
        .padding(.leading, 12)
        .padding(.trailing, 6)
        .background(color.opacity(0.09))
        .accessibilityElement(children: .contain)
    }
}
