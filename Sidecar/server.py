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
import re
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


END_MARKER = "…"    # non-vocalized marker appended so the last syllable isn't clipped
GAP_MS = 180.0      # silence inserted between sentences (per-sentence fallback)
TRUNC_RATIO = 2.0   # audio/text token ratio below which whole output is treated as truncated


def _split_sentences(text: str):
    """Synthesize one sentence at a time: long multi-sentence input makes the
    model stop early (mid-paragraph)."""
    text = text.strip()
    if not text:
        return []
    parts = re.split(r"(?<=[.!?。！？…])\s+", text)
    return [p.strip() for p in parts if p.strip()] or [text]


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

    sr = _state["sample_rate"]
    t0 = time.time()

    def gen(t):
        results = list(model.generate(
            text=t + END_MARKER, ref_audio=REF_AUDIO, ref_text=_state["ref_text"],
            temperature=req.temperature, speed=req.speed, verbose=False))
        nonlocal sr
        sr = int(getattr(results[0], "sample_rate", 0) or sr)
        a = np.concatenate([np.array(r.audio).reshape(-1) for r in results]).astype(np.float32)
        toks = sum(int(getattr(r, "token_count", 0)) for r in results)
        return a, toks

    # Whole-paragraph for natural prosody; fall back to per-sentence only if the
    # model stopped early (low audio/text token ratio).
    text_tokens = max(1, len(model.tokenizer.encode(text)))
    audio, toks = gen(text)
    ratio = toks / text_tokens
    mode = "whole"
    sents = _split_sentences(text)
    if TRUNC_RATIO > 0 and ratio < TRUNC_RATIO and len(sents) > 1:
        gap = np.zeros(int(sr * GAP_MS / 1000), dtype=np.float32)
        segs = [gen(s)[0] for s in sents]
        joined = []
        for i, s in enumerate(segs):
            if i and gap.size:
                joined.append(gap)
            joined.append(s)
        audio = np.concatenate(joined)
        mode = f"sentence×{len(sents)}"

    wav = _pcm_wav_bytes(audio, sr)
    print(f"[sidecar] tts {len(text)} chars [{mode}] -> {len(audio)/sr:.2f}s audio "
          f"in {time.time()-t0:.1f}s", flush=True)
    return Response(content=wav, media_type="audio/wav")


if __name__ == "__main__":
    import uvicorn
    uvicorn.run(app, host=HOST, port=PORT, log_level="warning")
