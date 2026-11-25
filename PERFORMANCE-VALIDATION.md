# Synthetic history performance

Measured on macOS 27.0.1 arm64, optimized swiftc build, local filesystem, 2026-11-17. This is an informal warm-filesystem measurement, not a cold-cache or controlled-system benchmark. Other Mac apps remained running. App build/unit compilation had finished before the final sequential comparison.

All data is synthetic. Seed sizes: 50/300/1000 threads, 20 messages per thread, approximately 500 text characters per message; 10/80/80 valid PNG attachments of 1,033,018 bytes each (10,330,180 / 82,641,440 / 82,641,440 bytes). Initial metadata sizes: 771,215 / 4,633,045 / 15,440,345 bytes. Each timed run appends one small benchmark thread/two messages. Exact loaded counts are in the JSON logs; this drift is small relative to seed message count.

Baseline: ChatSession extracted read-only from 0bfb8f4. Final: cached unchanged-thread metadata, one new-thread flush. Baseline is one run per scale; final entries are medians of three fresh-process runs. No filesystem cache flush was attempted.

| Seed threads/messages | Load ms before → final | New-thread flush ms before → final | Send flush ms before → final | Shutdown flush ms before → final | Main actor max tick gap ms before → final | Final loaded / end RSS MiB | Peak RSS MiB range |
|---|---|---|---|---|---|---|---|
| 50 / 1000 | 18.91 → 14.21 | 21.22 → 10.09 | 8.69 → 0.90 | 14.90 → 4.47 | 21.00 → 11.87 | 18.72 / 22.27 | 24.08–24.17 |
| 300 / 6000 | 69.53 → 63.28 | 86.83 → 42.57 | 41.19 → 2.90 | 45.41 → 9.42 | 69.94 → 14.39 | 104.09 / 119.92 | 121.44–130.59 |
| 1000 / 20000 | 158.02 → 150.06 | 288.68 → 135.83 | 137.62 → 7.91 | 146.38 → 29.15 | 149.16 → 22.26 | 142.58 / 237.64 | 237.34–240.34 |

Load includes synchronous archive decode and image file loading, measured from a fresh process with potentially warm OS cache. New-thread time includes its first full cache fill. Send and shutdown measure synchronous durability flush. The stream emits 120 synthetic chunks at 10 ms intervals, with a 1 ms MainActor ticker; the maximum observed tick gap measures scheduling stalls, not display frame rate or human-perceived latency. Resident memory uses Mach task_info; peak uses /usr/bin/time -l and includes the entire benchmark process. These are not GUI-app memory measurements.

The former repeated full JSON encoding was a measurable bottleneck. Caching unchanged thread JSON and removing the duplicate new-thread save reduced steady-state flush and main-actor scheduling gaps. The cache increases resident memory, especially for 20,000 messages. First save/initial load still scale with total history; this prototype is not a lazy-loading database.

Reproduce from the repository with `bash Tests/run-chat-benchmark.sh /tmp/codebasic-v2-benchmark-repro-UNIQUE`. It generates its own deterministic synthetic PNG and archives, compiles baseline/final harnesses, performs one baseline and three final runs per scale, and leaves JSON/time/fixture records in that dedicated /tmp root. Use a new root for each reproduction. No credentials or provider transports are compiled into this harness.

Actual GUI responsiveness on the final 300-thread dataset is recorded separately in GUI-VALIDATION.md; the ticker above is not a substitute for that observation.

After unlock, CUA qualitatively verified the 300-seed-thread GUI list through item 0299, new-thread creation, compose/attach/response, playback/stop, cancellation and settings navigation without a visible hang. This observation is separate from the quantitative MainActor ticker. The final visual restoration check was briefly interrupted by another Mac lock and was then completed independently by the parent using the explicit offline environment; see GUI-VALIDATION.md.
