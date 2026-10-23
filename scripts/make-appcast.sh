#!/bin/zsh
# Zeiterfassung für Odoo – Versionsliste für Sparkle schreiben
# Copyright (C) 2026 Baumgärtner Marketing GmbH
# SPDX-License-Identifier: AGPL-3.0-or-later
#
# Schreibt appcast.xml für das DMG einer Version und signiert den Eintrag mit dem privaten
# Schlüssel des Projekts. Die App lädt die Liste über
# https://github.com/BM1-de/zeiterfassung-fuer-odoo/releases/latest/download/appcast.xml
#
#   SPARKLE_BIN=/pfad/zu/Sparkle/bin scripts/make-appcast.sh build/release/Zeiterfassung-fuer-Odoo-0.1.0.dmg 0.1.0
#
# Den Schlüssel liest generate_appcast aus dem Schlüsselbund (Konto zeiterfassung-fuer-odoo) oder mit
# SPARKLE_KEY_FILE aus einer Datei; „-“ liest ihn von der Standardeingabe (so auf GitHub).
# Die Hinweise zur Version stammen aus dem Abschnitt der Version in CHANGELOG.md.

set -euo pipefail
cd "${0:A:h}/.."

DMG=${1:?Pfad zum DMG fehlt}
VERSION=${2:?Version fehlt}
SPARKLE_BIN=${SPARKLE_BIN:?SPARKLE_BIN fehlt (Ordner bin aus dem Sparkle-Download)}
DOWNLOAD_URL_PREFIX=${DOWNLOAD_URL_PREFIX:-https://github.com/BM1-de/zeiterfassung-fuer-odoo/releases/download/v$VERSION/}
OUT=build/appcast

rm -rf "$OUT"
mkdir -p "$OUT"
cp "$DMG" "$OUT/"
awk -v heading="## $VERSION" 'index($0, heading) == 1 { found = 1; next } /^## / { found = 0 } found' CHANGELOG.md \
  > "$OUT/$(basename "$DMG" .dmg).md"

key=(--account zeiterfassung-fuer-odoo)
if [[ -n "${SPARKLE_KEY_FILE:-}" ]]; then
  key=(--ed-key-file "$SPARKLE_KEY_FILE")
fi
"$SPARKLE_BIN/generate_appcast" "${key[@]}" --download-url-prefix "$DOWNLOAD_URL_PREFIX" --embed-release-notes \
  --link https://github.com/BM1-de/zeiterfassung-fuer-odoo --maximum-deltas 0 "$OUT"
echo "$OUT/appcast.xml"
