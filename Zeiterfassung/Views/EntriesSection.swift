// Zeiterfassung für Odoo
// Copyright (C) 2026 Baumgärtner Marketing GmbH
// SPDX-License-Identifier: AGPL-3.0-or-later

import AppKit
import SwiftUI

struct EntriesSection: View {
    @Environment(AppModel.self) private var model

    /// Ab so vielen Einträgen scrollt die Liste, damit das Fenster auf den Bildschirm passt.
    private let visibleRows = 6

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            SectionHeader(title: "Einträge", detail: model.entries.isEmpty ? nil : model.entryCountText)
            InsetGroup {
                if model.entries.isEmpty {
                    emptyState
                } else if model.entries.count > visibleRows {
                    ScrollView { rows }
                        .frame(height: CGFloat(visibleRows) * 46 + 23)
                } else {
                    rows
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

    private var rows: some View {
        VStack(spacing: 0) {
            ForEach(Array(model.entries.enumerated()), id: \.element.id) { index, entry in
                if index > 0 { Divider().padding(.leading, 12) }
                EntryRow(entry: entry)
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

struct EntryRow: View {
    let entry: TimesheetEntry

    private var title: String { entry.description.isEmpty ? String(localized: "Ohne Beschreibung") : entry.description }

    var body: some View {
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
            Text(DurationInput.format(entry.minutes))
                .monospacedDigit()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .frame(minHeight: 46)
        .modifier(HoverHighlight())
        .help([entry.description, entry.path].filter { !$0.isEmpty }.joined(separator: "\n"))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel([title, entry.path, DurationInput.spoken(entry.minutes)].joined(separator: ", "))
        .contextMenu {
            Button("Beschreibung kopieren") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(entry.description, forType: .string)
            }
            .disabled(entry.description.isEmpty)
        }
    }
}
