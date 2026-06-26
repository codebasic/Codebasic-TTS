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


def _pcm_wav_bytes(audio: np.ndarray, sr: int) -> bytes:
    """float32 [-1,1] mono -> 16-bit PCM WAV container."""
    audio = np.clip(audio.reshape(-1), -1.0, 1.0)
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
        text=text,
        ref_audio=REF_AUDIO,
        ref_text=_state["ref_text"],
        temperature=req.temperature,
        speed=req.speed,
        verbose=False,
    ))
    sr = int(getattr(results[0], "sample_rate", 0) or _state["sample_rate"])
    audio = np.concatenate([np.array(r.audio).reshape(-1) for r in results]).astype(np.float32)
    wav = _pcm_wav_bytes(audio, sr)
    print(f"[sidecar] tts {len(text)} chars -> {len(audio)/sr:.2f}s audio "
          f"in {time.time()-t0:.1f}s", flush=True)
    return Response(content=wav, media_type="audio/wav")


if __name__ == "__main__":
    import uvicorn
    uvicorn.run(app, host=HOST, port=PORT, log_level="warning")
