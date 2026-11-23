#!/usr/bin/env bash
#
# Build / install / register SelectedTextTTS without Xcode (Command Line Tools only).
#
# Usage:
#   ./build.sh           Build the .app, install to ~/Applications, register Services.
#   ./build.sh dev       Build, then run the binary directly in the foreground so
#                        stdout/stderr (and os_log) are visible in THIS terminal.
#   ./build.sh build     Build the .app into ./build only (no install, no register).
#   ./build.sh preview   Build the isolated Agent preview (no install or launch).
#   ./build.sh review    Build the whole app as a separate "Review" bundle with its own
#                        data folder, to try a change beside the installed app
#                        (no install or launch; no Services or global hotkeys).
#   ./build.sh logs      Tail this app's unified logs.
#   ./build.sh clean     Remove ./build.
#
set -euo pipefail

APP_NAME="Codebasic TTS"
OLD_APP_NAME="SelectedTextTTS"      # previous bundle name, cleaned up on install
BUNDLE_ID="com.seongjoo.SelectedTextTTS"
MIN_OS="14.0"                     # product and preview share one deployment target
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BUILD_DIR="${TTS_BUILD_DIR:-$HERE/build}"
APP_DIR="$BUILD_DIR/$APP_NAME.app"
INSTALL_DIR="$HOME/Applications"
LSREGISTER="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"
RUNTIME_SOURCE="$HERE/Sources/Core/TTSRuntime.swift"

# The macOS 27 SDK expands SwiftUI's @State through a compiler plugin that ships with
# Xcode, not with the Command Line Tools. Without Xcode, build against the newest
# installed SDK that does not need it. An explicit SDKROOT always wins.
if [ -z "${SDKROOT:-}" ] && [ ! -d "$(xcode-select -p 2>/dev/null)/Platforms" ]; then
  for candidate in macosx26.5 macosx26; do
    if sdk_path="$(xcrun --sdk "$candidate" --show-sdk-path 2>/dev/null)"; then
      export SDKROOT="$sdk_path"
      break
    fi
  done
fi

build() {
  local variant="${1:-product}"
  local app_name="$APP_NAME"
  local bundle_id="$BUNDLE_ID"
  local app_dir="$APP_DIR"
  local -a swift_flags=(-O -target "$(uname -m)-apple-macos$MIN_OS")
  if [ "$variant" = preview ]; then
    app_name="$APP_NAME Preview"
    bundle_id="$BUNDLE_ID.preview"
    app_dir="$BUILD_DIR/preview/$app_name.app"
    swift_flags+=(-D TTS_LOCAL_PREVIEW -module-cache-path "$BUILD_DIR/preview/module-cache")
  elif [ "$variant" = review ]; then
    app_name="$APP_NAME Review"
    bundle_id="$BUNDLE_ID.review"
    app_dir="$BUILD_DIR/review/$app_name.app"
    swift_flags+=(-D TTS_LOCAL_REVIEW -module-cache-path "$BUILD_DIR/review/module-cache")
  fi
  local macos_dir="$app_dir/Contents/MacOS"
  local res_dir="$app_dir/Contents/Resources"
  local plist="$app_dir/Contents/Info.plist"
  local helper="$app_dir/Contents/Helpers/CodebasicAgentMCP"
  local helper_id="$bundle_id.agent-helper"

  echo "==> Compiling Swift sources"
  rm -rf "$app_dir"
  mkdir -p "$macos_dir" "$res_dir" "$app_dir/Contents/Helpers"

  # shellcheck disable=SC2046
  swiftc "${swift_flags[@]}" \
    -o "$macos_dir/$app_name" \
    $(find "$HERE/Sources" -name '*.swift') \
    -framework AppKit -framework SwiftUI -framework AVFoundation \
    -framework Carbon -framework ApplicationServices \
    -lsqlite3

  swiftc "${swift_flags[@]}" -framework Security "$RUNTIME_SOURCE" "$HERE/Sources/App/AgentPeerSigning.swift" "$HERE/Sources/Core/AgentCatalog.swift" \
    "$HERE/Helpers/AgentCatalogMCP.swift" -o "$helper"

  cp "$HERE/Resources/Info.plist" "$plist"
  /usr/libexec/PlistBuddy -c "Set :LSMinimumSystemVersion $MIN_OS" "$plist"
  if [ "$variant" != product ]; then
    local key
    for key in CFBundleName CFBundleDisplayName CFBundleExecutable; do
      /usr/libexec/PlistBuddy -c "Set :$key $app_name" "$plist"
    done
    /usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier $bundle_id" "$plist"
    /usr/libexec/PlistBuddy -c 'Delete :NSServices' "$plist"
  fi
  [ -f "$HERE/Resources/AppIcon.icns" ] && cp "$HERE/Resources/AppIcon.icns" "$res_dir/AppIcon.icns"
  printf 'APPL????' > "$app_dir/Contents/PkgInfo"

  # Prefer a STABLE self-signed identity so TCC grants (Accessibility, needed for
  # the global hotkeys) survive rebuilds. Ad-hoc signing rebinds the designated
  # requirement to the cdhash every build, which silently invalidates the grant.
  # Create the cert once (see README "Stable signing"); falls back to ad-hoc.
  # Note: no -v — a self-signed local cert is untrusted (CSSMERR_TP_NOT_TRUSTED),
  # so it's excluded by -v, but codesign still signs with it and the resulting
  # designated requirement (cert-leaf hash) is stable across rebuilds, which is
  # all TCC needs.
  SIGN_ID="${CODESIGN_IDENTITY:-Codebasic TTS Local}"
  if security find-identity -p codesigning 2>/dev/null | grep -qF "$SIGN_ID"; then
    echo "==> Code signing with stable identity: $SIGN_ID"
    codesign --force --options runtime --timestamp=none --sign "$SIGN_ID" --identifier "$helper_id" "$helper"
    codesign --force --options runtime --timestamp=none --sign "$SIGN_ID" "$app_dir"
  else
    if [ "$variant" != product ] || [ "${TTS_REQUIRE_STABLE_SIGNING:-0}" = 1 ] || [ -n "${CODESIGN_IDENTITY:-}" ]; then
      echo "Required stable code signing identity not found." >&2
      return 1
    fi
    echo "==> Ad-hoc code signing  (no '$SIGN_ID' identity → Accessibility grant resets each rebuild)"
    codesign --force --options runtime --sign - --identifier "$helper_id" "$helper"
    codesign --force --options runtime --sign - "$app_dir"
  fi

  codesign --verify --strict "$helper"
  codesign --verify --strict --deep "$app_dir"
  for product in "$app_dir" "$helper"; do
    signature="$(codesign --display --verbose=4 "$product" 2>&1)"
    entitlements="$(codesign --display --entitlements - "$product" 2>/dev/null)"
    if ! grep -Eq 'flags=0x[0-9a-f]+\((adhoc,)?runtime\)' <<< "$signature" || [ -n "$entitlements" ]; then
      echo "Expected hardened runtime without entitlements: $product" >&2
      return 1
    fi
  done

  echo "==> Built: $app_dir"
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
  # Stage and verify the new bundle first; the previous one is only removed after
  # the swap succeeds, and is put back if the swap fails.
  local target="$INSTALL_DIR/$APP_NAME.app"
  local staged="$INSTALL_DIR/.$APP_NAME.app.staged"
  local previous="$INSTALL_DIR/.$APP_NAME.app.previous"
  rm -rf "$staged" "$previous"
  if ! cp -R "$APP_DIR" "$staged" || ! codesign --verify --strict --deep "$staged"; then
    rm -rf "$staged"
    echo "Install aborted: the new bundle could not be staged. The installed app was left untouched." >&2
    return 1
  fi
  [ -d "$target" ] && mv "$target" "$previous"
  if ! mv "$staged" "$target"; then
    [ -d "$previous" ] && mv "$previous" "$target"
    rm -rf "$staged"
    echo "Install aborted: the swap failed. The previous app was restored." >&2
    return 1
  fi
  rm -rf "$previous"

  echo "==> API keys are managed in-app (Settings → 음성 합성 / 텍스트 생성); none are"
  echo "    provisioned from the repo. Keys live in Application Support, entered via the UI."

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
  preview) build preview ;;
  review) build review ;;
  dev)
    build
    echo "==> Running in foreground (Ctrl-C to stop). os_log mirrors to stderr here."
    exec "$APP_DIR/Contents/MacOS/$APP_NAME"
    ;;
  logs)
    exec log stream --predicate "subsystem == \"$BUNDLE_ID\"" --level debug
    ;;
  test)
    echo "==> Compiling + running unit tests"
    mkdir -p "$BUILD_DIR"
    /usr/bin/python3 -B -m unittest discover -s "$HERE/Tests" -p 'test_mcp*.py' -v
    swiftc -O "$RUNTIME_SOURCE" "$HERE/Sources/Core/TextSplitter.swift" "$HERE/Sources/App/LocalSpeechSocket.swift" \
      "$HERE/Tests/LocalSpeechGateTests.swift" -o "$BUILD_DIR/local-speech-gate-tests"
    "$BUILD_DIR/local-speech-gate-tests"
    catalog_fixture="$(mktemp -d "$BUILD_DIR/catalog-test.XXXXXX")"
    swiftc -O "$HERE/Sources/Core/AgentCatalog.swift" "$HERE/Sources/Core/AgentDeliveryProofs.swift" \
      "$HERE/Sources/Core/AgentTrustStore.swift" \
      "$HERE/Sources/Core/ExplanationDraftWorkspace.swift" "$HERE/Tests/AgentCatalogTests.swift" -o "$BUILD_DIR/agent-catalog-tests"
    "$BUILD_DIR/agent-catalog-tests" "$catalog_fixture"
    swiftc -O "$RUNTIME_SOURCE" "$HERE/Sources/Core/AgentMCPConfiguration.swift" "$HERE/Tests/AgentMCPConfigurationTests.swift" \
      -o "$BUILD_DIR/agent-mcp-configuration-tests"
    "$BUILD_DIR/agent-mcp-configuration-tests" > "$BUILD_DIR/agent-mcp-configuration-sample.json"
    editing_fixture="$(mktemp -d "$BUILD_DIR/instruction-editing-test.XXXXXX")"
    swiftc -O "$HERE/Sources/Core/AgentCatalog.swift" "$HERE/Sources/Core/AgentInstructionEditing.swift" \
      "$HERE/Tests/AgentInstructionEditingTests.swift" -o "$BUILD_DIR/agent-instruction-editing-tests"
    "$BUILD_DIR/agent-instruction-editing-tests" "$editing_fixture"
    socket_fixture="$(mktemp -d "$BUILD_DIR/socket-test.XXXXXX")"
    swiftc -O "$RUNTIME_SOURCE" "$HERE/Sources/App/LocalInstructionSocket.swift" \
      "$HERE/Tests/LocalApprovedSocketLifecycleTests.swift" -o "$BUILD_DIR/local-approved-socket-tests"
    "$BUILD_DIR/local-approved-socket-tests" "$socket_fixture"
    mkdir -p "$BUILD_DIR"
    swiftc -O "$HERE/Sources/Core/TextSplitter.swift" "$HERE/Sources/Core/CrawlLayout.swift" \
      "$HERE/Sources/App/Endpoints.swift" "$HERE/Tests/main.swift" -o "$BUILD_DIR/tests"
    "$BUILD_DIR/tests"
    swiftc -O "$HERE/Sources/Core/ElevenModelCatalog.swift" "$HERE/Tests/ElevenModelCatalogTests.swift" \
      -o "$BUILD_DIR/model-tests"
    "$BUILD_DIR/model-tests"
    swiftc -O "$RUNTIME_SOURCE" "$HERE/Sources/Core/Logging.swift" "$HERE/Sources/Core/MemoryDiagnostics.swift" \
      "$HERE/Tests/MemoryDiagnosticsTests.swift" -o "$BUILD_DIR/memory-tests"
    "$BUILD_DIR/memory-tests"
    swiftc -O "$RUNTIME_SOURCE" "$HERE/Sources/App/CodexPlan.swift" "$HERE/Sources/App/AntigravityPlan.swift" "$HERE/Sources/App/Secrets.swift" \
      "$HERE/Sources/TTS/TextNormalizer.swift" "$HERE/Sources/Core/ExplanationConversation.swift" "$HERE/Sources/Core/Logging.swift" "$HERE/Sources/Core/MemoryDiagnostics.swift" "$HERE/Tests/ConnectionTests.swift" \
      -framework AppKit -o "$BUILD_DIR/connection-tests"
    "$BUILD_DIR/connection-tests" "$HERE/Tests/Fixtures/fake-codex.py"
    swiftc -O "$HERE/Sources/Core/ExplanationConversation.swift" "$HERE/Tests/ExplanationConversationTests.swift" \
      -o "$BUILD_DIR/conversation-tests"
    "$BUILD_DIR/conversation-tests"
    swiftc -O "$RUNTIME_SOURCE" "$HERE/Sources/App/CodexPlan.swift" "$HERE/Sources/App/AntigravityPlan.swift" "$HERE/Sources/App/Secrets.swift" \
      "$HERE/Sources/App/Endpoints.swift" "$HERE/Sources/TTS/TextNormalizer.swift" "$HERE/Sources/TTS/EndpointGenerator.swift" \
      "$HERE/Sources/Core/ExplanationConversation.swift" "$HERE/Sources/Core/NormalizationCache.swift" \
      "$HERE/Sources/Core/Logging.swift" "$HERE/Sources/Core/MemoryDiagnostics.swift" "$HERE/Tests/ExplanationStyleTests.swift" \
      -framework AppKit -o "$BUILD_DIR/explanation-style-tests"
    "$BUILD_DIR/explanation-style-tests"
    ;;
  clean) rm -rf "$BUILD_DIR"; echo "cleaned" ;;
  install|"") build; install_and_register ;;
  *) echo "unknown command: $1"; exit 2 ;;
esac
