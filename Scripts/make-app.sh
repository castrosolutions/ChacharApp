#!/usr/bin/env bash
# Assemble a runnable ChacharApp.app from the xcodebuild-built executable.
#
# Why xcodebuild (not `swift build`): MLX's Metal kernels (default.metallib) are ONLY compiled by
# Xcode's build system; plain `swift build` skips them and MLX crashes at runtime with
# "Failed to load the default metallib". Usage: Scripts/make-app.sh [debug|release]
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CONFIG="${1:-debug}"
case "$CONFIG" in
    release|Release) XC_CONFIG="Release" ;;
    *)               XC_CONFIG="Debug" ;;
esac
APP_NAME="ChacharApp"
# Local/dev builds get a distinct bundle id + display name so their TCC grants (Microphone,
# Accessibility) never collide with the notarized distribution build (Scripts/release.sh), which
# keeps the clean id. Same id + a different signing cert makes macOS treat two builds as different
# apps that clobber each other's grants.
BUNDLE_ID="com.juanpablocastro.chacharapp.dev"
DISPLAY_NAME="ChacharApp (dev)"
DERIVED="$ROOT/.build/xcode"

echo "Building chacharapp via xcodebuild ($XC_CONFIG)…"
xcodebuild -scheme chacharapp -configuration "$XC_CONFIG" \
    -derivedDataPath "$DERIVED" -destination 'platform=macOS,arch=arm64' \
    -skipMacroValidation -skipPackagePluginValidation \
    CODE_SIGNING_ALLOWED=NO build >/dev/null

PRODUCTS="$DERIVED/Build/Products/$XC_CONFIG"
APP="$ROOT/.build/$APP_NAME.app"
CONTENTS="$APP/Contents"

rm -rf "$APP"
mkdir -p "$CONTENTS/MacOS" "$CONTENTS/Resources"
cp "$PRODUCTS/chacharapp" "$CONTENTS/MacOS/chacharapp"

# Copy resource bundles into Resources so Bundle.module / MLX resolve at runtime — crucially
# mlx-swift_Cmlx.bundle (default.metallib) and swift-transformers_Hub.bundle.
for bundle in "$PRODUCTS"/*.bundle; do
    [ -e "$bundle" ] && cp -R "$bundle" "$CONTENTS/Resources/"
done

# Symlink the local Whisper model into the bundle (codesign seals the symlink, not the 600 MB).
ln -sfn "$ROOT/Models" "$CONTENTS/Resources/Models"

# App icon + menu bar icon.
"$ROOT/Scripts/make-icns.sh" "$ROOT/Assets/AppIcon.png" "$CONTENTS/Resources/AppIcon.icns" >/dev/null
cp "$ROOT/Assets/MenuBarIcon.png" "$CONTENTS/Resources/MenuBarIcon.png"

cat > "$CONTENTS/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>${APP_NAME}</string>
    <key>CFBundleDisplayName</key><string>${DISPLAY_NAME}</string>
    <key>CFBundleIdentifier</key><string>${BUNDLE_ID}</string>
    <key>CFBundleExecutable</key><string>chacharapp</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>CFBundleIconName</key><string>AppIcon</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>0.0.1</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>LSUIElement</key><true/>
    <key>NSMicrophoneUsageDescription</key>
    <string>ChacharApp transcribes your speech locally while you hold the push-to-talk key.</string>
    <key>NSHumanReadableCopyright</key><string>© 2026</string>
</dict>
</plist>
PLIST

# Prefer a stable signing identity so TCC grants persist across rebuilds; fall back to ad-hoc.
IDENTITY="$(security find-identity -v -p codesigning 2>/dev/null \
    | awk -F'"' '/Developer ID Application/{print $2; exit} /Apple Development/{print $2; exit}')"
if [ -n "$IDENTITY" ]; then
    echo "Signing with stable identity: $IDENTITY"
    codesign --force --sign "$IDENTITY" "$APP"
else
    echo "No stable identity found; ad-hoc signing (TCC may need re-granting on each rebuild)."
    codesign --force --sign - "$APP"
fi

echo "Built: $APP"
echo "Run it with:  open \"$APP\""
