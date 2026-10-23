#!/bin/zsh
# Zeiterfassung für Odoo – Release bauen
# Copyright (C) 2026 Baumgärtner Marketing GmbH
# SPDX-License-Identifier: AGPL-3.0-or-later
#
# Baut die App für Apple Silicon und Intel und packt sie als DMG nach build/release. Die App selbst
# liegt in build/app.noindex und die Zwischenstände in build/DerivedData.noindex: Ordner mit dieser
# Endung durchsucht Spotlight nicht, sonst stünde jede gebaute Kopie neben der installierten App.
#
#   scripts/build-release.sh
#
# Ohne weitere Angaben ist die App nur lokal signiert, zum Ausprobieren auf diesem Mac. Zum
# Weitergeben signiert das Skript mit dem Zertifikat „Developer ID Application“ des Teams und lässt
# App und DMG von Apple prüfen (Notarisierung); dann öffnen sie auf jedem Mac ohne Warnung:
#
#   TEAM_ID=ABCDE12345 NOTARY_PROFILE=zeiterfassung scripts/build-release.sh
#
# Zugang zur Notarisierung, eins von dreien:
#   NOTARY_PROFILE                                 Profil im Schlüsselbund, einmal angelegt mit
#                                                  xcrun notarytool store-credentials zeiterfassung
#   NOTARY_KEY, NOTARY_KEY_ID, NOTARY_ISSUER       API-Schlüssel von App Store Connect (.p8-Datei)
#   NOTARY_APPLE_ID, NOTARY_PASSWORD               Apple-Account mit App-spezifischem Passwort
#
# Weitere Angaben: VERSION (statt der Version im Projekt), DMGBUILD (Pfad zu dmgbuild).

set -euo pipefail
cd "${0:A:h}/.."

VERSION=${VERSION:-$(xcodebuild -project Zeiterfassung.xcodeproj -target Zeiterfassung -configuration Release -showBuildSettings 2>/dev/null \
  | awk '$1 == "MARKETING_VERSION" { print $3; exit }')}
OUT=build/release
STAGE=build/app.noindex
DERIVED=build/DerivedData.noindex
# Der Dateiname bleibt ASCII, angezeigt wird „Zeiterfassung für Odoo“ (de.lproj/InfoPlist.strings).
# Ein „ü“ im Pfad steht je nach Weg mal als ein Zeichen, mal zerlegt da; Sparkle findet die
# laufende App dann nicht und startet sie nach einem Update nicht neu.
APP="$STAGE/Zeiterfassung.app"
DMG="$OUT/Zeiterfassung-fuer-Odoo-$VERSION.dmg"
IDENTITY="Developer ID Application"
TEAM_ID=${TEAM_ID:-}

notary=()
if [[ -n "${NOTARY_PROFILE:-}" ]]; then
  notary=(--keychain-profile "$NOTARY_PROFILE")
elif [[ -n "${NOTARY_KEY:-}" ]]; then
  notary=(--key "$NOTARY_KEY" --key-id "${NOTARY_KEY_ID:?NOTARY_KEY_ID fehlt}" --issuer "${NOTARY_ISSUER:?NOTARY_ISSUER fehlt}")
elif [[ -n "${NOTARY_APPLE_ID:-}" ]]; then
  notary=(--apple-id "$NOTARY_APPLE_ID" --password "${NOTARY_PASSWORD:?NOTARY_PASSWORD fehlt}" --team-id "${TEAM_ID:?TEAM_ID fehlt}")
fi
if (( ${#notary} )) && [[ -z "$TEAM_ID" ]]; then
  echo "Notarisierung braucht eine Signatur mit Developer ID: TEAM_ID fehlt." >&2
  exit 1
fi

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

# Lässt eine Datei von Apple prüfen und bricht mit dem Protokoll ab, wenn Apple sie ablehnt.
notarize() {
  local result notary_status
  result=$(xcrun notarytool submit "$1" "${notary[@]}" --wait --timeout 30m --output-format json)
  notary_status=$(plutil -extract status raw -o - - <<< "$result")
  if [[ "$notary_status" != "Accepted" ]]; then
    xcrun notarytool log "$(plutil -extract id raw -o - - <<< "$result")" "${notary[@]}" >&2 || true
    echo "Notarisierung von $1: $notary_status" >&2
    exit 1
  fi
}

rm -rf "$OUT" "$STAGE"
mkdir -p "$OUT" "$STAGE"
if [[ -n "$TEAM_ID" ]]; then
  # Archivieren und für Developer ID exportieren: So signiert Xcode auch die Hilfsprogramme von Sparkle richtig.
  xcodebuild archive -project Zeiterfassung.xcodeproj -scheme Zeiterfassung -configuration Release \
    -destination 'generic/platform=macOS' -archivePath "$WORK/Zeiterfassung.xcarchive" -derivedDataPath "$DERIVED" \
    MARKETING_VERSION="$VERSION" CODE_SIGN_IDENTITY="$IDENTITY" DEVELOPMENT_TEAM="$TEAM_ID" OTHER_CODE_SIGN_FLAGS=--timestamp \
    | grep -E "error:|warning:|ARCHIVE (SUCCEEDED|FAILED)" || true
  test -d "$WORK/Zeiterfassung.xcarchive"
  cat > "$WORK/ExportOptions.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>method</key>
	<string>developer-id</string>
	<key>teamID</key>
	<string>$TEAM_ID</string>
	<key>signingStyle</key>
	<string>manual</string>
	<key>signingCertificate</key>
	<string>$IDENTITY</string>
</dict>
</plist>
PLIST
  xcodebuild -exportArchive -archivePath "$WORK/Zeiterfassung.xcarchive" -exportOptionsPlist "$WORK/ExportOptions.plist" \
    -exportPath "$WORK/export" | grep -E "error:|EXPORT (SUCCEEDED|FAILED)" || true
  ditto "$WORK/export/Zeiterfassung.app" "$APP"
else
  # Nur lokal signiert ohne Hardened Runtime: Mit ihr dürfte die App das ebenfalls nur lokal signierte
  # Sparkle nicht laden. Die Hardened Runtime braucht nur die Notarisierung, also die Weitergabe.
  xcodebuild -project Zeiterfassung.xcodeproj -scheme Zeiterfassung -configuration Release \
    -destination 'generic/platform=macOS' -derivedDataPath "$DERIVED" MARKETING_VERSION="$VERSION" \
    ENABLE_HARDENED_RUNTIME=NO build \
    | grep -E "error:|warning:|BUILD (SUCCEEDED|FAILED)" || true
  test -d "$DERIVED/Build/Products/Release/Zeiterfassung.app"
  ditto "$DERIVED/Build/Products/Release/Zeiterfassung.app" "$APP"
fi
codesign --verify --strict --deep "$APP"
# Probestart: Lädt die App nicht (etwa weil eine Bibliothek anders signiert ist), bricht das hier ab.
started=$("$APP/Contents/MacOS/Zeiterfassung" --version 2>&1 || true)
if [[ "$started" != "$VERSION" ]]; then
  echo "Die App startet nicht: $started" >&2
  exit 1
fi

if (( ${#notary} )); then
  ditto -c -k --keepParent "$APP" "$WORK/app.zip"
  notarize "$WORK/app.zip"
  xcrun stapler staple "$APP"
fi

scripts/make-dmg.sh "$APP" "$DMG" >/dev/null
if [[ -n "$TEAM_ID" ]]; then
  codesign --sign "$IDENTITY" --timestamp "$DMG"
fi
if (( ${#notary} )); then
  notarize "$DMG"
  xcrun stapler staple "$DMG"
fi

echo "Version: $VERSION"
echo "Architekturen: $(lipo -archs "$APP/Contents/MacOS/Zeiterfassung")"
echo "Signatur: $(codesign -dv "$APP" 2>&1 | awk -F= '/^Authority=/ { print $2; exit }' || true)"
echo "$DMG"
