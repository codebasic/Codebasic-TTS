#!/usr/bin/env python3
"""Voice-clone TTS test CLI for Qwen3-TTS (local, MLX).

Two modes:

  REPL (default — load once, test many sentences fast):
      ./tts                       # or: .venv/bin/python clone.py
      > 안녕하세요, 오늘 날씨 좋네요.        -> synthesizes + plays
      > :ref ../ref_siwon.wav                 -> switch reference voice
      > :model 4bit                           -> reload at 4/5/6/8bit or bf16
      > :temp 0.7                             -> change temperature
      > :save on                              -> also keep each wav in ./out/
      > :q                                    -> quit

  One-shot:
      ./tts "읽을 문장" -o out.wav            # synth, play, save to out.wav

Timing (first-sound / total / RTF) is printed for every synthesis.
First synthesis in a fresh process pays a ~30s Metal compile (cold start);
the REPL warms up once at launch so subsequent sentences are ~1s.
"""
import argparse
import os
import subprocess
import sys
import tempfile
import time
import wave

import numpy as np
from mlx_audio.tts.utils import load_model

DEF_REPO_SHORT = "6bit"
REPO_FMT = "mlx-community/Qwen3-TTS-12Hz-1.7B-Base-{q}"
HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.abspath(os.path.join(HERE, ".."))            # SelectedTextTTS/
DEF_REF_AUDIO = "/Users/seongjoo/code/tts/ref_sj.wav"
DEF_REF_TEXT = "/Users/seongjoo/code/tts/ref_text.txt"


def repo_for(q: str) -> str:
    q = q.replace("-", "")
    if not q.endswith("bit") and q != "bf16":
        q = q + "bit"
    return REPO_FMT.format(q=q)


def read_text_file(path: str) -> str:
    with open(path) as f:
        return f.read().strip()


def to_wav(audio: np.ndarray, sr: int, path: str):
    audio = np.clip(audio.reshape(-1), -1.0, 1.0)
    pcm16 = (audio * 32767.0).astype("<i2")
    with wave.open(path, "wb") as w:
        w.setnchannels(1)
        w.setsampwidth(2)
        w.setframerate(sr)
        w.writeframes(pcm16.tobytes())


class Engine:
    def __init__(self, quant, ref_audio, ref_text, temperature, speed):
        self.quant = quant
        self.ref_audio = ref_audio
        self.ref_text_path = ref_text
        self.ref_text = read_text_file(ref_text)
        self.temperature = temperature
        self.speed = speed
        self.model = None
        self.sr = 24000
        self.load()

    def load(self):
        repo = repo_for(self.quant)
        print(f"[load] {repo} ...", flush=True)
        t0 = time.time()
        self.model = load_model(repo)
        self.sr = int(getattr(self.model, "sample_rate", 0) or 24000)
        print(f"[load] done in {time.time()-t0:.1f}s (sr={self.sr})", flush=True)

    def warmup(self):
        print("[warmup] compiling graph (one-time ~30s on cold MLX) ...", flush=True)
        t0 = time.time()
        self._gen("워밍업.", stream=True, quiet=True)
        print(f"[warmup] ready in {time.time()-t0:.1f}s", flush=True)

    def _gen(self, text, stream=True, quiet=False):
        t0 = time.time()
        t_first = None
        chunks = []
        kw = dict(stream=True, streaming_interval=0.5) if stream else {}
        for r in self.model.generate(
            text=text, ref_audio=self.ref_audio, ref_text=self.ref_text,
            temperature=self.temperature, speed=self.speed, verbose=False, **kw
        ):
            if t_first is None:
                t_first = time.time() - t0
            chunks.append(np.array(r.audio).reshape(-1))
        total = time.time() - t0
        audio = np.concatenate(chunks).astype(np.float32)
        dur = len(audio) / self.sr
        if not quiet:
            rtf = total / dur if dur else 0
            print(f"[time] first_sound={t_first:.2f}s  total={total:.2f}s  "
                  f"audio={dur:.2f}s  RTF={rtf:.2f}x", flush=True)
        return audio

    def synth(self, text, out_path=None, play=True):
        ref = os.path.basename(self.ref_audio)
        print(f"[synth] ({self.quant}, ref={ref}, temp={self.temperature}) {text!r}", flush=True)
        audio = self._gen(text, stream=True)
        path = out_path or os.path.join(tempfile.gettempdir(), "clone_repl.wav")
        to_wav(audio, self.sr, path)
        if out_path:
            print(f"[saved] {path}", flush=True)
        if play:
            subprocess.run(["afplay", path], check=False)
        return path


def repl(eng: Engine, save: bool):
    out_dir = os.path.join(HERE, "out")
    n = 0
    print("\nREADY. Type a sentence, or :help for commands. Ctrl-D to quit.\n", flush=True)
    while True:
        try:
            line = input("> ").strip()
        except EOFError:
            print()
            break
        if not line:
            continue
        if line in (":q", ":quit", ":exit"):
            break
        if line == ":help":
            print(":ref PATH | :model 4bit|5bit|6bit|8bit|bf16 | :temp 0.x | "
                  ":speed 1.0 | :save on|off | :q", flush=True)
            continue
        if line.startswith(":ref "):
            p = os.path.expanduser(line[5:].strip())
            if os.path.exists(p):
                eng.ref_audio = p
                print(f"[ref] -> {p}  (NOTE: ref_text still '{eng.ref_text_path}')", flush=True)
            else:
                print(f"[ref] not found: {p}", flush=True)
            continue
        if line.startswith(":model "):
            eng.quant = line[7:].strip()
            eng.load(); eng.warmup()
            continue
        if line.startswith(":temp "):
            eng.temperature = float(line[6:]); print(f"[temp] {eng.temperature}", flush=True); continue
        if line.startswith(":speed "):
            eng.speed = float(line[7:]); print(f"[speed] {eng.speed}", flush=True); continue
        if line.startswith(":save "):
            save = line[6:].strip() == "on"; print(f"[save] {save}", flush=True); continue

        out = None
        if save:
            os.makedirs(out_dir, exist_ok=True)
            n += 1
            out = os.path.join(out_dir, f"clone_{n:03d}.wav")
        eng.synth(line, out_path=out, play=True)


def main():
    ap = argparse.ArgumentParser(description="Qwen3-TTS voice-clone test CLI")
    ap.add_argument("text", nargs="?", help="text to synthesize (omit for REPL)")
    ap.add_argument("-o", "--out", help="output wav path (one-shot mode)")
    ap.add_argument("-m", "--model", default=DEF_REPO_SHORT,
                    help="quant: 4bit|5bit|6bit|8bit|bf16 (default 6bit)")
    ap.add_argument("--ref-audio", default=DEF_REF_AUDIO)
    ap.add_argument("--ref-text", default=DEF_REF_TEXT)
    ap.add_argument("--temp", type=float, default=0.9)
    ap.add_argument("--speed", type=float, default=1.0)
    ap.add_argument("--no-play", action="store_true", help="don't auto-play")
    ap.add_argument("--save", action="store_true", help="REPL: keep each wav in ./out/")
    args = ap.parse_args()

    eng = Engine(args.model, args.ref_audio, args.ref_text, args.temp, args.speed)

    if args.text:  # one-shot
        eng.warmup()  # so the single run isn't the 30s cold path
        eng.synth(args.text, out_path=args.out, play=not args.no_play)
    else:          # REPL
        eng.warmup()
        repl(eng, save=args.save)


if __name__ == "__main__":
    main()
