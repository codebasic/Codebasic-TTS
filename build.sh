#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"
mkdir -p build
SDK="${SWIFT_SDK_PATH:-/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk}"
if [ ! -d "$SDK" ]; then SDK="$(xcrun --show-sdk-path)"; fi
case "${1:-build}" in
 build)
  APP="build/Codebasic TTS V2.app"
  mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
  swiftc -sdk "$SDK" -target "$(uname -m)-apple-macosx14.0" -O -o "$APP/Contents/MacOS/Codebasic TTS V2" $(find Sources -name '*.swift') -framework AppKit -framework SwiftUI -framework AVFoundation -framework Carbon -framework ApplicationServices -lsqlite3
  cp Resources/Info.plist "$APP/Contents/Info.plist"
  codesign --force --sign - "$APP"
  ;;
 test)
  swiftc -O Sources/Core/ExplanationConversation.swift Sources/Core/ChatSession.swift Tests/ChatTests.swift -framework Combine -o build/chat-tests
  build/chat-tests
  bash Tests/regression.sh
  ;;
 *) echo 'V2 supports build and test only; no installation or live smoke target.'; exit 2;;
esac
