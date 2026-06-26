"""Latency validation for the Qwen3-TTS local clone path.

Loads the (already-downloaded) 6bit 1.7B-Base model, then synthesizes a SHORT
sentence in streaming mode and reports the numbers that decide the local track:

  - model load time
  - time-to-first-audio-chunk   (the UX-critical "time to first sound")
  - total generation time
  - produced audio duration  ->  real-time factor (RTF)
"""
import time
import numpy as np
import soundfile as sf
from mlx_audio.tts.utils import load_model

REPO = "mlx-community/Qwen3-TTS-12Hz-1.7B-Base-6bit"
REF_AUDIO = "/Users/seongjoo/code/tts/ref_sj.wav"
REF_TEXT = open("/Users/seongjoo/code/tts/ref_text.txt").read().strip()
SHORT = "안녕하세요, 반갑습니다."        # one short sentence (the real UX unit)

print(f"[probe] loading {REPO} ...", flush=True)
t0 = time.time()
model = load_model(REPO)
load_s = time.time() - t0
print(f"[probe] model loaded in {load_s:.1f}s", flush=True)

def run(label, **kw):
    t0 = time.time()
    t_first = None
    chunks = []
    for r in model.generate(text=SHORT, ref_audio=REF_AUDIO, ref_text=REF_TEXT,
                            verbose=False, **kw):
        if t_first is None:
            t_first = time.time() - t0
        chunks.append(np.array(r.audio).reshape(-1))
    total = time.time() - t0
    audio = np.concatenate(chunks).astype(np.float32)
    sr = int(getattr(model, "sample_rate", 0) or 24000)
    dur = len(audio) / sr
    print(f"[probe] {label}: first_sound={t_first:.2f}s  total={total:.2f}s  "
          f"audio={dur:.2f}s  RTF={total/dur:.2f}x  (text='{SHORT}')", flush=True)
    return audio, sr

# Cold (first call includes any lazy graph build), then warm, then streaming.
a, sr = run("non-stream #1 (cold)")
run("non-stream #2 (warm)")
run("stream(interval=0.5)", stream=True, streaming_interval=0.5)

sf.write("/tmp/qwen_clone_test.wav", a, sr)
print("[probe] wrote /tmp/qwen_clone_test.wav", flush=True)
