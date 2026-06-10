#!/usr/bin/env python3
"""Resident local-Whisper transcription helper for the Dictation app.

Spawned by WhisperLocalTranscriber.swift with a Python interpreter that has
`openai-whisper` installed. Loads the model once, then serves line-delimited
JSON requests on stdin:

    {"id": 1, "audio": "/path/to/audio.wav", "language": "en"}

and replies with one JSON line on stdout per request:

    {"id": 1, "text": "..."}      on success
    {"id": 1, "error": "..."}     on failure (the server keeps running)

Emits {"event": "ready"} once the model is loaded. Diagnostics go to stderr
(the app forwards them to dictation.log). Exits when stdin closes, i.e. when
the app quits.

The app records 16 kHz mono 16-bit PCM WAV, so audio is decoded with the
stdlib `wave` module — no ffmpeg required, unlike whisper's own loader.
"""

import argparse
import json
import sys
import wave


def log(message):
    print(message, file=sys.stderr, flush=True)


def emit(obj):
    print(json.dumps(obj, ensure_ascii=False), file=sys.stdout, flush=True)


def load_wav(path, np):
    """Decode a PCM WAV into the float32 mono 16 kHz array whisper expects."""
    with wave.open(path, "rb") as w:
        rate = w.getframerate()
        channels = w.getnchannels()
        width = w.getsampwidth()
        frames = w.readframes(w.getnframes())
    if width != 2:
        raise ValueError(f"expected 16-bit PCM WAV, got {width * 8}-bit")
    audio = np.frombuffer(frames, dtype=np.int16).astype(np.float32) / 32768.0
    if channels > 1:
        audio = audio.reshape(-1, channels).mean(axis=1)
    if rate != 16000:
        target_len = int(len(audio) * 16000 / rate)
        audio = np.interp(
            np.linspace(0.0, len(audio), target_len, endpoint=False),
            np.arange(len(audio)),
            audio,
        ).astype(np.float32)
    return audio


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--model", default="turbo")
    parser.add_argument("--model-dir", required=True)
    parser.add_argument("--device", default="cpu")
    args = parser.parse_args()

    log(f"loading whisper model '{args.model}' from {args.model_dir} on {args.device}…")
    import numpy as np
    import whisper

    model = whisper.load_model(args.model, device=args.device, download_root=args.model_dir)
    log("model loaded, serving requests")
    emit({"event": "ready"})

    for line in sys.stdin:
        line = line.strip()
        if not line:
            continue
        req_id = None
        try:
            request = json.loads(line)
            req_id = request.get("id")
            audio = load_wav(request["audio"], np)
            result = model.transcribe(
                audio,
                language=request.get("language") or None,
                fp16=(args.device != "cpu"),
            )
            emit({"id": req_id, "text": result["text"].strip()})
        except Exception as e:  # report per-request errors, keep serving
            emit({"id": req_id, "error": f"{type(e).__name__}: {e}"})

    log("stdin closed, exiting")


if __name__ == "__main__":
    main()
