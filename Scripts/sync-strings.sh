#!/bin/zsh
# Brings Jelly/Localizable.xcstrings up to date with the strings in the code, after both apps were built
# (.build/dd-ios and .build/dd-tv, as the test commands in the README leave them). New keys then need translations.
cd "$(dirname "$0")/.."
files=()
for file in .build/dd-ios/Build/Intermediates.noindex/Jelly.build/*/{JellyMobile,JellyWidgets}.build/Objects-normal/*/*.stringsdata(N) \
            .build/dd-tv/Build/Intermediates.noindex/Jelly.build/*/{Jelly,JellyTopShelf}.build/Objects-normal/*/*.stringsdata(N); do
  files+=(--stringsdata $file)
done
xcrun xcstringstool sync Jelly/Localizable.xcstrings "${files[@]}"
