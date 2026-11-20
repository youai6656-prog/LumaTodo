#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."

sources_root="${LUMATODO_PROFILE_SOURCES:-Sources}"
probe_dir="$(mktemp -d)"
trap 'rm -rf -- "$probe_dir"' EXIT
app="$probe_dir/LumaTodo Profile.app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
plist="$app/Contents/Info.plist"
cp Resources/Info.plist "$plist"
cp Resources/AppIcon.icns "$app/Contents/Resources/"
plutil -replace CFBundleIdentifier -string io.lumatodo.mac.motion-profile "$plist"
plutil -replace CFBundleExecutable -string LumaTodo "$plist"

sources=()
while IFS= read -r -d '' source; do sources+=("$source"); done \
    < <(find "$sources_root/LumaTodo" -type f -name '*.swift' ! -name 'LumaTodoApp.swift' -print0)
swiftc -O -whole-module-optimization -swift-version 6 -module-name LumaTodo -target "$(uname -m)-apple-macosx26.0" \
    "${sources[@]}" Tests/NativeMotionProfile.swift -o "$app/Contents/MacOS/LumaTodo"
codesign --force --sign - "$app"
"$app/Contents/MacOS/LumaTodo" "$@"
