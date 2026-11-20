#!/bin/bash
set -euo pipefail

cd "$(dirname "$0")/.."
case "${1:-}" in
    ""|--notifications|--record=*) ;;
    *)
        printf 'Usage: %s [--notifications|--record=PATH]\n' "$0" >&2
        exit 2
        ;;
esac
probe_dir="$(mktemp -d)"
trap 'rm -rf -- "$probe_dir"' EXIT
app="$probe_dir/LumaTodo QA.app"
plist="$app/Contents/Info.plist"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp Resources/Info.plist "$plist"
cp Resources/AppIcon.icns "$app/Contents/Resources/"
# Reuse the notification authorization of the established non-production QA identity, if present.
plutil -replace CFBundleIdentifier -string io.lumatodo.mac.roundtwo.qa "$plist"
plutil -replace CFBundleExecutable -string LumaTodo "$plist"
plutil -replace CFBundleName -string 'LumaTodo QA' "$plist"
plutil -replace CFBundleDisplayName -string 'LumaTodo QA' "$plist"

sources=()
while IFS= read -r -d '' source; do
    sources+=("$source")
done < <(find Sources/LumaTodo -type f -name '*.swift' ! -name 'LumaTodoApp.swift' -print0)
swiftc -D DEBUG -swift-version 6 -module-name LumaTodo -target "$(uname -m)-apple-macosx26.0" \
    "${sources[@]}" Tests/NativeAcceptanceProbe.swift Tests/NativeMotionRecording.swift -o "$app/Contents/MacOS/LumaTodo"
codesign --force --sign - "$app"
"$app/Contents/MacOS/LumaTodo" "$@"
