#!/bin/sh
# Builds build/Dropwheel.app and build/dropwheel (the CLI). Needs the Xcode Command Line Tools.
set -e
cd "$(dirname "$0")"
# UNIVERSAL=1 builds for Apple silicon and Intel. It needs full Xcode, not only the Command Line Tools.
if [ -n "$UNIVERSAL" ]; then ARCHS="--arch arm64 --arch x86_64"; OUT=.build/apple/Products/Release; else ARCHS=""; OUT=.build/release; fi
swift build -c release $ARCHS --product Dropwheel
swift build -c release $ARCHS --product dropwheel-cli
APP=build/Dropwheel.app
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp -f "$OUT/Dropwheel" "$APP/Contents/MacOS/Dropwheel"
cp -f "$OUT/dropwheel-cli" build/dropwheel
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
# VERSION=1.2.3 sets the version that Finder and the About window show.
if [ -n "$VERSION" ]; then /usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" "$APP/Contents/Info.plist"; fi
codesign --force --sign - "$APP"
echo "Built $APP"
