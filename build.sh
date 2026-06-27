#!/usr/bin/env bash
#
# Build / install / register SelectedTextTTS without Xcode (Command Line Tools only).
#
# Usage:
#   ./build.sh           Build the .app, install to ~/Applications, register Services.
#   ./build.sh dev       Build, then run the binary directly in the foreground so
#                        stdout/stderr (and os_log) are visible in THIS terminal.
#   ./build.sh build     Build the .app into ./build only (no install, no register).
#   ./build.sh logs      Tail this app's unified logs.
#   ./build.sh clean     Remove ./build.
#
set -euo pipefail

APP_NAME="Codebasic TTS"
OLD_APP_NAME="SelectedTextTTS"      # previous bundle name, cleaned up on install
BUNDLE_ID="com.seongjoo.SelectedTextTTS"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BUILD_DIR="$HERE/build"
APP_DIR="$BUILD_DIR/$APP_NAME.app"
MACOS_DIR="$APP_DIR/Contents/MacOS"
RES_DIR="$APP_DIR/Contents/Resources"
INSTALL_DIR="$HOME/Applications"
LSREGISTER="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"

build() {
  echo "==> Compiling Swift sources"
  rm -rf "$APP_DIR"
  mkdir -p "$MACOS_DIR" "$RES_DIR"

  # shellcheck disable=SC2046
  swiftc -O \
    -o "$MACOS_DIR/$APP_NAME" \
    $(find "$HERE/Sources" -name '*.swift') \
    -framework AppKit -framework SwiftUI -framework AVFoundation

  cp "$HERE/Resources/Info.plist" "$APP_DIR/Contents/Info.plist"
  printf 'APPL????' > "$APP_DIR/Contents/PkgInfo"

  echo "==> Ad-hoc code signing"
  codesign --force --sign - "$APP_DIR" >/dev/null 2>&1 || \
    echo "    (codesign skipped/failed — fine for local runs)"

  echo "==> Built: $APP_DIR"
}

install_and_register() {
  echo "==> Stopping any running instance (so 'open' launches the new binary, not the old one)"
  pkill -f "$APP_NAME.app/Contents/MacOS/$APP_NAME" 2>/dev/null || true
  pkill -f "$OLD_APP_NAME.app/Contents/MacOS/$OLD_APP_NAME" 2>/dev/null || true
  sleep 1

  echo "==> Removing the old '$OLD_APP_NAME' bundle if present (renamed to '$APP_NAME')"
  if [ -d "$INSTALL_DIR/$OLD_APP_NAME.app" ]; then
    "$LSREGISTER" -u "$INSTALL_DIR/$OLD_APP_NAME.app" 2>/dev/null || true
    rm -rf "$INSTALL_DIR/$OLD_APP_NAME.app"
  fi

  echo "==> Installing to $INSTALL_DIR (Launch Services only scans ~/Applications and /Applications)"
  mkdir -p "$INSTALL_DIR"
  rm -rf "$INSTALL_DIR/$APP_NAME.app"
  cp -R "$APP_DIR" "$INSTALL_DIR/$APP_NAME.app"

  echo "==> Installing ElevenLabs key into Application Support (if present)"
  local appsup="$HOME/Library/Application Support/Codebasic TTS"
  if [ -f "$HERE/Sidecar/.eleven_key" ]; then
    mkdir -p "$appsup"
    tr -d ' \n\r' < "$HERE/Sidecar/.eleven_key" > "$appsup/eleven_key"
    chmod 600 "$appsup/eleven_key"
    echo "    eleven key -> $appsup/eleven_key"
  else
    echo "    (no Sidecar/.eleven_key — speech will be disabled)"
  fi
  if [ -f "$HERE/Sidecar/.gemini_key" ]; then
    mkdir -p "$appsup"
    tr -d ' \n\r' < "$HERE/Sidecar/.gemini_key" > "$appsup/gemini_key"
    chmod 600 "$appsup/gemini_key"
    echo "    gemini key -> $appsup/gemini_key"
  fi

  echo "==> Registering with Launch Services"
  "$LSREGISTER" -f "$INSTALL_DIR/$APP_NAME.app"

  echo "==> Refreshing the Services / pasteboard server"
  /System/Library/CoreServices/pbs -update >/dev/null 2>&1 || true
  /System/Library/CoreServices/pbs -flush  >/dev/null 2>&1 || true

  echo "==> Launching the installed app (registers the dynamic service)"
  open "$INSTALL_DIR/$APP_NAME.app"

  cat <<EOF

Done. Regular Dock app — the management window opens on launch; closing it keeps
the app running in the background. Click the Dock icon to reopen.
To smoke-test the Services path:
  1. In TextEdit (or any app), select some text.
  2. Right-click → Services → "Codebasic TTS".
  3. It speaks via ElevenLabs; a floating HUD shows pause/stop (focus stays on
     the source window). Watch logs: ./build.sh logs
EOF
}

case "${1:-install}" in
  build) build ;;
  dev)
    build
    echo "==> Running in foreground (Ctrl-C to stop). os_log mirrors to stderr here."
    exec "$MACOS_DIR/$APP_NAME"
    ;;
  logs)
    exec log stream --predicate "subsystem == \"$BUNDLE_ID\"" --level debug
    ;;
  clean) rm -rf "$BUILD_DIR"; echo "cleaned" ;;
  install|"") build; install_and_register ;;
  *) echo "unknown command: $1"; exit 2 ;;
esac
