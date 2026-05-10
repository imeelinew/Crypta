#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD_DIR="$ROOT_DIR/.build/arm64-apple-macosx/release"
APP_DIR="$ROOT_DIR/.build/Crypta.app"
CONTENTS_DIR="$APP_DIR/Contents"
MACOS_DIR="$CONTENTS_DIR/MacOS"
RESOURCES_DIR="$CONTENTS_DIR/Resources"
ICON_TOOL="/Applications/Xcode.app/Contents/Applications/Icon Composer.app/Contents/Executables/ictool"
ICON_SOURCE="$ROOT_DIR/Sources/Crypta/Resources/AppIcon.icon"
ICONSET_DIR="$ROOT_DIR/Sources/Crypta/Resources/AppIcon.iconset"

swift build -c release --package-path "$ROOT_DIR"

if [[ -x "$ICON_TOOL" && -d "$ICON_SOURCE" ]]; then
    rm -rf "$ICONSET_DIR"
    mkdir -p "$ICONSET_DIR"
    "$ICON_TOOL" "$ICON_SOURCE" --export-image --output-file "$ICONSET_DIR/icon_16x16.png" --platform macOS --rendition Default --width 16 --height 16 --scale 1 >/dev/null
    "$ICON_TOOL" "$ICON_SOURCE" --export-image --output-file "$ICONSET_DIR/icon_16x16@2x.png" --platform macOS --rendition Default --width 32 --height 32 --scale 1 >/dev/null
    "$ICON_TOOL" "$ICON_SOURCE" --export-image --output-file "$ICONSET_DIR/icon_32x32.png" --platform macOS --rendition Default --width 32 --height 32 --scale 1 >/dev/null
    "$ICON_TOOL" "$ICON_SOURCE" --export-image --output-file "$ICONSET_DIR/icon_32x32@2x.png" --platform macOS --rendition Default --width 64 --height 64 --scale 1 >/dev/null
    "$ICON_TOOL" "$ICON_SOURCE" --export-image --output-file "$ICONSET_DIR/icon_128x128.png" --platform macOS --rendition Default --width 128 --height 128 --scale 1 >/dev/null
    "$ICON_TOOL" "$ICON_SOURCE" --export-image --output-file "$ICONSET_DIR/icon_128x128@2x.png" --platform macOS --rendition Default --width 256 --height 256 --scale 1 >/dev/null
    "$ICON_TOOL" "$ICON_SOURCE" --export-image --output-file "$ICONSET_DIR/icon_256x256.png" --platform macOS --rendition Default --width 256 --height 256 --scale 1 >/dev/null
    "$ICON_TOOL" "$ICON_SOURCE" --export-image --output-file "$ICONSET_DIR/icon_256x256@2x.png" --platform macOS --rendition Default --width 512 --height 512 --scale 1 >/dev/null
    "$ICON_TOOL" "$ICON_SOURCE" --export-image --output-file "$ICONSET_DIR/icon_512x512.png" --platform macOS --rendition Default --width 512 --height 512 --scale 1 >/dev/null
    "$ICON_TOOL" "$ICON_SOURCE" --export-image --output-file "$ICONSET_DIR/icon_512x512@2x.png" --platform macOS --rendition Default --width 1024 --height 1024 --scale 1 >/dev/null
    cp "$ICONSET_DIR/icon_512x512@2x.png" "$ROOT_DIR/Sources/Crypta/Resources/AppIcon.png"
    iconutil --convert icns --output "$ROOT_DIR/Sources/Crypta/Resources/AppIcon.icns" "$ICONSET_DIR"
fi

rm -rf "$APP_DIR"
mkdir -p "$MACOS_DIR" "$RESOURCES_DIR"

cp "$BUILD_DIR/Crypta" "$MACOS_DIR/Crypta"
cp "$ROOT_DIR/Sources/Crypta/Resources/AppIcon.icns" "$RESOURCES_DIR/AppIcon.icns"

cat > "$CONTENTS_DIR/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key>
    <string>en</string>
    <key>CFBundleExecutable</key>
    <string>Crypta</string>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>CFBundleIdentifier</key>
    <string>local.elidev.Crypta</string>
    <key>CFBundleInfoDictionaryVersion</key>
    <string>6.0</string>
    <key>CFBundleName</key>
    <string>Crypta</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>0.2.0</string>
    <key>CFBundleVersion</key>
    <string>1</string>
    <key>LSMinimumSystemVersion</key>
    <string>26.0</string>
    <key>NSHighResolutionCapable</key>
    <true/>
</dict>
</plist>
PLIST

echo "$APP_DIR"
