// Zeiterfassung für Odoo
// Copyright (C) 2026 Baumgärtner Marketing GmbH
// SPDX-License-Identifier: AGPL-3.0-or-later

import SwiftUI

/// Laufende Projektzeit oben im Fenster, darunter, was beim Stoppen herauskam.
struct RunningTimerSection: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(spacing: 8) {
            if let timer = model.runningTimer {
                RunningTimerCard(timer: timer)
                if timer.end != nil {
                    ErrorBanner(title: "Projektzeit konnte nicht gebucht werden",
                                message: model.timerError ?? String(localized: "Die Zeit steht still, bis sie gebucht ist."),
                                retry: model.isStoppingTimer ? nil : { Task { await model.stopTimer() } })
                }
            }
            if let notice = model.timerNotice {
                TimerNoticeBanner(notice: notice) { model.dismissTimerNotice() }
            }
        }
    }
}

/// Beschreibung zum Ändern, Projekt › Aufgabe, Zeit seit dem Start, Verwerfen und Stoppen.
private struct RunningTimerCard: View {
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let timer: Preferences.RunningTimer

    private var isStopped: Bool { timer.end != nil }

    var body: some View {
        @Bindable var model = model
        HStack(spacing: 10) {
            TimelineView(.periodic(from: timer.start, by: 1)) { _ in
                let odd = model.timerSeconds() % 2 == 1
                Circle()
                    .fill(isStopped ? Color.orange : Color.red)
                    .frame(width: 8, height: 8)
                    .opacity(!isStopped && !reduceMotion && odd ? 0.35 : 1)
                    .animation(.easeInOut(duration: 0.8), value: odd)
            }
            .frame(width: 8, height: 8)
            .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                TextField("Beschreibung", text: $model.timerDescription, prompt: Text("Was machst du gerade?"))
                    .textFieldStyle(.plain)
                    .fontWeight(.semibold)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .accessibilityLabel("Beschreibung der laufenden Zeit")
                Text(timer.path)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            Spacer(minLength: 4)
            TimelineView(.periodic(from: timer.start, by: 1)) { _ in
                let seconds = model.timerSeconds()
                VStack(alignment: .trailing, spacing: 1) {
                    Text(DurationInput.format(seconds: seconds))
                        .font(.system(size: 15, weight: .semibold))
                        .monospacedDigit()
                    Text(model.timerStartText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel([DurationInput.spoken(seconds / 60), model.timerStartText].joined(separator: ", "))
            }
            .fixedSize()
            Button { model.requestDiscardTimer() } label: {
                Image(systemName: "trash").foregroundStyle(.secondary)
            }
            .buttonStyle(IconButtonStyle())
            .disabled(model.isStoppingTimer)
            .help("Verwerfen …")
            .accessibilityLabel("Verwerfen …")
            if model.isStoppingTimer {
                ProgressView()
                    .controlSize(.small)
                    .frame(width: 30, height: 30)
            } else if !isStopped {
                Button { Task { await model.stopTimer() } } label: {
                    RoundedRectangle(cornerRadius: 2, style: .continuous)
                        .fill(.white)
                        .frame(width: 10, height: 10)
                        .frame(width: 30, height: 30)
                        .background(Color.red, in: Circle())
                        .shadow(color: .black.opacity(0.18), radius: 0.5, y: 0.5)
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .help("Stoppen und buchen")
                .accessibilityLabel("Stoppen und buchen")
            }
        }
        .padding(.vertical, 10)
        .padding(.leading, 12)
        .padding(.trailing, 8)
        .background(Color.groupFill, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(Color.hairline.opacity(0.6), lineWidth: 0.5)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Laufende Projektzeit")
    }
}

/// Ergebnis nach dem Stoppen oder Verwerfen, mit Knopf zum Schließen.
private struct TimerNoticeBanner: View {
    let notice: AppModel.TimerNotice
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
        .background(color.opacity(0.09), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .accessibilityElement(children: .contain)
    }
}
