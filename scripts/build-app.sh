#!/bin/sh
set -eu

PROJECT_ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
BUILD_DIR=${MACGAMEDOCK_BUILD_DIR:-"$PROJECT_ROOT/.build"}
OUTPUT_DIR=${MACGAMEDOCK_APP_OUTPUT:-"$PROJECT_ROOT/dist"}
APP="$OUTPUT_DIR/MacGameDeck.app"
SWIFT_TOOL=$(xcrun --find swift)
export CLANG_MODULE_CACHE_PATH="$BUILD_DIR/module-cache"

"$SWIFT_TOOL" build --package-path "$PROJECT_ROOT" --configuration release \
    --scratch-path "$BUILD_DIR" --cache-path "$BUILD_DIR/cache" \
    --config-path "$BUILD_DIR/config" --security-path "$BUILD_DIR/security" --disable-sandbox
BIN_DIR=$("$SWIFT_TOOL" build --package-path "$PROJECT_ROOT" --configuration release \
    --scratch-path "$BUILD_DIR" --cache-path "$BUILD_DIR/cache" \
    --config-path "$BUILD_DIR/config" --security-path "$BUILD_DIR/security" --disable-sandbox --show-bin-path)

mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/MacGameDock" "$APP/Contents/MacOS/MacGameDock"
cp -R "$BIN_DIR/MacGameDock_MacGameDock.bundle" "$APP/Contents/Resources/"
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
    <key>CFBundleName</key><string>MacGameDeck</string>
    <key>CFBundleDisplayName</key><string>MacGameDeck</string>
    <key>CFBundleIdentifier</key><string>com.macgamedock.app</string>
    <key>CFBundleExecutable</key><string>MacGameDock</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>0.6.0</string>
    <key>CFBundleVersion</key><string>8</string>
    <key>LSMinimumSystemVersion</key><string>13.0</string>
    <key>NSHighResolutionCapable</key><true/>
</dict></plist>
PLIST
/usr/bin/codesign --force --sign - --identifier com.macgamedock.app "$APP"
printf '%s\n' "App di sviluppo creata: $APP"
