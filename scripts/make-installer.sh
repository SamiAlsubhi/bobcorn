#!/bin/bash
# Builds build/Bobcorn.dmg: a disk image holding Bobcorn.app beside a link
# to Applications, to install by dragging one onto the other.
#
#   scripts/make-installer.sh
#   VERSION=1.2.0 scripts/make-installer.sh
#
# It runs on Apple silicon and Intel Macs. With SIGN_IDENTITY set (see
# build-app.sh) the app and image are signed for distribution, and with an
# App Store Connect API key (NOTARY_KEY_PATH, NOTARY_KEY_ID,
# NOTARY_ISSUER_ID) the image is notarized and the ticket stapled to it, so
# it opens on any Mac without a warning.
set -euo pipefail

cd "$(dirname "$0")/.."
UNIVERSAL=1 scripts/build-app.sh

version=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" build/Bobcorn.app/Contents/Info.plist)
dmg=build/Bobcorn.dmg
stage="$(mktemp -d)"
trap 'rm -rf "$stage"' EXIT

cp -R build/Bobcorn.app "$stage/"
ln -s /Applications "$stage/Applications"

echo "==> hdiutil create"
rm -f "$dmg"
hdiutil create -quiet -volname "Bobcorn $version" -srcfolder "$stage" -fs HFS+ -format UDZO -ov "$dmg"
# An image signed ad hoc is one Gatekeeper rejects outright; unsigned, it at
# least opens. Only a real identity signs it.
if [ -n "${SIGN_IDENTITY:-}" ]; then
    codesign --force --timestamp --sign "$SIGN_IDENTITY" "$dmg"
fi
if [ -n "${NOTARY_KEY_PATH:-}" ] && [ -n "${NOTARY_KEY_ID:-}" ] && [ -n "${NOTARY_ISSUER_ID:-}" ]; then
    echo "==> notarizing"
    xcrun notarytool submit "$dmg" --key "$NOTARY_KEY_PATH" --key-id "$NOTARY_KEY_ID" --issuer "$NOTARY_ISSUER_ID" --wait
    xcrun stapler staple "$dmg"
fi
echo "==> built $dmg ($(du -h "$dmg" | cut -f1 | tr -d ' '))"
