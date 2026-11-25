#!/usr/bin/env bash
set -euo pipefail
HERE="$(cd "$(dirname "$0")/.." && pwd)"
BUILD_DIR="$HERE/build/regression"
mkdir -p "$BUILD_DIR"
    echo "==> Compiling + running unit tests"
    mkdir -p "$BUILD_DIR"
    swiftc -O "$HERE/Sources/Core/TextSplitter.swift" "$HERE/Sources/Core/CrawlLayout.swift" \
      "$HERE/Sources/App/Endpoints.swift" "$HERE/Tests/main.swift" -o "$BUILD_DIR/tests"
    "$BUILD_DIR/tests"
    swiftc -O "$HERE/Sources/Core/ElevenModelCatalog.swift" "$HERE/Tests/ElevenModelCatalogTests.swift" \
      -o "$BUILD_DIR/model-tests"
    "$BUILD_DIR/model-tests"
    swiftc -O "$HERE/Sources/Core/Logging.swift" "$HERE/Sources/Core/MemoryDiagnostics.swift" \
      "$HERE/Tests/MemoryDiagnosticsTests.swift" -o "$BUILD_DIR/memory-tests"
    "$BUILD_DIR/memory-tests"
    swiftc -O "$HERE/Sources/App/CodexPlan.swift" "$HERE/Sources/App/AntigravityPlan.swift" "$HERE/Sources/App/Secrets.swift" \
      "$HERE/Sources/TTS/TextNormalizer.swift" "$HERE/Sources/Core/ExplanationConversation.swift" "$HERE/Sources/Core/Logging.swift" "$HERE/Sources/Core/MemoryDiagnostics.swift" "$HERE/Tests/ConnectionTests.swift" \
      -framework AppKit -o "$BUILD_DIR/connection-tests"
    "$BUILD_DIR/connection-tests" "$HERE/Tests/Fixtures/fake-codex.py"
    swiftc -O "$HERE/Sources/Core/ExplanationConversation.swift" "$HERE/Tests/ExplanationConversationTests.swift" \
      -o "$BUILD_DIR/conversation-tests"
    "$BUILD_DIR/conversation-tests"
    swiftc -O "$HERE/Sources/App/CodexPlan.swift" "$HERE/Sources/App/AntigravityPlan.swift" "$HERE/Sources/App/Secrets.swift" \
      "$HERE/Sources/App/Endpoints.swift" "$HERE/Sources/TTS/TextNormalizer.swift" "$HERE/Sources/TTS/EndpointGenerator.swift" \
      "$HERE/Sources/Core/ExplanationConversation.swift" "$HERE/Sources/Core/NormalizationCache.swift" \
      "$HERE/Sources/Core/Logging.swift" "$HERE/Sources/Core/MemoryDiagnostics.swift" "$HERE/Tests/ExplanationStyleTests.swift" \
      -framework AppKit -o "$BUILD_DIR/explanation-style-tests"
    "$BUILD_DIR/explanation-style-tests"

    swiftc -O "$HERE/Sources/App/CodexPlan.swift" "$HERE/Sources/App/AntigravityPlan.swift" "$HERE/Sources/App/Secrets.swift" \
      "$HERE/Sources/App/Endpoints.swift" "$HERE/Sources/TTS/TextNormalizer.swift" "$HERE/Sources/TTS/EndpointGenerator.swift" \
      "$HERE/Sources/Core/ExplanationConversation.swift" "$HERE/Sources/Core/NormalizationCache.swift" \
      "$HERE/Sources/Core/Logging.swift" "$HERE/Sources/Core/MemoryDiagnostics.swift" "$HERE/Tests/GeminiValidationTests.swift" \
      -framework AppKit -o "$BUILD_DIR/gemini-validation-tests"
    GEMINI_ROOT="$(mktemp -d /tmp/codebasic-v2-gemini-mock.XXXXXX)"
    CODEBASIC_V2_LIVE_VALIDATION=1 CODEBASIC_V2_TEST_ROOT="$GEMINI_ROOT" "$BUILD_DIR/gemini-validation-tests"
    rm -rf "$GEMINI_ROOT"
