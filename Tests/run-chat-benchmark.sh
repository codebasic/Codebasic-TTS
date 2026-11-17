#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
ROOT="${1:-$(mktemp -d /tmp/codebasic-v2-benchmark.XXXXXX)}"
case "$ROOT" in /tmp/*) ;; *) echo 'Use a dedicated /tmp directory'; exit 2;; esac
mkdir -p "$ROOT" build
python3 - "$ROOT/image.png" <<'PY'
import sys,random,struct,zlib
from pathlib import Path
w,h=768,448
rng=random.Random(20261117)
rows=b''.join(b'\0'+rng.randbytes(w*3) for _ in range(h))
def chunk(t,d): return struct.pack('>I',len(d))+t+d+struct.pack('>I',zlib.crc32(t+d)&0xffffffff)
Path(sys.argv[1]).write_bytes(b'\x89PNG\r\n\x1a\n'+chunk(b'IHDR',struct.pack('>IIBBBBB',w,h,8,2,0,0,0))+chunk(b'IDAT',zlib.compress(rows))+chunk(b'IEND',b''))
PY
swiftc -O Sources/Core/ExplanationConversation.swift Sources/Core/ChatSession.swift Sources/Core/TextSplitter.swift Tests/ChatBenchmark.swift -framework Combine -o build/chat-benchmark
# Old implementation is extracted read-only for before/after comparison.
git show 0bfb8f4:Sources/Core/ChatSession.swift > "$ROOT/BeforeChatSession.swift"
swiftc -O Sources/Core/ExplanationConversation.swift "$ROOT/BeforeChatSession.swift" Sources/Core/TextSplitter.swift Tests/ChatBenchmark.swift -framework Combine -o build/chat-benchmark-before
for scale in 50 300 1000; do
  images=80; [ "$scale" = 50 ] && images=10
  build/chat-benchmark prepare "$ROOT/data-$scale" "$scale" "$images" "$ROOT/image.png" > "$ROOT/fixture-$scale.txt"
  /usr/bin/time -l build/chat-benchmark-before run "$ROOT/data-$scale" "$scale" > "$ROOT/baseline-$scale.json" 2> "$ROOT/baseline-$scale.time"
  for run in 1 2 3; do
    /usr/bin/time -l build/chat-benchmark run "$ROOT/data-$scale" "$scale" > "$ROOT/final-$scale-$run.json" 2> "$ROOT/final-$scale-$run.time"
  done
done
printf 'Synthetic benchmark results: %s\n' "$ROOT"
