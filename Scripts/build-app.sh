#!/bin/bash
set -euo pipefail

cd "$(dirname "$0")/.."
swift build -c release
bin="$(swift build -c release --show-bin-path)/LumaTodo"
mkdir -p Release
stage="$(mktemp -d "$PWD/Release/.stage.XXXXXX")"
trap 'rm -rf -- "$stage"' EXIT
app="$stage/LumaTodo.app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
install -m 755 "$bin" "$app/Contents/MacOS/LumaTodo"
install -m 644 Resources/AppIcon.icns "$app/Contents/Resources/AppIcon.icns"
install -m 644 Resources/Info.plist "$app/Contents/Info.plist"
plutil -replace CFBundleIdentifier -string io.lumatodo.mac "$app/Contents/Info.plist"
plutil -replace CFBundleExecutable -string LumaTodo "$app/Contents/Info.plist"
codesign --force --sign "${LUMATODO_SIGNING_IDENTITY:--}" "$app"
codesign --verify --strict "$app"
rm -rf -- Release/LumaTodo.app
mv "$app" Release/LumaTodo.app
printf '%s\n' "$PWD/Release/LumaTodo.app"
