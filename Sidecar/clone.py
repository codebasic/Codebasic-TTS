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
import re
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


def normalize(audio: np.ndarray, target_rms_db: float = -20.0,
              peak_limit: float = 0.97) -> np.ndarray:
    """Loudness-normalize quiet model output: scale to a target RMS, then cap
    the peak so it can't clip. Near-silence is left untouched."""
    audio = audio.reshape(-1).astype(np.float32)
    if audio.size == 0:
        return audio
    rms = float(np.sqrt(np.mean(audio ** 2)))
    if rms < 1e-6:                                   # silence: don't amplify noise
        return audio
    audio = audio * (10.0 ** (target_rms_db / 20.0) / rms)
    peak = float(np.max(np.abs(audio)))
    if peak > peak_limit:
        audio = audio * (peak_limit / peak)
    return audio


def pad_tail(audio: np.ndarray, sr: int, pad_ms: float = 250.0,
             fade_ms: float = 12.0) -> np.ndarray:
    """The model leaves almost no silence after the last phoneme (~10-70ms), so
    endings feel abruptly cut. Apply a short fade-out (click safety) then append
    breathing-room silence."""
    audio = audio.reshape(-1).astype(np.float32).copy()
    n_fade = int(sr * fade_ms / 1000)
    if 0 < n_fade < audio.size:
        audio[-n_fade:] *= np.linspace(1.0, 0.0, n_fade, dtype=np.float32)
    n_pad = int(sr * pad_ms / 1000)
    if n_pad > 0:
        audio = np.concatenate([audio, np.zeros(n_pad, dtype=np.float32)])
    return audio


def split_sentences(text: str):
    """Split into sentences. The model emits an early EOS on long multi-sentence
    input (it can stop mid-paragraph), so we synthesize one sentence at a time.
    Splits after sentence-ending punctuation; falls back to the whole text."""
    text = text.strip()
    if not text:
        return []
    parts = re.split(r"(?<=[.!?。！？…])\s+", text)
    return [p.strip() for p in parts if p.strip()] or [text]


def to_wav(audio: np.ndarray, sr: int, path: str):
    audio = np.clip(audio.reshape(-1), -1.0, 1.0)
    pcm16 = (audio * 32767.0).astype("<i2")
    with wave.open(path, "wb") as w:
        w.setnchannels(1)
        w.setsampwidth(2)
        w.setframerate(sr)
        w.writeframes(pcm16.tobytes())


class Engine:
    def __init__(self, quant, ref_audio, ref_text, temperature, speed,
                 norm=True, rms_db=-20.0, tail_ms=250.0, fade_ms=25.0, end_marker="…",
                 gap_ms=180.0, trunc_ratio=2.0):
        self.quant = quant
        self.ref_audio = ref_audio
        self.ref_text_path = ref_text
        self.ref_text = read_text_file(ref_text)
        self.temperature = temperature
        self.speed = speed
        self.norm = norm
        self.rms_db = rms_db
        self.tail_ms = tail_ms
        self.fade_ms = fade_ms
        self.end_marker = end_marker  # non-vocalized marker that prevents end-cut
        self.gap_ms = gap_ms          # silence inserted between sentences (fallback)
        self.trunc_ratio = trunc_ratio  # audio/text token ratio below this = truncated
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
        self._gen("워밍업.")
        print(f"[warmup] ready in {time.time()-t0:.1f}s", flush=True)

    def _gen(self, text):
        """Synthesize `text` (non-streaming). A non-vocalized end marker ('…')
        is appended so the model doesn't clip the last syllable (it isn't read,
        so no trimming is needed). Returns (audio, generated_token_count)."""
        gen_text = text + self.end_marker
        results = list(self.model.generate(
            text=gen_text, ref_audio=self.ref_audio, ref_text=self.ref_text,
            temperature=self.temperature, speed=self.speed, verbose=False))
        audio = np.concatenate([np.array(r.audio).reshape(-1) for r in results]).astype(np.float32)
        toks = sum(int(getattr(r, "token_count", 0)) for r in results)
        return audio, toks

    def _join(self, segs):
        gap = np.zeros(int(self.sr * self.gap_ms / 1000), dtype=np.float32)
        out = []
        for i, s in enumerate(segs):
            if i and gap.size:
                out.append(gap)
            out.append(s)
        return np.concatenate(out) if out else np.zeros(0, dtype=np.float32)

    def synth(self, text, out_path=None, play=True):
        # Whole-paragraph generation keeps prosody natural across sentences.
        # The model RARELY stops early (mid-paragraph) via a stochastic EOS; we
        # detect that as a low audio/text token ratio and fall back to
        # guaranteed-complete per-sentence synthesis only then.
        text = text.strip()
        text_tokens = max(1, len(self.model.tokenizer.encode(text)))
        t0 = time.time()

        audio, toks = self._gen(text)
        ratio = toks / text_tokens
        mode = "whole"
        sents = split_sentences(text)
        if self.trunc_ratio > 0 and ratio < self.trunc_ratio and len(sents) > 1:
            print(f"[truncation guard] whole output short (ratio {ratio:.2f} "
                  f"< {self.trunc_ratio}); per-sentence fallback", flush=True)
            audio = self._join([self._gen(s)[0] for s in sents])
            mode = f"sentence×{len(sents)}"
        total = time.time() - t0

        if self.norm:
            audio = normalize(audio, target_rms_db=self.rms_db)
        if self.tail_ms > 0 or self.fade_ms > 0:
            audio = pad_tail(audio, self.sr, pad_ms=self.tail_ms, fade_ms=self.fade_ms)

        dur = len(audio) / self.sr
        rtf = total / dur if dur else 0
        print(f"[{self.quant} ref={os.path.basename(self.ref_audio)} temp={self.temperature}] "
              f"{mode} total={total:.2f}s audio={dur:.2f}s RTF={rtf:.2f}x", flush=True)

        path = out_path or os.path.join(tempfile.gettempdir(), "clone_repl.wav")
        to_wav(audio, self.sr, path)
        if out_path:
            print(f"[saved] {path}", flush=True)
        if play:
            subprocess.run(["afplay", path], check=False)
        return path


def _make_reader():
    """Return read_block(prompt)->str|None. Uses prompt_toolkit when available so
    that (a) multibyte editing (Korean backspace) is correct and (b) bracketed
    paste collects a multi-line paste into one buffer (Enter submits the whole
    thing). Falls back to input() if prompt_toolkit is missing."""
    try:
        if not sys.stdin.isatty():
            raise ImportError                  # piped/non-interactive: use plain input()
        from prompt_toolkit import PromptSession
        from prompt_toolkit.key_binding import KeyBindings

        kb = KeyBindings()

        @kb.add("escape")                       # Esc clears the current input in place
        def _(event):                           # (not eager, so arrow keys still work)
            event.current_buffer.reset()

        @kb.add("c-c")                          # Ctrl-C cancels the current line (no exit)
        def _(event):
            event.current_buffer.reset()
            event.app.exit(result="")

        session = PromptSession(key_bindings=kb)

        def read_block(prompt="> "):
            try:
                return session.prompt(prompt)     # full string, paste-safe, unicode-correct
            except EOFError:                       # Ctrl-D
                return None
            except KeyboardInterrupt:              # fallback: Ctrl-C cancels the current line
                return ""
        return read_block
    except ImportError:
        def read_block(prompt="> "):
            try:
                return input(prompt)
            except EOFError:
                return None
            except KeyboardInterrupt:
                return ""
        return read_block


read_block = _make_reader()


def repl(eng: Engine, save: bool):
    out_dir = os.path.join(HERE, "out")
    n = 0
    print("\nREADY. Type text + Enter to synthesize. Paste multi-line freely — "
          "the whole paste is one utterance.\n"
          ":help for commands · Esc/Ctrl-C clears input · Ctrl-D quits.\n", flush=True)
    while True:
        block = read_block("> ")
        if block is None:                 # Ctrl-D
            print()
            break
        # Collapse a (possibly multi-line / pasted) block into one utterance.
        lines = [s for s in (ln.strip() for ln in block.splitlines()) if s]
        if not lines:
            continue

        # Commands are recognized only as a single ':' line (so pasted text that
        # happens to start with ':' is still treated as text).
        if len(lines) == 1 and lines[0].strip().startswith(":"):
            cmd = lines[0].strip()
            if cmd in (":q", ":quit", ":exit"):
                break
            elif cmd == ":help":
                print(":ref PATH | :model 4bit|5bit|6bit|8bit|bf16 | :temp 0.x | "
                      ":speed 1.0 | :norm on|off | :rms -20 | :tail 250 | :fade 25 | "
                      ":marker '…'|off | :gap 180 | :trunc 2.0 | :save on|off | :q", flush=True)
            elif cmd.startswith(":ref "):
                p = os.path.expanduser(cmd[5:].strip())
                if os.path.exists(p):
                    eng.ref_audio = p
                    print(f"[ref] -> {p}  (NOTE: ref_text still '{eng.ref_text_path}')", flush=True)
                else:
                    print(f"[ref] not found: {p}", flush=True)
            elif cmd.startswith(":model "):
                eng.quant = cmd[7:].strip()
                eng.load(); eng.warmup()
            elif cmd.startswith(":temp "):
                eng.temperature = float(cmd[6:]); print(f"[temp] {eng.temperature}", flush=True)
            elif cmd.startswith(":speed "):
                eng.speed = float(cmd[7:]); print(f"[speed] {eng.speed}", flush=True)
            elif cmd.startswith(":save "):
                save = cmd[6:].strip() == "on"; print(f"[save] {save}", flush=True)
            elif cmd.startswith(":norm "):
                eng.norm = cmd[6:].strip() == "on"; print(f"[norm] {eng.norm}", flush=True)
            elif cmd.startswith(":rms "):
                eng.rms_db = float(cmd[5:]); print(f"[rms] target {eng.rms_db} dBFS", flush=True)
            elif cmd.startswith(":tail "):
                eng.tail_ms = float(cmd[6:]); print(f"[tail] {eng.tail_ms} ms", flush=True)
            elif cmd.startswith(":fade "):
                eng.fade_ms = float(cmd[6:]); print(f"[fade] {eng.fade_ms} ms", flush=True)
            elif cmd.startswith(":marker"):
                v = cmd[len(":marker"):].strip()
                eng.end_marker = "" if v in ("off", "''", '""') else (v or eng.end_marker)
                print(f"[marker] {eng.end_marker!r}", flush=True)
            elif cmd.startswith(":gap "):
                eng.gap_ms = float(cmd[5:]); print(f"[gap] {eng.gap_ms} ms", flush=True)
            elif cmd.startswith(":trunc "):
                eng.trunc_ratio = float(cmd[7:]); print(f"[trunc] ratio {eng.trunc_ratio}", flush=True)
            else:
                print(f"[?] unknown command: {cmd}  (try :help)", flush=True)
            continue

        # Join the block into one utterance; collapse internal blank lines.
        text = " ".join(s for s in (l.strip() for l in lines) if s)
        if not text:
            continue
        out = None
        if save:
            os.makedirs(out_dir, exist_ok=True)
            n += 1
            out = os.path.join(out_dir, f"clone_{n:03d}.wav")
        eng.synth(text, out_path=out, play=True)


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
    ap.add_argument("--no-normalize", action="store_true",
                    help="disable loudness normalization (raw model level)")
    ap.add_argument("--rms-db", type=float, default=-20.0,
                    help="target RMS loudness in dBFS (default -20; higher=louder)")
    ap.add_argument("--tail-ms", type=float, default=250.0,
                    help="trailing silence appended after speech (default 250; 0=off)")
    ap.add_argument("--fade-ms", type=float, default=25.0,
                    help="fade-out over the speech end, click safety (default 25; 0=off)")
    ap.add_argument("--end-marker", default="…",
                    help="non-vocalized marker appended so the last syllable isn't clipped "
                         "(default '…'; empty string disables). Model still clips occasionally.")
    ap.add_argument("--gap-ms", type=float, default=180.0,
                    help="silence between sentences in per-sentence fallback (default 180)")
    ap.add_argument("--trunc-ratio", type=float, default=2.0,
                    help="audio/text token ratio below which whole output is treated as "
                         "truncated, triggering per-sentence fallback (default 2.0; 0=off)")
    ap.add_argument("--save", action="store_true", help="REPL: keep each wav in ./out/")
    args = ap.parse_args()

    eng = Engine(args.model, args.ref_audio, args.ref_text, args.temp, args.speed,
                 norm=not args.no_normalize, rms_db=args.rms_db,
                 tail_ms=args.tail_ms, fade_ms=args.fade_ms, end_marker=args.end_marker,
                 gap_ms=args.gap_ms, trunc_ratio=args.trunc_ratio)

    if args.text:  # one-shot
        eng.warmup()  # so the single run isn't the 30s cold path
        eng.synth(args.text, out_path=args.out, play=not args.no_play)
    else:          # REPL
        eng.warmup()
        repl(eng, save=args.save)


if __name__ == "__main__":
    main()
