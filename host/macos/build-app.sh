#!/bin/zsh
set -euo pipefail

SCRIPT_DIR=${0:A:h}
REPO_ROOT=${SCRIPT_DIR:h:h}
OUTPUT_DIR=${AI_PASSPORT_OUTPUT_DIR:-"$REPO_ROOT/dist"}
APP_NAME="AI Passport.app"
APP_PATH="$OUTPUT_DIR/$APP_NAME"
ARCHIVE_PATH="$OUTPUT_DIR/AI-Passport-macOS.zip"
IDENTITY=${AI_PASSPORT_CODESIGN_IDENTITY:--}
ARCH_TEXT=${AI_PASSPORT_ARCHS:-"arm64 x86_64"}
ARCHS=(${=ARCH_TEXT})

[[ $(uname -s) == Darwin ]] || { print -u2 "macOS is required"; exit 1; }
command -v xcrun >/dev/null || { print -u2 "Xcode Command Line Tools are required"; exit 1; }
[[ ${OUTPUT_DIR:A} != / && ${OUTPUT_DIR:A} != ${HOME:A} ]] || {
  print -u2 "Refusing unsafe output directory: $OUTPUT_DIR"
  exit 2
}

BUILD_DIR=$(mktemp -d /tmp/ai-passport-app.XXXXXX)
trap 'case "$BUILD_DIR" in /tmp/ai-passport-app.*) rm -rf -- "$BUILD_DIR" ;; esac' EXIT
mkdir -p "$BUILD_DIR/$APP_NAME/Contents/MacOS" \
  "$BUILD_DIR/$APP_NAME/Contents/Resources" "$OUTPUT_DIR"

SOURCES=(
  "$SCRIPT_DIR/statusbar/mac_status_bar.swift"
  "$SCRIPT_DIR/app/BridgeProtocol.swift"
  "$SCRIPT_DIR/app/MetricProvider.swift"
  "$SCRIPT_DIR/app/NativeAudioSink.swift"
  "$SCRIPT_DIR/app/NativeBridge.swift"
)
FRAMEWORKS=(
  -framework AppKit
  -framework CoreAudio
  -framework AudioToolbox
  -framework AudioUnit
  -framework IOKit
  -framework ServiceManagement
)

BINARIES=()
for arch in $ARCHS; do
  binary="$BUILD_DIR/AI-Passport-$arch"
  xcrun swiftc -parse-as-library -O -target "$arch-apple-macos13.0" \
    $SOURCES -o "$binary" $FRAMEWORKS
  BINARIES+=("$binary")
done

if (( ${#BINARIES} == 1 )); then
  cp "$BINARIES[1]" "$BUILD_DIR/$APP_NAME/Contents/MacOS/AI Passport"
else
  xcrun lipo -create $BINARIES \
    -output "$BUILD_DIR/$APP_NAME/Contents/MacOS/AI Passport"
fi
cp "$SCRIPT_DIR/statusbar/Info.plist" "$BUILD_DIR/$APP_NAME/Contents/Info.plist"
cp "$SCRIPT_DIR/bridge/config.example.json" \
  "$BUILD_DIR/$APP_NAME/Contents/Resources/config.example.json"

xattr -cr "$BUILD_DIR/$APP_NAME"
codesign --force --options runtime --sign "$IDENTITY" "$BUILD_DIR/$APP_NAME"
codesign --verify --deep --strict "$BUILD_DIR/$APP_NAME"

if [[ -e "$APP_PATH" ]]; then
  [[ ${APP_PATH:t} == "$APP_NAME" ]] || { print -u2 "Unsafe app path"; exit 2; }
  rm -rf -- "$APP_PATH"
fi
ditto --norsrc --noextattr --noacl "$BUILD_DIR/$APP_NAME" "$APP_PATH"
rm -f -- "$ARCHIVE_PATH"
ditto -c -k --keepParent --norsrc --noextattr --noacl \
  "$APP_PATH" "$ARCHIVE_PATH"

print "Built: $APP_PATH"
print "Archive: $ARCHIVE_PATH"
if [[ $IDENTITY == - ]]; then
  print "Signing: ad hoc (public releases still require Developer ID + notarization)"
else
  print "Signing: $IDENTITY"
fi
