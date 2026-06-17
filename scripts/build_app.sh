#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_NAME="${APP_NAME:-GameChatTranslator}"
PRODUCT_NAME="GameChatTranslatorApp"
BUNDLE_ID="${BUNDLE_ID:-dev.pfrommer.gamechattranslator}"
APP_VERSION="${APP_VERSION:-0.1.0}"
BUILD_NUMBER="${BUILD_NUMBER:-1}"
CONFIGURATION="${CONFIGURATION:-release}"
DEPLOYMENT_TARGET="${DEPLOYMENT_TARGET:-13.3}"
DIST_DIR="$ROOT_DIR/dist"
APP_PATH="$DIST_DIR/$APP_NAME.app"
ZIP_PATH="$DIST_DIR/$APP_NAME-$APP_VERSION.zip"
CONTENTS_DIR="$APP_PATH/Contents"
MACOS_DIR="$CONTENTS_DIR/MacOS"
FRAMEWORKS_DIR="$CONTENTS_DIR/Frameworks"
RESOURCES_DIR="$CONTENTS_DIR/Resources"
ENTITLEMENTS="$ROOT_DIR/Packaging/GameChatTranslator.entitlements"
CODESIGN_IDENTITY="${CODESIGN_IDENTITY:--}"

WHISPER_BUILD_DIR="$ROOT_DIR/vendor/whisper.cpp/build"

if [[ ! -e "$ROOT_DIR/vendor/whisper.cpp/.git" ]]; then
  echo "whisper.cpp submodule is missing. Run:"
  echo "  git submodule update --init --recursive"
  exit 1
fi

echo "Configuring whisper.cpp..."
cmake -S "$ROOT_DIR/vendor/whisper.cpp" -B "$WHISPER_BUILD_DIR" \
  -DWHISPER_BUILD_TESTS=OFF \
  -DWHISPER_BUILD_EXAMPLES=OFF \
  -DGGML_METAL=OFF \
  -DCMAKE_OSX_DEPLOYMENT_TARGET="$DEPLOYMENT_TARGET"

cmake --build "$WHISPER_BUILD_DIR" --config Release

echo "Building Swift release binaries..."
MACOSX_DEPLOYMENT_TARGET="$DEPLOYMENT_TARGET" swift build -c "$CONFIGURATION" --product "$PRODUCT_NAME" --package-path "$ROOT_DIR"

BUILD_DIR="$(swift build -c "$CONFIGURATION" --show-bin-path --package-path "$ROOT_DIR")"
APP_BINARY="$BUILD_DIR/$PRODUCT_NAME"

if [[ ! -x "$APP_BINARY" ]]; then
  echo "Expected release binaries were not produced."
  exit 1
fi

echo "Creating app bundle..."
rm -rf "$APP_PATH" "$ZIP_PATH"
mkdir -p "$MACOS_DIR" "$FRAMEWORKS_DIR" "$RESOURCES_DIR"

ditto "$APP_BINARY" "$MACOS_DIR/$APP_NAME"
chmod 755 "$MACOS_DIR/$APP_NAME"

cat > "$CONTENTS_DIR/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
  "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleDevelopmentRegion</key>
  <string>en</string>
  <key>CFBundleDisplayName</key>
  <string>Game Chat Translator</string>
  <key>CFBundleExecutable</key>
  <string>$APP_NAME</string>
  <key>CFBundleIdentifier</key>
  <string>$BUNDLE_ID</string>
  <key>CFBundleInfoDictionaryVersion</key>
  <string>6.0</string>
  <key>CFBundleName</key>
  <string>Game Chat Translator</string>
  <key>CFBundlePackageType</key>
  <string>APPL</string>
  <key>CFBundleShortVersionString</key>
  <string>$APP_VERSION</string>
  <key>CFBundleVersion</key>
  <string>$BUILD_NUMBER</string>
  <key>LSApplicationCategoryType</key>
  <string>public.app-category.utilities</string>
  <key>LSMinimumSystemVersion</key>
  <string>$DEPLOYMENT_TARGET</string>
  <key>NSHighResolutionCapable</key>
  <true/>
  <key>NSPrincipalClass</key>
  <string>NSApplication</string>
  <key>NSSupportsAutomaticGraphicsSwitching</key>
  <true/>
  <key>NSScreenCaptureUsageDescription</key>
  <string>Game Chat Translator captures system audio locally so it can transcribe and translate voice chat. Captured audio is kept in memory and is not saved to disk.</string>
</dict>
</plist>
PLIST

copy_dylibs_from() {
  local source_dir="$1"
  if [[ -d "$source_dir" ]]; then
    for dylib in "$source_dir"/*.dylib; do
      [[ -e "$dylib" ]] || continue
      ditto "$dylib" "$FRAMEWORKS_DIR/$(basename "$dylib")"
    done
  fi
}

copy_dylibs_from "$WHISPER_BUILD_DIR/src"
copy_dylibs_from "$WHISPER_BUILD_DIR/ggml/src"
copy_dylibs_from "$WHISPER_BUILD_DIR/ggml/src/ggml-blas"

MODEL_TO_BUNDLE="${INCLUDE_MODEL:-}"
if [[ -z "$MODEL_TO_BUNDLE" && -f "$ROOT_DIR/models/ggml-small.bin" ]]; then
  MODEL_TO_BUNDLE="$ROOT_DIR/models/ggml-small.bin"
fi

if [[ "$MODEL_TO_BUNDLE" != "" && "$MODEL_TO_BUNDLE" != "none" ]]; then
  if [[ ! -f "$MODEL_TO_BUNDLE" ]]; then
    echo "INCLUDE_MODEL does not exist: $MODEL_TO_BUNDLE"
    exit 1
  fi
  mkdir -p "$RESOURCES_DIR/models"
  ditto "$MODEL_TO_BUNDLE" "$RESOURCES_DIR/models/$(basename "$MODEL_TO_BUNDLE")"
  if [[ "$(basename "$MODEL_TO_BUNDLE")" != "ggml-small.bin" ]]; then
    echo "Bundled model: $(basename "$MODEL_TO_BUNDLE")"
    echo "The GUI default still points to ggml-small.bin; choose this model manually on first launch."
  fi
else
  echo "No model bundled. Users can choose a local ggml model in the app."
fi

for dev_rpath in \
  "@executable_path/../../../vendor/whisper.cpp/build/src" \
  "@executable_path/../../../vendor/whisper.cpp/build/ggml/src" \
  "@executable_path/../../../vendor/whisper.cpp/build/ggml/src/ggml-blas" \
  "@executable_path/../../../vendor/whisper.cpp/build/ggml/src/ggml-metal"
do
  install_name_tool -delete_rpath "$dev_rpath" "$MACOS_DIR/$APP_NAME" 2>/dev/null || true
done

SDK_VERSION="$(xcrun --sdk macosx --show-sdk-version 2>/dev/null || echo "$DEPLOYMENT_TARGET")"
set_build_version() {
  local binary="$1"
  local temp_binary="$binary.vtool"
  vtool -set-build-version macos "$DEPLOYMENT_TARGET" "$SDK_VERSION" -replace -output "$temp_binary" "$binary"
  mv "$temp_binary" "$binary"
  chmod 755 "$binary"
}

set_build_version "$MACOS_DIR/$APP_NAME"

echo "Signing app bundle..."
if [[ "$CODESIGN_IDENTITY" == "-" ]]; then
  find "$FRAMEWORKS_DIR" -type f -name "*.dylib" -print0 | while IFS= read -r -d '' dylib; do
    codesign --force --sign - "$dylib"
  done
  codesign --force --sign - "$MACOS_DIR/$APP_NAME"
  codesign --force --sign - "$APP_PATH"
else
  find "$FRAMEWORKS_DIR" -type f -name "*.dylib" -print0 | while IFS= read -r -d '' dylib; do
    codesign --force --options runtime --timestamp --sign "$CODESIGN_IDENTITY" "$dylib"
  done
  codesign --force --options runtime --timestamp --entitlements "$ENTITLEMENTS" --sign "$CODESIGN_IDENTITY" "$MACOS_DIR/$APP_NAME"
  codesign --force --options runtime --timestamp --entitlements "$ENTITLEMENTS" --sign "$CODESIGN_IDENTITY" "$APP_PATH"
fi

codesign --verify --deep --strict --verbose=2 "$APP_PATH"

echo "Creating release zip..."
ditto -c -k --keepParent "$APP_PATH" "$ZIP_PATH"

echo
echo "Built:"
echo "  $APP_PATH"
echo "  $ZIP_PATH"
echo
if [[ "$CODESIGN_IDENTITY" == "-" ]]; then
  echo "Signed ad-hoc for local testing. For public distribution, rebuild with:"
  echo "  CODESIGN_IDENTITY=\"Developer ID Application: Your Name (TEAMID)\" ./scripts/build_app.sh"
  echo "Then notarize the generated zip with xcrun notarytool and staple the app."
else
  echo "Signed with Developer ID identity: $CODESIGN_IDENTITY"
  echo "Next notarization step:"
  echo "  xcrun notarytool submit \"$ZIP_PATH\" --keychain-profile <profile> --wait"
  echo "  xcrun stapler staple \"$APP_PATH\""
fi
