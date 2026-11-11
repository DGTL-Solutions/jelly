#!/bin/zsh
# App Store screenshots of the Mac app (AppStore/screenshots-raw/mac/<locale>, then flattened into
# AppStore/screenshots-mac/<locale>), with the public Jellyfin demo server's free films and the Jellyseerr mock.
#   Scripts/screenshots-mac.sh            all languages
#   Scripts/screenshots-mac.sh fr it      only these
# Drives the running app through its command file (see JellyMacApp); the window comes to the front while it runs.
set -u
cd "$(dirname "$0")/.."
APP=.build/dd-mac/Build/Products/Debug/Jelly.app
T=~/Library/Containers/de.jelly.tv/Data/tmp
DRACULA=c002f0f88ee970cce7f138bbc925de64
PIONEER_ONE=9bd5926326d651153928e0d11c6ee7cb

xcodebuild -project Jelly.xcodeproj -scheme JellyMac -configuration Debug -destination "platform=macOS,arch=arm64" \
  -derivedDataPath .build/dd-mac -clonedSourcePackagesDirPath .build/Packages \
  SWIFT_ACTIVE_COMPILATION_CONDITIONS='DEBUG APPSTORE' build 2>&1 | grep -E "error:|BUILD (SUCCEEDED|FAILED)"
[[ -d $APP ]] || exit 1

python3 Scripts/seerr-mock.py > /dev/null 2>&1 &
MOCK=$!
trap 'kill $MOCK 2>/dev/null; pkill -f "Debug/Jelly.app"' EXIT

folder_of() { case $1 in de) echo de-DE;; fr) echo fr-FR;; es) echo es-ES;; it) echo it-IT;; nl) echo nl-NL;; pt-BR) echo pt-BR;; da) echo da-DK;; sv) echo sv-SE;; pl) echo pl-PL;; *) echo en-US;; esac }

launch() { # lang env…
  local lang=$1; shift
  pkill -f "Debug/Jelly.app"; sleep 1; rm -f $T/shot.png $T/command.txt
  local env=(--env JELLY_SERVER=demo.jellyfin.org/stable --env JELLY_USER=demo --env JELLY_ACCESS=active --env JELLY_SHOT=1
             --env JELLY_WINDOW=1440x900 --env JELLY_SEERR_SERVER=http://127.0.0.1:15055 --env JELLY_SEERR_PASSWORD=x)
  for pair in "$@"; do env+=(--env $pair); done
  open $env $APP --args -AppleLanguages "($lang)"
}
shot() { sleep $2; cp $T/shot.png $DIR/$1.png && echo "  $DIR/$1.png"; }
cmd() { echo "$1" > $T/command.txt; }

for lang in ${@:-de en fr es it nl pt-BR da sv pl}; do
  DIR=AppStore/screenshots-raw/mac/$(folder_of $lang); mkdir -p $DIR
  launch $lang JELLY_TAB=home
  shot 1-start 28
  cmd "jelly://item/$DRACULA"; shot 2-details 14
  cmd "tab:home"; cmd "jelly://item/$PIONEER_ONE"; shot 3-series 14
  cmd "tab:discover"; shot 4-discover 16
  cmd "tab:movies"; shot 5-library 14
  launch $lang JELLY_PLAY=$DRACULA JELLY_START=2761 JELLY_CONTROLS=1
  shot 6-player 40
done
swift Scripts/FlattenMacScreenshots.swift
