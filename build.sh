#!/bin/sh
# Builds build/Dropwheel.app and build/dropwheel (the CLI). Needs the Xcode Command Line Tools.
set -e
cd "$(dirname "$0")"
swift build -c release --product Dropwheel
swift build -c release --product dropwheel-cli
APP=build/Dropwheel.app
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp -f .build/release/Dropwheel "$APP/Contents/MacOS/Dropwheel"
cp -f .build/release/dropwheel-cli build/dropwheel
cp -f Info.plist "$APP/Contents/Info.plist"
# AppIcon.png is the 1024px source. Replace it to change the logo.
ICONSET=build/AppIcon.iconset
mkdir -p "$ICONSET"
for s in 16 32 128 256 512; do
  sips -z $s $s AppIcon.png --out "$ICONSET/icon_${s}x${s}.png" >/dev/null
  sips -z $((s * 2)) $((s * 2)) AppIcon.png --out "$ICONSET/icon_${s}x${s}@2x.png" >/dev/null
done
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"
# Helpers in Contents/Resources/Tools win over Homebrew copies at runtime.
# Homebrew ffmpeg links Homebrew dylibs, so a build for other Macs needs static ffmpeg and cwebp there.
codesign --force --sign - "$APP"
echo "Built $APP"
