#!/bin/zsh
# Builds Jelly, signs it and installs it on the paired Apple TV – entirely from the terminal (headless Mac).
#
# Signing with an App Store Connect API key – no Xcode account and no keychain involved:
#   ASC_KEY_ID, ASC_ISSUER_ID   key file defaults to ~/.appstoreconnect/private_keys/AuthKey_<ASC_KEY_ID>.p8
#   SIGNING_CERT_DIR            folder with dev.key + dev.pem of an Apple Development certificate of the same team
#   RCODESIGN                   apple-codesign binary (cargo install apple-codesign --bin rcodesign)
# Without ASC_KEY_ID the Apple ID signed into Xcode › Settings › Accounts signs automatically.
# Optional: BUNDLE_ID (default net.dgtl24.jelly), DEVICE (UDID), CONFIGURATION (default Release)
set -euo pipefail
cd "$(dirname "$0")/.."

BUNDLE_ID=${BUNDLE_ID:-net.dgtl24.jelly}
CONFIGURATION=${CONFIGURATION:-Release}
DEVICE=${DEVICE:-$(xcrun devicectl list devices 2>/dev/null | awk '/physical/ && /AppleTV|Apple TV/ {for (i = 1; i <= NF; i++) if ($i ~ /^[0-9A-F]{8}-[0-9A-F]{16}$/) {print $i; exit}}' || true)}
[[ -n "$DEVICE" ]] || { echo "Kein gekoppeltes Apple TV gefunden." >&2; exit 1; }
APP=.build/DeviceData/Build/Products/$CONFIGURATION-appletvos/Jelly.app
build=(xcodebuild -project Jelly.xcodeproj -scheme Jelly -configuration "$CONFIGURATION"
       -derivedDataPath .build/DeviceData -clonedSourcePackagesDirPath .build/Packages JELLY_BUNDLE_ID="$BUNDLE_ID")

if [[ -z "${ASC_KEY_ID:-}" ]]; then
  TEAM=$(defaults read com.apple.dt.Xcode IDEProvisioningTeamByIdentifier 2>/dev/null | awk -F' = ' '/teamID/ {gsub(/[";]/, "", $2); print $2; exit}' || true)
  [[ -n "$TEAM" ]] || { echo "Kein Team: API-Schlüssel setzen oder in Xcode mit einer Apple-ID anmelden." >&2; exit 1; }
  "${build[@]}" -destination "platform=tvOS,id=$DEVICE" -allowProvisioningUpdates -allowProvisioningDeviceRegistration \
    CODE_SIGN_STYLE=Automatic DEVELOPMENT_TEAM="$TEAM" build 2>&1 | grep -E "error:|BUILD (SUCCEEDED|FAILED)" || true
else
  : ${ASC_ISSUER_ID:?ASC_ISSUER_ID fehlt}
  : ${SIGNING_CERT_DIR:?SIGNING_CERT_DIR fehlt (Ordner mit dev.key und dev.pem)}
  KEY_PATH=${ASC_KEY_PATH:-$HOME/.appstoreconnect/private_keys/AuthKey_$ASC_KEY_ID.p8}
  RCODESIGN=${RCODESIGN:-$(command -v rcodesign || echo "$HOME/.t3tv-tools/bin/rcodesign")}
  [[ -x "$RCODESIGN" ]] || { echo "rcodesign fehlt: cargo install apple-codesign --bin rcodesign" >&2; exit 1; }
  TEAM=$(openssl x509 -in "$SIGNING_CERT_DIR/dev.pem" -noout -subject | sed -nE 's/.*OU ?= ?([A-Z0-9]{10}).*/\1/p')
  WORK=$(mktemp -d)
  trap 'rm -rf "$WORK"' EXIT

  echo "Profile über App Store Connect …"
  python3 Scripts/asc_profile.py "$ASC_KEY_ID" "$ASC_ISSUER_ID" "$KEY_PATH" "$BUNDLE_ID" "$SIGNING_CERT_DIR/dev.pem" "$DEVICE" "$WORK/jelly.mobileprovision"
  python3 Scripts/asc_profile.py "$ASC_KEY_ID" "$ASC_ISSUER_ID" "$KEY_PATH" "$BUNDLE_ID.topshelf" "$SIGNING_CERT_DIR/dev.pem" "$DEVICE" \
    "$WORK/topshelf.mobileprovision" "Jelly Top Shelf Development"

  echo "Build …"
  rm -rf "$APP"
  "${build[@]}" -destination "generic/platform=tvOS" CODE_SIGNING_ALLOWED=NO build 2>&1 | grep -E "error:|BUILD (SUCCEEDED|FAILED)" || true
  [[ -d "$APP" ]] || { echo "Build fehlgeschlagen." >&2; exit 1; }

  echo "Signieren …"
  # entitlements <file> <bundle ID>: the extension shares the app's keychain group to read the active profile.
  entitlements() {
    /usr/libexec/PlistBuddy -c "Clear dict" \
      -c "Add :application-identifier string $TEAM.$2" \
      -c "Add :com.apple.developer.team-identifier string $TEAM" \
      -c "Add :get-task-allow bool true" \
      -c "Add :keychain-access-groups array" -c "Add :keychain-access-groups:0 string $TEAM.$BUNDLE_ID" \
      "$1" >/dev/null
  }
  entitlements "$WORK/app.plist" "$BUNDLE_ID"
  entitlements "$WORK/topshelf.plist" "$BUNDLE_ID.topshelf"
  keys=(--pem-file "$SIGNING_CERT_DIR/dev.key" --pem-file "$SIGNING_CERT_DIR/dev.pem")
  # Inside out: frameworks, then the extension with its own profile, then the app itself.
  for item in "$APP"/Frameworks/*(N) "$APP"/PlugIns/*.appex/Frameworks/*(N); do "$RCODESIGN" sign "${keys[@]}" "$item" >/dev/null 2>&1; done
  for appex in "$APP"/PlugIns/*.appex(N); do
    cp "$WORK/topshelf.mobileprovision" "$appex/embedded.mobileprovision"
    "$RCODESIGN" sign "${keys[@]}" --entitlements-xml-file "$WORK/topshelf.plist" --exclude '**' "$appex" >/dev/null 2>&1
  done
  cp "$WORK/jelly.mobileprovision" "$APP/embedded.mobileprovision"
  "$RCODESIGN" sign "${keys[@]}" --entitlements-xml-file "$WORK/app.plist" --exclude '**' "$APP" >/dev/null 2>&1
fi

codesign --verify --strict --deep "$APP" 2>&1 | grep -v "^$" || true
echo "Installieren auf $DEVICE …"
xcrun devicectl device install app --device "$DEVICE" "$APP" 2>&1 | tail -3
xcrun devicectl device process launch --device "$DEVICE" "$BUNDLE_ID" 2>&1 | tail -1
