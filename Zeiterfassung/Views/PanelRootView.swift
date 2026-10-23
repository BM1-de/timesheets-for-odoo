// Zeiterfassung für Odoo
// Copyright (C) 2026 Baumgärtner Marketing GmbH
// SPDX-License-Identifier: AGPL-3.0-or-later

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
        .frame(width: PanelMetrics.width)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
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
