#!/bin/zsh
# App Store screenshots of the iPhone and iPad app (AppStore/screenshots-ios/<locale>/{iphone,ipad}), with the public
# Jellyfin demo server's free films and the Jellyseerr mock for "Erkunden". Boots one simulator at a time.
#   Scripts/screenshots-ios.sh            both devices
#   Scripts/screenshots-ios.sh ipad       only one of them (iphone | ipad)
# Builds the store variant first (Debug for the JELLY_* launch settings, APPSTORE for what the store version shows).
set -u
cd "$(dirname "$0")/.."
IPHONE="iPhone 18 Pro Max"            # 6.9": 1320×2868
IPAD="iPad Pro 13-inch (M5)"          # 13": 2064×2752
DRACULA=c002f0f88ee970cce7f138bbc925de64
PIONEER_ONE=9bd5926326d651153928e0d11c6ee7cb
APP=.build/ios-shots/Build/Products/Debug-iphonesimulator/Jelly.app

xcodebuild -project Jelly.xcodeproj -scheme JellyMobile -configuration Debug -destination 'generic/platform=iOS Simulator' \
  -derivedDataPath .build/ios-shots -clonedSourcePackagesDirPath .build/ios/SourcePackages CODE_SIGN_IDENTITY=- \
  SWIFT_ACTIVE_COMPILATION_CONDITIONS='DEBUG APPSTORE' build 2>&1 | grep -E "error:|BUILD (SUCCEEDED|FAILED)"
[[ -d $APP ]] || exit 1

python3 Scripts/seerr-mock.py > /dev/null 2>&1 &
MOCK=$!
trap 'kill $MOCK 2>/dev/null; xcrun simctl shutdown all 2>/dev/null' EXIT

# Boots the simulator with the system language set, so the status bar's date matches the screenshots' language.
boot() { # device lang
  local device=$1 lang=$2
  xcrun simctl boot "$device" 2>/dev/null; xcrun simctl bootstatus "$device" -b >/dev/null
  xcrun simctl spawn "$device" defaults write -g AppleLanguages -array $lang
  xcrun simctl spawn "$device" defaults write -g AppleLocale $([[ $lang == de ]] && echo de_DE || echo en_US)
  # The home screen's featured titles stay put instead of turning mid-screenshot.
  xcrun simctl spawn "$device" defaults write com.apple.Accessibility ReduceMotionEnabled -bool true
  xcrun simctl shutdown "$device"; xcrun simctl boot "$device"; xcrun simctl bootstatus "$device" -b >/dev/null
  xcrun simctl status_bar "$device" override --time 9:41 --batteryState discharging --batteryLevel 100 --wifiBars 3 --cellularBars 4
  xcrun simctl install "$device" $APP
}

shoot() { # device file lang seconds env…
  local device=$1 out=$2 lang=$3 wait=$4; shift 4
  xcrun simctl terminate "$device" de.jelly.tv 2>/dev/null
  env SIMCTL_CHILD_JELLY_SERVER=demo.jellyfin.org/stable SIMCTL_CHILD_JELLY_USER=demo SIMCTL_CHILD_JELLY_ACCESS=active \
      SIMCTL_CHILD_JELLY_SEERR_SERVER=http://127.0.0.1:15055 SIMCTL_CHILD_JELLY_SEERR_PASSWORD=x "$@" \
    xcrun simctl launch "$device" de.jelly.tv -AppleLanguages "($lang)" -AppleLocale $([[ $lang == de ]] && echo de_DE || echo en_US) >/dev/null
  sleep $wait
  mkdir -p ${out:h}; xcrun simctl io "$device" screenshot $out >/dev/null 2>&1 && echo "  $out"
}

for kind in ${1:-iphone ipad}; do
  device=$([[ $kind == iphone ]] && echo $IPHONE || echo $IPAD)
  for lang in de en; do
    dir=AppStore/screenshots-ios/$([[ $lang == de ]] && echo de-DE || echo en-US)/$kind
    boot $device $lang
    shoot $device $dir/1-start.png $lang 30 SIMCTL_CHILD_JELLY_TAB=home
    shoot $device $dir/2-details.png $lang 25 SIMCTL_CHILD_JELLY_TAB=home SIMCTL_CHILD_JELLY_OPEN=$DRACULA
    if [[ $kind == iphone ]]; then
      # The player turns the iPhone to landscape: a 2868×1320 screenshot.
      shoot $device $dir/3-player.png $lang 40 SIMCTL_CHILD_JELLY_TAB=home SIMCTL_CHILD_JELLY_PLAY=$DRACULA SIMCTL_CHILD_JELLY_CONTROLS=1
    else
      shoot $device $dir/3-series.png $lang 30 SIMCTL_CHILD_JELLY_TAB=home SIMCTL_CHILD_JELLY_OPEN=$PIONEER_ONE
    fi
    shoot $device $dir/4-discover.png $lang 35 SIMCTL_CHILD_JELLY_TAB=discover
    shoot $device $dir/5-library.png $lang 25 SIMCTL_CHILD_JELLY_TAB=movies
    xcrun simctl status_bar "$device" clear
    xcrun simctl spawn "$device" defaults write com.apple.Accessibility ReduceMotionEnabled -bool false
    xcrun simctl shutdown "$device"
  done
done
echo "Hochladen: PLATFORM=ios python3 Scripts/asc_appstore.py <Key-ID> <Issuer-ID> <Key-Datei> setup"
