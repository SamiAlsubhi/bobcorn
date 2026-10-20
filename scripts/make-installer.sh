#!/bin/bash
# Builds build/Bobcorn.dmg: a disk image holding Bobcorn.app beside a link
# to Applications, to install by dragging one onto the other.
#
#   scripts/make-installer.sh
#   VERSION=1.2.0 scripts/make-installer.sh
#
# It runs on Apple silicon and Intel Macs.
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
codesign --force --sign - "$dmg" >/dev/null
echo "==> built $dmg ($(du -h "$dmg" | cut -f1 | tr -d ' '))"
