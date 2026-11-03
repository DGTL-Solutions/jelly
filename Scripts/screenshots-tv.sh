#!/bin/zsh
# Raw App Store screenshots of the Apple TV app (AppStore/screenshots-raw/tv/<locale>, 1920×1080) with the public
# Jellyfin demo server's free films; then Scripts/FrameScreenshots.swift adds the headlines (AppStore/captions.json).
#   Scripts/screenshots-tv.sh             German, English, French, Spanish, Italian and Dutch
#   Scripts/screenshots-tv.sh fr          only one language (de | en | fr | es | it | nl)
# Builds the store variant first (Debug for the JELLY_* launch settings, APPSTORE for what the store version shows).
set -u
cd "$(dirname "$0")/.."
TV="Apple TV 4K (3rd generation) (at 1080p)"  # 1920×1080
DRACULA=c002f0f88ee970cce7f138bbc925de64
APP=.build/tv-shots/Build/Products/Debug-appletvsimulator/Jelly.app

xcodebuild -project Jelly.xcodeproj -scheme Jelly -configuration Debug -destination 'generic/platform=tvOS Simulator' \
  -derivedDataPath .build/tv-shots -clonedSourcePackagesDirPath .build/Packages CODE_SIGN_IDENTITY=- EXCLUDED_ARCHS=x86_64 \
  SWIFT_ACTIVE_COMPILATION_CONDITIONS='DEBUG APPSTORE' build 2>&1 | grep -E "error:|BUILD (SUCCEEDED|FAILED)"
[[ -d $APP ]] || exit 1
trap 'xcrun simctl shutdown "$TV" 2>/dev/null' EXIT

locale_of() { case $1 in de) echo de_DE;; fr) echo fr_FR;; es) echo es_ES;; it) echo it_IT;; nl) echo nl_NL;; *) echo en_US;; esac }

shoot() { # file lang seconds env…
  local out=$1 lang=$2 wait=$3; shift 3
  xcrun simctl terminate "$TV" de.jelly.tv 2>/dev/null
  env SIMCTL_CHILD_JELLY_SERVER=demo.jellyfin.org/stable SIMCTL_CHILD_JELLY_USER=demo SIMCTL_CHILD_JELLY_ACCESS=active "$@" \
    xcrun simctl launch "$TV" de.jelly.tv -AppleLanguages "($lang)" -AppleLocale $(locale_of $lang) >/dev/null
  sleep $wait
  mkdir -p ${out:h}; xcrun simctl io "$TV" screenshot $out >/dev/null 2>&1 && echo "  $out"
}

xcrun simctl boot "$TV" 2>/dev/null; xcrun simctl bootstatus "$TV" -b >/dev/null
xcrun simctl install "$TV" $APP
for lang in ${=1:-de en fr es it nl}; do
  dir=AppStore/screenshots-raw/tv/$(locale_of $lang | tr _ -)
  shoot $dir/1-start.png $lang 30
  shoot $dir/2-details.png $lang 25 SIMCTL_CHILD_JELLY_OPEN=$DRACULA
  shoot $dir/3-player.png $lang 35 SIMCTL_CHILD_JELLY_PLAY=$DRACULA SIMCTL_CHILD_JELLY_START=609 SIMCTL_CHILD_JELLY_CONTROLS=1
  shoot $dir/4-info.png $lang 35 SIMCTL_CHILD_JELLY_PLAY=$DRACULA SIMCTL_CHILD_JELLY_START=609 SIMCTL_CHILD_JELLY_PANEL=info
done
swift Scripts/FrameScreenshots.swift
echo "Hochladen: python3 Scripts/asc_appstore.py <Key-ID> <Issuer-ID> <Key-Datei> setup"
