#!/bin/bash
# Builds build/Bobcorn.app from the Swift package.
#
#   scripts/build-app.sh            release build
#   scripts/build-app.sh debug      debug build
#   scripts/build-app.sh install    release build, copied to /Applications
#
# VERSION=1.2.0 stamps that version in; UNIVERSAL=1 builds for both Apple
# silicon and Intel; SIGN_IDENTITY="Developer ID Application: …" signs it for
# distribution, with the hardened runtime notarization needs.
set -euo pipefail

cd "$(dirname "$0")/.."
config=release
install=0
case "${1:-}" in
    debug) config=debug ;;
    install) install=1 ;;
esac

arch=()
if [ "${UNIVERSAL:-0}" = 1 ]; then arch=(--arch arm64 --arch x86_64); fi
echo "==> swift build -c $config ${arch[*]:-}"
swift build -c "$config" ${arch[@]+"${arch[@]}"} --product Bobcorn
bin="$(swift build -c "$config" ${arch[@]+"${arch[@]}"} --show-bin-path)/Bobcorn"

app=build/Bobcorn.app
rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp "$bin" "$app/Contents/MacOS/Bobcorn"
cp Resources/Info.plist "$app/Contents/Info.plist"
if [ -n "${VERSION:-}" ]; then
    /usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" "$app/Contents/Info.plist"
    /usr/libexec/PlistBuddy -c "Set :CFBundleVersion $VERSION" "$app/Contents/Info.plist"
fi
if [ "$config" = debug ]; then
    # A debug build keeps its own settings and data, and never claims
    # magnet links or .torrent files from the installed app.
    plist="$app/Contents/Info.plist"
    /usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier me.alsubhi.Bobcorn.debug" "$plist"
    /usr/libexec/PlistBuddy -c "Delete :CFBundleURLTypes" "$plist"
    /usr/libexec/PlistBuddy -c "Delete :CFBundleDocumentTypes" "$plist"
fi

icns=build/AppIcon.icns
if [ ! -f "$icns" ] || [ scripts/make-icon.swift -nt "$icns" ]; then
    echo "==> rendering icon"
    tmp="$(mktemp -d)"
    swift scripts/make-icon.swift "$tmp/icon.png" >/dev/null
    set="$tmp/AppIcon.iconset"
    mkdir -p "$set"
    for s in 16 32 128 256 512; do
        sips -z $s $s "$tmp/icon.png" --out "$set/icon_${s}x${s}.png" >/dev/null
        sips -z $((s * 2)) $((s * 2)) "$tmp/icon.png" --out "$set/icon_${s}x${s}@2x.png" >/dev/null
    done
    iconutil -c icns "$set" -o "$icns"
    rm -rf "$tmp"
fi
cp "$icns" "$app/Contents/Resources/AppIcon.icns"

if [ -n "${SIGN_IDENTITY:-}" ]; then
    codesign --force --options runtime --timestamp --sign "$SIGN_IDENTITY" "$app"
else
    # Ad-hoc signature, enough to run locally.
    codesign --force --sign - "$app" >/dev/null
fi
echo "==> built $app"

if [ "$install" = 1 ]; then
    rm -rf /Applications/Bobcorn.app
    cp -R "$app" /Applications/
    echo "==> installed /Applications/Bobcorn.app"
fi
