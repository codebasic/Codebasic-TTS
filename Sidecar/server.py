"""Local Qwen3-TTS sidecar for SelectedTextTTS.

A tiny HTTP server that loads a Qwen3-TTS Base model once and synthesizes
speech cloned from a reference recording. The Swift app's Qwen3MLXBackend
talks to this over 127.0.0.1.

Run:
    .venv/bin/python server.py            # defaults below
    QWEN_TTS_PORT=8765 .venv/bin/python server.py

Env:
    QWEN_TTS_REPO        mlx-community model id   (default: 6bit 1.7B-Base)
    QWEN_TTS_REF_AUDIO   reference wav for cloning
    QWEN_TTS_REF_TEXT    path to the reference transcript
    QWEN_TTS_HOST/PORT   bind address              (default 127.0.0.1:8765)

Endpoints:
    GET  /health   -> {status, model, sample_rate, ready}
    POST /tts      -> audio/wav   body: {"text": "...", "temperature"?, "speed"?}
"""
import io
import os
import time
import wave

import numpy as np
from fastapi import FastAPI, HTTPException
from fastapi.responses import JSONResponse, Response
from pydantic import BaseModel

# ---- config -----------------------------------------------------------------
REPO = os.environ.get("QWEN_TTS_REPO", "mlx-community/Qwen3-TTS-12Hz-1.7B-Base-6bit")
REF_AUDIO = os.environ.get("QWEN_TTS_REF_AUDIO", "/Users/seongjoo/code/tts/ref_sj.wav")
REF_TEXT_FILE = os.environ.get("QWEN_TTS_REF_TEXT", "/Users/seongjoo/code/tts/ref_text.txt")
HOST = os.environ.get("QWEN_TTS_HOST", "127.0.0.1")
PORT = int(os.environ.get("QWEN_TTS_PORT", "8765"))

# Identity string folded into the Swift-side cache key (must stay in sync with
# whatever distinguishes the audio this engine produces).
IDENTITY = "qwen3-1.7b-6bit"

app = FastAPI(title="SelectedTextTTS Qwen3 sidecar")

_state = {"model": None, "sample_rate": 24000, "ref_text": ""}


def _load():
    from mlx_audio.tts.utils import load_model
    t0 = time.time()
    model = load_model(REPO)
    _state["model"] = model
    _state["sample_rate"] = int(getattr(model, "sample_rate", 0) or 24000)
    with open(REF_TEXT_FILE) as f:
        _state["ref_text"] = f.read().strip()
    print(f"[sidecar] loaded {REPO} in {time.time()-t0:.1f}s "
          f"(sr={_state['sample_rate']})", flush=True)


@app.on_event("startup")
def _startup():
    _load()


class TTSRequest(BaseModel):
    text: str
    temperature: float = 0.9
    speed: float = 1.0


def _normalize(audio: np.ndarray, target_rms_db: float = -20.0, peak_limit: float = 0.97) -> np.ndarray:
    """Loudness-normalize quiet model output (RMS target + peak cap)."""
    audio = audio.reshape(-1).astype(np.float32)
    if audio.size == 0:
        return audio
    rms = float(np.sqrt(np.mean(audio ** 2)))
    if rms < 1e-6:
        return audio
    audio = audio * (10.0 ** (target_rms_db / 20.0) / rms)
    peak = float(np.max(np.abs(audio)))
    if peak > peak_limit:
        audio = audio * (peak_limit / peak)
    return audio


FILLER = " 네."   # appended then trimmed so the real ending isn't truncated by early EOS


def _trim_after_filler(audio: np.ndarray, sr: int, min_gap_ms: float = 120.0, thr_ratio: float = 0.02) -> np.ndarray:
    """Cut at the last silence gap, dropping the appended filler word + its
    leading pause and keeping the now-complete real ending."""
    a = audio.reshape(-1)
    pk = float(np.max(np.abs(a))) or 1e-9
    idx = np.where(np.abs(a) > thr_ratio * pk)[0]
    if idx.size == 0:
        return a
    big = np.where(np.diff(idx) > int(min_gap_ms * sr / 1000))[0]
    if big.size == 0:
        return a
    return a[:idx[big[-1]] + 1]


def _pad_tail(audio: np.ndarray, sr: int, pad_ms: float = 250.0, fade_ms: float = 25.0) -> np.ndarray:
    """Append breathing-room silence (with a short fade-out) so endings don't
    sound abruptly cut; the model leaves only ~10-70ms of trailing silence."""
    audio = audio.reshape(-1).astype(np.float32).copy()
    n_fade = int(sr * fade_ms / 1000)
    if 0 < n_fade < audio.size:
        audio[-n_fade:] *= np.linspace(1.0, 0.0, n_fade, dtype=np.float32)
    n_pad = int(sr * pad_ms / 1000)
    if n_pad > 0:
        audio = np.concatenate([audio, np.zeros(n_pad, dtype=np.float32)])
    return audio


def _pcm_wav_bytes(audio: np.ndarray, sr: int) -> bytes:
    """float32 [-1,1] mono -> 16-bit PCM WAV container (normalized + tail-padded)."""
    audio = np.clip(_pad_tail(_normalize(audio), sr).reshape(-1), -1.0, 1.0)
    pcm16 = (audio * 32767.0).astype("<i2")
    buf = io.BytesIO()
    with wave.open(buf, "wb") as w:
        w.setnchannels(1)
        w.setsampwidth(2)
        w.setframerate(sr)
        w.writeframes(pcm16.tobytes())
    return buf.getvalue()


@app.get("/health")
def health():
    return JSONResponse({
        "status": "ok",
        "model": REPO,
        "identity": IDENTITY,
        "sample_rate": _state["sample_rate"],
        "ready": _state["model"] is not None,
    })


@app.post("/tts")
def tts(req: TTSRequest):
    model = _state["model"]
    if model is None:
        raise HTTPException(503, "model not loaded")
    text = req.text.strip()
    if not text:
        raise HTTPException(400, "empty text")

    t0 = time.time()
    results = list(model.generate(
        text=text + FILLER,
        ref_audio=REF_AUDIO,
        ref_text=_state["ref_text"],
        temperature=req.temperature,
        speed=req.speed,
        verbose=False,
    ))
    sr = int(getattr(results[0], "sample_rate", 0) or _state["sample_rate"])
    audio = np.concatenate([np.array(r.audio).reshape(-1) for r in results]).astype(np.float32)
    audio = _trim_after_filler(audio, sr)   # drop the filler + its leading pause
    wav = _pcm_wav_bytes(audio, sr)
    print(f"[sidecar] tts {len(text)} chars -> {len(audio)/sr:.2f}s audio "
          f"in {time.time()-t0:.1f}s", flush=True)
    return Response(content=wav, media_type="audio/wav")


if __name__ == "__main__":
    import uvicorn
    uvicorn.run(app, host=HOST, port=PORT, log_level="warning")
