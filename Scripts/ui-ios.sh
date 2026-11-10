#!/bin/zsh
# Runs a scripted flow in the iPhone simulator: Scripts/ui-ios.sh "<launch env; separated>" "<steps; separated>" [out dir]
# Steps are described in JellyUITests/ScriptedUITest.swift. Screenshots land in the out dir (default /tmp/jelly-ui).
cd "$(dirname "$0")/.."
OUT=${3:-/tmp/jelly-ui}; rm -rf "$OUT"; mkdir -p "$OUT"
TEST_RUNNER_JELLY_ENV="$1" TEST_RUNNER_JELLY_STEPS="$2" TEST_RUNNER_JELLY_OUT="$OUT" \
xcodebuild -project Jelly.xcodeproj -scheme JellyMobile -destination "platform=iOS Simulator,name=${DEVICE:-iPhone 17}" \
  -derivedDataPath .build/dd-ios test 2>&1 | grep -E "error:|Executed|TEST (SUCCEEDED|FAILED)|BUILD FAILED" | sort -u | tail -4
cat "$OUT/log.txt" 2>/dev/null; ls "$OUT"
