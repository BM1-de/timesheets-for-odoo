#!/bin/zsh
# Zeiterfassung für Odoo – Fassung für den Mac App Store bauen und hochladen
# Copyright (C) 2026 Baumgärtner Marketing GmbH
# SPDX-License-Identifier: AGPL-3.0-or-later
#
# Archiviert das Ziel „Zeiterfassung App Store“: ohne Sparkle, ohne Sonderberechtigungen, und
# „Beim Anmelden am Mac öffnen“ schaltet erst der Benutzer ein. Xcode signiert über die
# Cloud-Signatur von Apple und lädt den Build zu App Store Connect hoch; dort steht er nach einigen
# Minuten für die Prüfung bereit. Vorher muss der Eintrag der App in App Store Connect angelegt sein.
#
#   scripts/build-appstore.sh            bauen und hochladen
#   UPLOAD=0 scripts/build-appstore.sh   nur das Installationspaket nach build/appstore bauen
#
# Braucht einen API-Schlüssel von App Store Connect mit der Rolle Admin:
#   ASC_KEY_ID, ASC_ISSUER_ID     Schlüssel-ID und Aussteller-ID
#   ASC_KEY_PATH oder ASC_KEY_P8  Pfad zur .p8-Datei oder ihr Inhalt in base64
#
# Weitere Angaben: TEAM_ID (Standard NK334VAXVK), VERSION (statt der Version im Projekt),
# BUILD_NUMBER (Standard: Zeitstempel; jeder Upload braucht eine höhere Nummer).

set -euo pipefail
cd "${0:A:h}/.."

: "${ASC_KEY_ID:?ASC_KEY_ID fehlt (Schlüssel-ID aus App Store Connect)}"
: "${ASC_ISSUER_ID:?ASC_ISSUER_ID fehlt (Aussteller-ID aus App Store Connect)}"
TEAM_ID=${TEAM_ID:-NK334VAXVK}
VERSION=${VERSION:-$(xcodebuild -project Zeiterfassung.xcodeproj -target "Zeiterfassung App Store" -configuration Release -showBuildSettings 2>/dev/null \
  | awk '$1 == "MARKETING_VERSION" { print $3; exit }')}
BUILD_NUMBER=${BUILD_NUMBER:-$(date -u +%y%m%d%H%M)}
UPLOAD=${UPLOAD:-1}
OUT=build/appstore

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
if [[ -n "${ASC_KEY_PATH:-}" ]]; then
  KEY=$ASC_KEY_PATH
else
  : "${ASC_KEY_P8:?ASC_KEY_P8 oder ASC_KEY_PATH fehlt (.p8-Datei des API-Schlüssels)}"
  KEY="$WORK/AuthKey_$ASC_KEY_ID.p8"
  (umask 077; print -rn -- "$ASC_KEY_P8" | base64 -d > "$KEY")
fi
# Darf Zertifikate und Profile anlegen und diesen Mac für das Entwicklungsprofil registrieren.
auth=(-allowProvisioningUpdates -allowProvisioningDeviceRegistration -authenticationKeyPath "$KEY"
      -authenticationKeyID "$ASC_KEY_ID" -authenticationKeyIssuerID "$ASC_ISSUER_ID")

xcodebuild archive -project Zeiterfassung.xcodeproj -scheme "Zeiterfassung App Store" -configuration Release \
  -destination 'generic/platform=macOS' -archivePath "$WORK/Zeiterfassung.xcarchive" \
  -derivedDataPath build/DerivedData.noindex MARKETING_VERSION="$VERSION" CURRENT_PROJECT_VERSION="$BUILD_NUMBER" \
  CODE_SIGN_STYLE=Automatic CODE_SIGN_IDENTITY="Apple Development" DEVELOPMENT_TEAM="$TEAM_ID" "${auth[@]}" \
  | grep -E "error:|warning:|ARCHIVE (SUCCEEDED|FAILED)" || true
APP="$WORK/Zeiterfassung.xcarchive/Products/Applications/Zeiterfassung.app"
test -d "$APP"
# Eigene Update-Suche ist im App Store nicht erlaubt.
if [[ -e "$APP/Contents/Frameworks/Sparkle.framework" ]] || plutil -extract SUFeedURL raw "$APP/Contents/Info.plist" >/dev/null 2>&1; then
  echo "Im App-Store-Build steckt Sparkle." >&2
  exit 1
fi

destination=export
(( UPLOAD )) && destination=upload
cat > "$WORK/ExportOptions.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>method</key>
	<string>app-store-connect</string>
	<key>destination</key>
	<string>$destination</string>
	<key>teamID</key>
	<string>$TEAM_ID</string>
	<key>signingStyle</key>
	<string>automatic</string>
	<key>manageAppVersionAndBuildNumber</key>
	<false/>
</dict>
</plist>
PLIST
rm -rf "$OUT"
mkdir -p "$OUT"
xcodebuild -exportArchive -archivePath "$WORK/Zeiterfassung.xcarchive" -exportOptionsPlist "$WORK/ExportOptions.plist" \
  -exportPath "$OUT" "${auth[@]}" | grep -E "error:|Upload|EXPORT (SUCCEEDED|FAILED)" || true

echo "Version: $VERSION (Build $BUILD_NUMBER)"
if (( UPLOAD )); then
  echo "Hochgeladen zu App Store Connect; der Build erscheint dort nach der Verarbeitung."
else
  ls "$OUT"/*.pkg
fi
