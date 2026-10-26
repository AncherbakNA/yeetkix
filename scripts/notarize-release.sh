#!/bin/bash
# Optional future public release. Requires credentials already configured in Keychain.
set -euo pipefail
cd "$(dirname "$0")/.."
: "${YEETKIX_SIGNING_IDENTITY:?Set the Developer ID Application identity from your Keychain}"
: "${YEETKIX_NOTARY_PROFILE:?Set an existing notarytool Keychain profile name}"
security find-identity -v -p codesigning | /usr/bin/grep -F -- "$YEETKIX_SIGNING_IDENTITY" >/dev/null || { echo 'Signing identity not found' >&2; exit 2; }
test -d build/Yeetkix.app
stage="$(mktemp -d "$(pwd)/build/signed.XXXXXX")"
app="$stage/Yeetkix.app"
ditto build/Yeetkix.app "$app"
framework="$app/Contents/Frameworks/Sparkle.framework"
for target in \
    "$framework/Versions/B/XPCServices/Downloader.xpc" \
    "$framework/Versions/B/XPCServices/Installer.xpc" \
    "$framework/Versions/B/Autoupdate" \
    "$framework/Versions/B/Updater.app" \
    "$framework" "$app"; do
    codesign --force --sign "$YEETKIX_SIGNING_IDENTITY" --options runtime --timestamp "$target"
done
codesign --verify --deep --strict --verbose=2 "$app"
ditto -c -k --sequesterRsrc --keepParent "$app" "$stage/Yeetkix-notarization.zip"
xcrun notarytool submit "$stage/Yeetkix-notarization.zip" --keychain-profile "$YEETKIX_NOTARY_PROFILE" --wait
xcrun stapler staple "$app"
xcrun stapler validate "$app"
spctl --assess --type execute --verbose=2 "$app"
ditto -c -k --sequesterRsrc --keepParent "$app" "$stage/Yeetkix-notarized.zip"
printf 'Подписанная сборка сохранена: %s\n' "$stage"
