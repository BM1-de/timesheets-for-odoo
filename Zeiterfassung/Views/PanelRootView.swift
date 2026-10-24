// Zeiterfassung für Odoo
// Copyright (C) 2026 Baumgärtner Marketing GmbH
// SPDX-License-Identifier: AGPL-3.0-or-later

import AppKit
import SwiftUI

/// Inhalt des Fensters unter dem Menüleistensymbol. Es ist so hoch wie sein Inhalt; passt der nicht
/// auf den Bildschirm, wird das Fenster so hoch wie möglich und der Inhalt lässt sich scrollen.
struct PanelRootView: View {
    @Environment(AppModel.self) private var model
    var onOpenSettings: @MainActor () -> Void
    var onHeightChange: @MainActor (CGFloat) -> Void

    var body: some View {
        ScrollView(.vertical) {
            content
                .frame(maxWidth: .infinity)
                .onGeometryChange(for: CGFloat.self) { proxy in
                    proxy.size.height
                } action: { height in
                    onHeightChange(height)
                }
        }
        .scrollBounceBehavior(.basedOnSize)
        .accessibilityHidden(model.pendingDeletion != nil)
        .frame(width: PanelMetrics.width)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .overlay {
            if model.pendingDeletion != nil {
                DeletionConfirmation()
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        switch model.screen {
        case .starting:
            ProgressView()
                .controlSize(.small)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 40)
        case .login:
            LoginView()
        case .main:
            DayView(onOpenSettings: onOpenSettings)
        }
    }
}

/// Rückfrage vor dem Löschen, im Fenster selbst wie eine Mitteilung. ↩ bricht ab, wie bei Rückfragen,
/// die etwas Unwiderrufliches tun.
struct DeletionConfirmation: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        ZStack {
            Color.black.opacity(0.16)
                .accessibilityHidden(true)
            VStack(spacing: 8) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .frame(width: 48, height: 48)
                    .accessibilityHidden(true)
                Text(model.deletionTitle)
                    .font(.headline)
                Text(model.deletionMessage)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 8) {
                    Button { model.cancelDeletion() } label: {
                        Text("Abbrechen").frame(maxWidth: .infinity)
                    }
                    .keyboardShortcut(.defaultAction)
                    Button(role: .destructive) { Task { await model.confirmDeletion() } } label: {
                        Text("Löschen").frame(maxWidth: .infinity)
                    }
                    .foregroundStyle(.red)
                }
                .disabled(model.isDeleting)
                .padding(.top, 6)
            }
            .padding(.horizontal, 16)
            .padding(.top, 18)
            .padding(.bottom, 16)
            .frame(width: 260)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(Color.hairline.opacity(0.6), lineWidth: 0.5)
            }
            .shadow(color: .black.opacity(0.25), radius: 18, y: 8)
            .accessibilityElement(children: .contain)
            .accessibilityAddTraits(.isModal)
            .background {
                // esc bricht ebenfalls ab.
                Button("Abbrechen") { model.cancelDeletion() }
                    .keyboardShortcut(.cancelAction)
                    .opacity(0)
                    .accessibilityHidden(true)
            }
        }
    }
}
