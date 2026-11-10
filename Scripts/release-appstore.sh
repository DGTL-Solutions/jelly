#!/bin/zsh
# Builds Jelly for the App Store – the Apple TV app, or with PLATFORM=ios the iPhone and iPad app – (with the APPSTORE flag: paywall with the annual subscription, no IMDb dataset), signs it with an Apple Distribution certificate and uploads it to App Store Connect
# (TestFlight first, review later in the web UI) – headless like install-appletv.sh: no Xcode account, no keychain.
#   ASC_KEY_ID, ASC_ISSUER_ID   API key with role Admin or App Manager; key file ~/.appstoreconnect/private_keys/AuthKey_<id>.p8
#   DIST_CERT_DIR               folder with dist.key + dist.pem of an Apple Distribution certificate
#                               (once per team: python3 Scripts/asc_certificate.py <key id> <issuer> <key file> <folder>)
#   BUILD_NUMBER                default: date +%Y%m%d%H%M; must grow with every upload
#   UPLOAD=0                    only build, sign and package: .build/AppStore/Jelly-<build>.ipa
#   PLATFORM=ios                the iPhone and iPad app (target JellyMobile) instead of the Apple TV app
# The app must already exist in App Store Connect (Apps › +) with this bundle ID: the API can't create apps.
set -euo pipefail
cd "$(dirname "$0")/.."

: ${ASC_KEY_ID:?ASC_KEY_ID fehlt}
: ${ASC_ISSUER_ID:?ASC_ISSUER_ID fehlt}
: ${DIST_CERT_DIR:?DIST_CERT_DIR fehlt (Ordner mit dist.key und dist.pem, siehe Scripts/asc_certificate.py)}
BUNDLE_ID=${BUNDLE_ID:-net.dgtl24.jelly}
BUILD_NUMBER=${BUILD_NUMBER:-$(date +%Y%m%d%H%M)}
KEY_PATH=${ASC_KEY_PATH:-$HOME/.appstoreconnect/private_keys/AuthKey_$ASC_KEY_ID.p8}
RCODESIGN=${RCODESIGN:-$(command -v rcodesign || echo "$HOME/.t3tv-tools/bin/rcodesign")}
[[ -x "$RCODESIGN" ]] || { echo "rcodesign fehlt: cargo install apple-codesign --bin rcodesign" >&2; exit 1; }
TEAM=$(openssl x509 -in "$DIST_CERT_DIR/dist.pem" -noout -subject | sed -nE 's/.*OU ?= ?([A-Z0-9]{10}).*/\1/p')
if [[ "${PLATFORM:-tvos}" == ios ]]; then
  SCHEME=JellyMobile; DESTINATION="generic/platform=iOS"; DATA=.build/AppStoreDataIOS; PRODUCTS=Release-iphoneos
  PROFILE_TYPE=IOS_APP_STORE; PROFILE_NAME="Jelly iOS App Store"; ALTOOL_TYPE=ios
else
  SCHEME=Jelly; DESTINATION="generic/platform=tvOS"; DATA=.build/AppStoreData; PRODUCTS=Release-appletvos
  PROFILE_TYPE=TVOS_APP_STORE; PROFILE_NAME="Jelly tvOS App Store"; ALTOOL_TYPE=appletvos
fi
APP=$DATA/Build/Products/$PRODUCTS/Jelly.app
OUT=.build/AppStore
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

echo "App-Store-Profile …"
python3 Scripts/asc_profile.py "$ASC_KEY_ID" "$ASC_ISSUER_ID" "$KEY_PATH" "$BUNDLE_ID" "$DIST_CERT_DIR/dist.pem" - \
  "$WORK/jelly.mobileprovision" "$PROFILE_NAME" $PROFILE_TYPE
# The extension inside the app: the Top Shelf on Apple TV, the widgets on iPhone and iPad.
if [[ $SCHEME == Jelly ]]; then
  python3 Scripts/asc_profile.py "$ASC_KEY_ID" "$ASC_ISSUER_ID" "$KEY_PATH" "$BUNDLE_ID.topshelf" "$DIST_CERT_DIR/dist.pem" - \
    "$WORK/extension.mobileprovision" "Jelly Top Shelf App Store" TVOS_APP_STORE
  EXTENSION_ID=$BUNDLE_ID.topshelf
else
  python3 Scripts/asc_profile.py "$ASC_KEY_ID" "$ASC_ISSUER_ID" "$KEY_PATH" "$BUNDLE_ID.widgets" "$DIST_CERT_DIR/dist.pem" - \
    "$WORK/extension.mobileprovision" "Jelly Widgets App Store" IOS_APP_STORE
  EXTENSION_ID=$BUNDLE_ID.widgets
fi

echo "Build $BUILD_NUMBER …"
rm -rf "$APP"
xcodebuild -project Jelly.xcodeproj -scheme $SCHEME -configuration Release -destination "$DESTINATION" \
  -derivedDataPath $DATA -clonedSourcePackagesDirPath .build/Packages \
  JELLY_BUNDLE_ID="$BUNDLE_ID" CURRENT_PROJECT_VERSION="$BUILD_NUMBER" CODE_SIGNING_ALLOWED=NO \
  SWIFT_ACTIVE_COMPILATION_CONDITIONS='$(inherited) APPSTORE' build 2>&1 \
  | grep -E "error:|BUILD (SUCCEEDED|FAILED)" || true
[[ -d "$APP" ]] || { echo "Build fehlgeschlagen." >&2; exit 1; }

echo "Signieren …"
# App Store entitlements: no get-task-allow; beta-reports-active lets TestFlight take the build. Capabilities are
# signed in only where the provisioning profile grants them (they are switched on per bundle ID in the developer
# account): SharePlay (Group Activities), and on Apple TV "runs as current user" and HomeKit scenes.
granted() { # profile, entitlement key -> prints the profile's value, empty if the profile doesn't grant it
  openssl smime -inform der -verify -noverify -in "$1" -out "$WORK/profile.plist" 2>/dev/null
  /usr/libexec/PlistBuddy -c "Print :Entitlements:$2" "$WORK/profile.plist" 2>/dev/null || true
}
entitlements() { # output plist, bundle ID, profile, capability keys …
  local out=$1 id=$2 profile=$3; shift 3
  /usr/libexec/PlistBuddy -c "Clear dict" \
    -c "Add :application-identifier string $TEAM.$id" \
    -c "Add :com.apple.developer.team-identifier string $TEAM" \
    -c "Add :beta-reports-active bool true" \
    -c "Add :keychain-access-groups array" -c "Add :keychain-access-groups:0 string $TEAM.$BUNDLE_ID" \
    "$out" >/dev/null
  local key
  for key in "$@"; do
    if [[ -n "$(granted "$profile" "$key")" ]]; then
      case $key in
        com.apple.developer.user-management)
          /usr/libexec/PlistBuddy -c "Add :$key array" -c "Add :$key:0 string runs-as-current-user" "$out" >/dev/null ;;
        *) /usr/libexec/PlistBuddy -c "Add :$key bool true" "$out" >/dev/null ;;
      esac
    else
      echo "Hinweis: Das Profil für $id gewährt $key nicht – ohne diese Fähigkeit signiert."
    fi
  done
}
if [[ $SCHEME == Jelly ]]; then
  entitlements "$WORK/app.plist" "$BUNDLE_ID" "$WORK/jelly.mobileprovision" com.apple.developer.user-management \
    com.apple.developer.homekit com.apple.developer.group-session
  entitlements "$WORK/extension.plist" "$EXTENSION_ID" "$WORK/extension.mobileprovision" com.apple.developer.user-management
else
  entitlements "$WORK/app.plist" "$BUNDLE_ID" "$WORK/jelly.mobileprovision" com.apple.developer.group-session
  entitlements "$WORK/extension.plist" "$EXTENSION_ID" "$WORK/extension.mobileprovision"
fi
# Prebuilt frameworks (AetherEngine's FFmpeg) arrive read-only; rcodesign signs in place.
chmod -R u+w "$APP"
keys=(--pem-file "$DIST_CERT_DIR/dist.key" --pem-file "$DIST_CERT_DIR/dist.pem")
for item in "$APP"/Frameworks/*(N) "$APP"/PlugIns/*.appex/Frameworks/*(N); do "$RCODESIGN" sign "${keys[@]}" "$item" >/dev/null 2>&1; done
for appex in "$APP"/PlugIns/*.appex(N); do
  cp "$WORK/extension.mobileprovision" "$appex/embedded.mobileprovision"
  "$RCODESIGN" sign "${keys[@]}" --entitlements-xml-file "$WORK/extension.plist" --exclude '**' "$appex" >/dev/null 2>&1
done
cp "$WORK/jelly.mobileprovision" "$APP/embedded.mobileprovision"
"$RCODESIGN" sign "${keys[@]}" --entitlements-xml-file "$WORK/app.plist" --exclude '**' "$APP" >/dev/null 2>&1
codesign --verify --strict --deep "$APP"

mkdir -p "$OUT" "$WORK/Payload"
cp -R "$APP" "$WORK/Payload/"
IPA="$PWD/$OUT/Jelly-$BUILD_NUMBER.ipa"
(cd "$WORK" && zip -qry "$IPA" Payload)
echo "Paket: $IPA"

[[ "${UPLOAD:-1}" == 1 ]] || exit 0
# altool finds the key in ~/.appstoreconnect/private_keys by its ID.
echo "Prüfen und hochladen …"
xcrun altool --validate-app "$IPA" -t $ALTOOL_TYPE --apiKey "$ASC_KEY_ID" --apiIssuer "$ASC_ISSUER_ID"
xcrun altool --upload-app -f "$IPA" -t $ALTOOL_TYPE --apiKey "$ASC_KEY_ID" --apiIssuer "$ASC_ISSUER_ID"
echo "Hochgeladen. Nach der Verarbeitung (etwa 15 min) erscheint Build $BUILD_NUMBER in App Store Connect › TestFlight."
