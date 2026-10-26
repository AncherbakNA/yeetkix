#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
architecture="${1:-arm64}"
bash scripts/build-app.sh "$architecture"
version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' build/Yeetkix.app/Contents/Info.plist)"
archive="$(pwd)/build/Yeetkix-$version-macOS-$architecture"
ditto -c -k --sequesterRsrc --keepParent build/Yeetkix.app "$archive.zip"
stage="$(mktemp -d "$(pwd)/build/dmg.XXXXXX")"
trap 'rm -rf "$stage"' EXIT
ditto build/Yeetkix.app "$stage/Yeetkix.app"
ln -s /Applications "$stage/Applications"
hdiutil create -volname "YEETKIX $version" -srcfolder "$stage" -ov -format UDZO "$archive.dmg"
(
    cd build
    shasum -a 256 "Yeetkix-$version-macOS-$architecture.zip" "Yeetkix-$version-macOS-$architecture.dmg" > "Yeetkix-$version-macOS-$architecture.sha256"
)
printf 'Архивы: %s.zip и .dmg\n' "$archive"
