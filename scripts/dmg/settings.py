# Zeiterfassung für Odoo
# Copyright (C) 2026 Baumgärtner Marketing GmbH
# SPDX-License-Identifier: AGPL-3.0-or-later
#
# Fenster des DMG für dmgbuild: links die App, rechts der Ordner „Applications“, dazwischen der
# Pfeil aus dem Hintergrundbild. Aufruf über scripts/make-dmg.sh.

import os.path

app = defines["app"]
app_name = os.path.basename(app)

format = "ULFO"
files = [app]
# Der Finder übersetzt den Namen eines Verweises nicht; „Applications“ verstehen alle Sprachen.
symlinks = {"Applications": "/Applications"}
# Keine ausgeblendete Endung: Sie hinterlässt Finder-Informationen am Programmpaket, und die strenge
# Signaturprüfung lehnt die App dann ab. Der Finder blendet „.app“ ohnehin aus.
icon = os.path.join(app, "Contents", "Resources", "AppIcon.icns")

background = defines["background"]
window_rect = ((200, 140), (600, 400))
default_view = "icon-view"
show_status_bar = False
show_tab_view = False
show_toolbar = False
show_pathbar = False
show_sidebar = False
include_icon_view_settings = True
arrange_by = None
icon_size = 128
text_size = 13
# Mitte der Symbole, von oben gemessen; passt zum Pfeil in scripts/make-dmg-background.swift.
icon_locations = {
    app_name: (170, 175),
    "Applications": (430, 175),
}
