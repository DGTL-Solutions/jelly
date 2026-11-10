#!/bin/zsh
# Builds Jelly for the Mac App Store (target JellyMac, with the APPSTORE flag like the other platforms), signs the app
# with the Apple Distribution certificate and its installer package with a Mac Installer Distribution certificate, and
# uploads it to App Store Connect (TestFlight first) – headless like release-appstore.sh.
#   ASC_KEY_ID, ASC_ISSUER_ID   API key; key file ~/.appstoreconnect/private_keys/AuthKey_<id>.p8
#   DIST_CERT_DIR               folder with dist.key + dist.pem of the Apple Distribution certificate
#   INSTALLER_CERT_DIR          folder with dist.key + dist.pem of a Mac Installer Distribution certificate
#                               (once per team: python3 Scripts/asc_certificate.py <key id> <issuer> <key file> <folder> MAC_INSTALLER_DISTRIBUTION)
#   BUILD_NUMBER                default: date +%Y%m%d%H%M
#   UPLOAD=0                    only build, sign and package: .build/AppStore/Jelly-<build>.pkg
set -euo pipefail
cd "$(dirname "$0")/.."

: ${ASC_KEY_ID:?ASC_KEY_ID fehlt}
: ${ASC_ISSUER_ID:?ASC_ISSUER_ID fehlt}
: ${DIST_CERT_DIR:?DIST_CERT_DIR fehlt}
: ${INSTALLER_CERT_DIR:?INSTALLER_CERT_DIR fehlt (siehe Scripts/asc_certificate.py … MAC_INSTALLER_DISTRIBUTION)}
BUNDLE_ID=${BUNDLE_ID:-net.dgtl24.jelly}
BUILD_NUMBER=${BUILD_NUMBER:-$(date +%Y%m%d%H%M)}
KEY_PATH=${ASC_KEY_PATH:-$HOME/.appstoreconnect/private_keys/AuthKey_$ASC_KEY_ID.p8}
RCODESIGN=${RCODESIGN:-$(command -v rcodesign || echo "$HOME/.t3tv-tools/bin/rcodesign")}
[[ -x "$RCODESIGN" ]] || { echo "rcodesign fehlt: cargo install apple-codesign --bin rcodesign" >&2; exit 1; }
TEAM=$(openssl x509 -in "$DIST_CERT_DIR/dist.pem" -noout -subject | sed -nE 's/.*OU ?= ?([A-Z0-9]{10}).*/\1/p')
DATA=.build/AppStoreDataMac
APP=$DATA/Build/Products/Release/Jelly.app
OUT=.build/AppStore
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

echo "App-Store-Profil …"
python3 Scripts/asc_profile.py "$ASC_KEY_ID" "$ASC_ISSUER_ID" "$KEY_PATH" "$BUNDLE_ID" "$DIST_CERT_DIR/dist.pem" - \
  "$WORK/jelly.provisionprofile" "Jelly Mac App Store" MAC_APP_STORE

echo "Build $BUILD_NUMBER …"
rm -rf "$APP"
xcodebuild -project Jelly.xcodeproj -scheme JellyMac -configuration Release -destination "generic/platform=macOS" \
  -derivedDataPath $DATA -clonedSourcePackagesDirPath .build/Packages \
  JELLY_BUNDLE_ID="$BUNDLE_ID" CURRENT_PROJECT_VERSION="$BUILD_NUMBER" CODE_SIGNING_ALLOWED=NO \
  SWIFT_ACTIVE_COMPILATION_CONDITIONS='$(inherited) APPSTORE' build 2>&1 \
  | grep -E "error:|BUILD (SUCCEEDED|FAILED)" || true
[[ -d "$APP" ]] || { echo "Build fehlgeschlagen." >&2; exit 1; }

echo "Signieren …"
# The sandbox every Mac App Store app runs in, the network both ways (the server; the film handed to Apple's player
# inside the Mac), the app's identity for TestFlight and the keychain – and SharePlay where the profile grants it.
openssl smime -inform der -verify -noverify -in "$WORK/jelly.provisionprofile" -out "$WORK/profile.plist" 2>/dev/null
/usr/libexec/PlistBuddy -c "Clear dict" \
  -c "Add :com.apple.security.app-sandbox bool true" \
  -c "Add :com.apple.security.network.client bool true" \
  -c "Add :com.apple.security.network.server bool true" \
  -c "Add :com.apple.application-identifier string $TEAM.$BUNDLE_ID" \
  -c "Add :com.apple.developer.team-identifier string $TEAM" \
  -c "Add :keychain-access-groups array" -c "Add :keychain-access-groups:0 string $TEAM.$BUNDLE_ID" \
  "$WORK/app.plist" >/dev/null
if /usr/libexec/PlistBuddy -c "Print :Entitlements:com.apple.developer.group-session" "$WORK/profile.plist" >/dev/null 2>&1; then
  /usr/libexec/PlistBuddy -c "Add :com.apple.developer.group-session bool true" "$WORK/app.plist" >/dev/null
else
  echo "Hinweis: Das Profil gewährt com.apple.developer.group-session nicht – ohne SharePlay signiert."
fi
chmod -R u+w "$APP"
keys=(--pem-file "$DIST_CERT_DIR/dist.key" --pem-file "$DIST_CERT_DIR/dist.pem")
for item in "$APP"/Contents/Frameworks/*(N); do "$RCODESIGN" sign "${keys[@]}" "$item" >/dev/null 2>&1; done
cp "$WORK/jelly.provisionprofile" "$APP/Contents/embedded.provisionprofile"
"$RCODESIGN" sign "${keys[@]}" --entitlements-xml-file "$WORK/app.plist" --exclude '**' "$APP" >/dev/null 2>&1
codesign --verify --strict --deep "$APP"

mkdir -p "$OUT"
PKG="$PWD/$OUT/Jelly-$BUILD_NUMBER.pkg"
productbuild --component "$APP" /Applications "$WORK/unsigned.pkg" >/dev/null
"$RCODESIGN" sign --pem-file "$INSTALLER_CERT_DIR/dist.key" --pem-file "$INSTALLER_CERT_DIR/dist.pem" "$WORK/unsigned.pkg" "$PKG" >/dev/null 2>&1
echo "Paket: $PKG"

[[ "${UPLOAD:-1}" == 1 ]] || exit 0
echo "Prüfen und hochladen …"
xcrun altool --validate-app "$PKG" -t macos --apiKey "$ASC_KEY_ID" --apiIssuer "$ASC_ISSUER_ID"
xcrun altool --upload-app -f "$PKG" -t macos --apiKey "$ASC_KEY_ID" --apiIssuer "$ASC_ISSUER_ID"
echo "Hochgeladen. Nach der Verarbeitung erscheint Build $BUILD_NUMBER in App Store Connect › TestFlight."
