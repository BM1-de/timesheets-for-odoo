// Zeiterfassung für Odoo
// Copyright (C) 2026 Baumgärtner Marketing GmbH
// SPDX-License-Identifier: AGPL-3.0-or-later

import SwiftUI

struct AttendanceSection: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let summary = model.attendanceSummary
        VStack(alignment: .leading, spacing: 6) {
            SectionHeader(title: "Anwesenheit")
            InsetGroup {
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
                    }
                }
                .padding(.vertical, 10)
                .padding(.leading, 10)
                .padding(.trailing, 10)

                ForEach(summary.rows) { row in
                    Divider().padding(.leading, 34)
                    HStack {
                        Text(row.range)
                        Spacer()
                        Text(row.duration).foregroundStyle(.secondary)
                    }
                    .font(.callout)
                    .monospacedDigit()
                    .padding(.vertical, 7)
                    .padding(.leading, 34)
                    .padding(.trailing, 12)
                    .accessibilityElement(children: .combine)
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
}
