#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
architecture="${1:-arm64}"
test "$architecture" = arm64 || { echo 'Only Apple Silicon (arm64) is supported' >&2; exit 2; }
export YEETKIX_VERSION="${YEETKIX_VERSION:-1.0}"
export YEETKIX_BUILD="${YEETKIX_BUILD:-8}"
mkdir -p build
stage="$(mktemp -d "$(pwd)/build/package.XXXXXX")"
trap 'rm -rf "$stage"' EXIT
app="$stage/Yeetkix.app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources" "$app/Contents/Frameworks"
swift build -c release --arch arm64 --product Yeetkix -debug-info-format none
arm_bin="$(swift build -c release --arch arm64 --show-bin-path)"
cp "$arm_bin/Yeetkix" "$app/Contents/MacOS/Yeetkix"
sparkle_root=.build/artifacts/sparkle/Sparkle
ditto "$sparkle_root/Sparkle.xcframework/macos-arm64_x86_64/Sparkle.framework" "$app/Contents/Frameworks/Sparkle.framework"
cp "$sparkle_root/LICENSE" "$app/Contents/Resources/Sparkle-LICENSE.txt"
if [ ! -f Resources/AppIcon.icns ]; then swift scripts/make-icon.swift; fi
cp Resources/AppIcon.icns "$app/Contents/Resources/AppIcon.icns"
cp docs/GUIDE.md docs/AI_DISCLOSURE.md "$app/Contents/Resources/"
python3 scripts/write-info.py "$app/Contents/Info.plist"
codesign --force --sign - "$app"
codesign --verify --deep --strict "$app"
if [ -e build/Yeetkix.app ]; then
    mkdir -p build/Previous
    mv build/Yeetkix.app "build/Previous/Yeetkix-$(date +%Y%m%d-%H%M%S)-$$.app"
fi
mv "$app" build/Yeetkix.app
printf 'Готово: %s/build/Yeetkix.app (%s)\n' "$(pwd)" "$architecture"
