#!/bin/zsh
# Zeiterfassung für Odoo – DMG zum Installieren bauen
# Copyright (C) 2026 Baumgärtner Marketing GmbH
# SPDX-License-Identifier: AGPL-3.0-or-later
#
# Packt die App in ein DMG wie bei Mac-Apps üblich: Das Fenster zeigt die App und den Ordner
# „Applications“, man zieht die App hinüber.
#
#   scripts/make-dmg.sh build/release/Zeiterfassung.app build/release/Zeiterfassung-fuer-Odoo-0.1.0.dmg
#
# Braucht dmgbuild (MIT-Lizenz): python3 -m pip install dmgbuild==1.6.7

set -euo pipefail
cd "${0:A:h}/.."

APP=${1:?Pfad zur App fehlt}
DMG=${2:?Pfad zum DMG fehlt}
VOLUME="Zeiterfassung für Odoo"
DMGBUILD=${DMGBUILD:-dmgbuild}

if ! command -v "$DMGBUILD" >/dev/null; then
  echo "dmgbuild fehlt: python3 -m pip install dmgbuild==1.6.7" >&2
  exit 1
fi

# Hintergrund für normale und Retina-Bildschirme in einer Datei
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
tiffutil -cathidpicheck scripts/dmg/background.png scripts/dmg/background@2x.png -out "$WORK/background.tiff" 2>/dev/null

rm -f "$DMG"
"$DMGBUILD" -s scripts/dmg/settings.py -D app="$APP" -D background="$WORK/background.tiff" "$VOLUME" "$DMG"
echo "$DMG"
