#!/bin/bash
# Builds build/Bobcorn.app from the Swift package.
#
#   scripts/build-app.sh            release build
#   scripts/build-app.sh debug      debug build
#   scripts/build-app.sh install    release build, copied to /Applications
set -euo pipefail

cd "$(dirname "$0")/.."
config=release
install=0
case "${1:-}" in
    debug) config=debug ;;
    install) install=1 ;;
esac

echo "==> swift build -c $config"
swift build -c "$config" --product Bobcorn
bin="$(swift build -c "$config" --show-bin-path)/Bobcorn"

app=build/Bobcorn.app
rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp "$bin" "$app/Contents/MacOS/Bobcorn"
cp Resources/Info.plist "$app/Contents/Info.plist"
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

# Ad-hoc signature, enough to run locally.
codesign --force --sign - "$app" >/dev/null
echo "==> built $app"

if [ "$install" = 1 ]; then
    rm -rf /Applications/Bobcorn.app
    cp -R "$app" /Applications/
    echo "==> installed /Applications/Bobcorn.app"
fi
