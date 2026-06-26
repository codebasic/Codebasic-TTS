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

APP_NAME="SelectedTextTTS"
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
    -framework AppKit

  cp "$HERE/Resources/Info.plist" "$APP_DIR/Contents/Info.plist"
  printf 'APPL????' > "$APP_DIR/Contents/PkgInfo"

  echo "==> Ad-hoc code signing"
  codesign --force --sign - "$APP_DIR" >/dev/null 2>&1 || \
    echo "    (codesign skipped/failed — fine for local runs)"

  echo "==> Built: $APP_DIR"
}

install_and_register() {
  echo "==> Installing to $INSTALL_DIR (Launch Services only scans ~/Applications and /Applications)"
  mkdir -p "$INSTALL_DIR"
  rm -rf "$INSTALL_DIR/$APP_NAME.app"
  cp -R "$APP_DIR" "$INSTALL_DIR/$APP_NAME.app"

  echo "==> Registering with Launch Services"
  "$LSREGISTER" -f "$INSTALL_DIR/$APP_NAME.app"

  echo "==> Refreshing the Services / pasteboard server"
  /System/Library/CoreServices/pbs -update >/dev/null 2>&1 || true
  /System/Library/CoreServices/pbs -flush  >/dev/null 2>&1 || true

  echo "==> Launching the installed app (registers the dynamic service)"
  open "$INSTALL_DIR/$APP_NAME.app"

  cat <<EOF

Done. To smoke-test M1:
  1. In TextEdit (or any app), select some text.
  2. Right-click → Services → "Read with SelectedTextTTS"
     (or app menu → Services). If it is missing, see README "Service not appearing".
  3. Watch the log:  ./build.sh logs
     You should see: 'Service fired: received N chars'.
  The 🔊 menu-bar icon briefly flips to 🔈 and its menu shows the last selection.
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
