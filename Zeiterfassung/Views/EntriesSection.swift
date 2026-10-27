// Zeiterfassung für Odoo
// Copyright (C) 2026 Baumgärtner Marketing GmbH
// SPDX-License-Identifier: AGPL-3.0-or-later

import AppKit
import SwiftUI

struct EntriesSection: View {
    @Environment(AppModel.self) private var model

    /// Ab so vielen Zeilen scrollt die Liste, damit das Fenster auf den Bildschirm passt.
    private let visibleRows = 6

    var body: some View {
        let groups = model.entryGroups
        let rowCount = model.entries.count + (groups.count > 1 ? groups.count : 0)
        VStack(alignment: .leading, spacing: 6) {
            SectionHeader(title: "Einträge", detail: model.entries.isEmpty ? nil : model.entryCountText)
            InsetGroup {
                if model.entries.isEmpty {
                    emptyState
                } else if rowCount > visibleRows {
                    ScrollView { rows(groups) }
                        .frame(height: CGFloat(visibleRows) * 46 + 23)
                } else {
                    rows(groups)
                }
                Divider()
                HStack {
                    Text("Summe").font(.callout).foregroundStyle(.secondary)
                    Spacer()
                    Text("\(DurationInput.format(model.bookedMinutes)) Std.")
                        .fontWeight(.semibold)
                        .monospacedDigit()
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(Color.groupFooterFill)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Summe \(DurationInput.spoken(model.bookedMinutes))")
            }
        }
    }

    private func rows(_ groups: [AppModel.EntryGroup]) -> some View {
        VStack(spacing: 0) {
            ForEach(groups) { group in
                if let title = group.title {
                    if group.id != groups.first?.id { Divider() }
                    CompanyHeader(title: title, minutes: group.minutes)
                    Divider()
                }
                ForEach(Array(group.entries.enumerated()), id: \.element.id) { index, entry in
                    if index > 0 { Divider().padding(.leading, 12) }
                    EntryRow(entry: entry, isSelected: model.editingEntry?.id == entry.id,
                             onStart: model.canStartTimer(like: entry) ? { Task { await model.startTimer(like: entry) } } : nil) {
                        model.beginEditing(entry)
                    } onDelete: {
                        model.askToDelete(.entry(entry))
                    }
                }
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 4) {
            if model.isDayLoaded {
                Image(systemName: "calendar")
                    .font(.system(size: 22, weight: .light))
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
                Text("Keine Einträge")
                    .fontWeight(.semibold)
                    .padding(.top, 4)
                Text(model.emptyDayMessage)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                ProgressView().controlSize(.small)
                Text("Wird geladen …")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 18)
    }
}

/// Zwischenüberschrift einer Firma mit der Summe ihrer Einträge.
private struct CompanyHeader: View {
    let title: String
    let minutes: Int

    var body: some View {
        HStack {
            Text(title)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 8)
            Text(DurationInput.format(minutes))
                .monospacedDigit()
        }
        .font(.subheadline.weight(.semibold))
        .foregroundStyle(.secondary)
        .padding(.leading, 12)
        .padding(.trailing, EntryRow.durationInset)
        .padding(.top, 6)
        .padding(.bottom, 4)
        .background(Color.groupFooterFill)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel([title, DurationInput.spoken(minutes)].joined(separator: ", "))
        .accessibilityAddTraits(.isHeader)
    }
}

/// Ein Eintrag; ein Klick öffnet ihn unten im Formular zum Bearbeiten. Beim Überfahren startet ▶ seine
/// Zeit erneut.
struct EntryRow: View {
    let entry: TimesheetEntry
    var isSelected = false
    /// ▶ und „Erneut starten“; `nil`, wenn sich die Zeit nicht erneut starten lässt.
    var onStart: (() -> Void)?
    var onEdit: () -> Void = {}
    var onDelete: () -> Void = {}
    @State private var isHovering = false

    /// Abstand der Dauer vom rechten Rand, mit Platz für ▶. Zwischensummen rücken genauso weit ein.
    static let durationInset: CGFloat = 38

    private var title: String { entry.description.isEmpty ? String(localized: "Ohne Beschreibung") : entry.description }

    private var lockLabel: String? {
        switch entry.lock {
        case .invoiced?: String(localized: "abgerechnet")
        case .validated?: String(localized: "freigegeben")
        case nil: nil
        }
    }

    var body: some View {
        HStack(spacing: 0) {
            Button(action: onEdit) {
                HStack(spacing: 10) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(title)
                            .foregroundStyle(entry.description.isEmpty ? .secondary : .primary)
                            .lineLimit(1)
                            .truncationMode(.tail)
                        Text(entry.path)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    Spacer(minLength: 8)
                    if let lockLabel {
                        Image(systemName: "lock")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .help(lockLabel)
                    }
                    Text(DurationInput.format(entry.minutes))
                        .monospacedDigit()
                }
                .padding(.leading, 12)
                .padding(.trailing, 4)
                .padding(.vertical, 7)
                .frame(minHeight: 46)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help([entry.description, entry.path].filter { !$0.isEmpty }.joined(separator: "\n"))
            .accessibilityElement(children: .ignore)
            .accessibilityLabel([title, entry.path, DurationInput.spoken(entry.minutes), lockLabel].compactMap { $0 }.joined(separator: ", "))
            .accessibilityHint("Zum Bearbeiten öffnen")
            .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
            .accessibilityActions {
                if let onStart { Button("Erneut starten", action: onStart) }
            }
            ZStack {
                if let onStart {
                    Button(action: onStart) {
                        Image(systemName: "play.fill")
                            .font(.system(size: 10))
                            .foregroundStyle(.tint)
                    }
                    .buttonStyle(IconButtonStyle())
                    .opacity(isHovering ? 1 : 0)
                    .help("Erneut starten")
                    .accessibilityHidden(true)
                }
            }
            .frame(width: Self.durationInset - 10)
            .padding(.trailing, 6)
        }
        .background(isSelected ? Color.accentColor.opacity(0.12) : isHovering ? Color.primary.opacity(0.04) : .clear)
        .onHover { isHovering = $0 }
        .contextMenu {
            Button("Ändern", action: onEdit)
            if let onStart {
                Button("Erneut starten", action: onStart)
            }
            Button("Beschreibung kopieren") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(entry.description, forType: .string)
            }
            .disabled(entry.description.isEmpty)
            Divider()
            Button("Löschen …", action: onDelete)
                .disabled(entry.lock != nil)
        }
    }
}
