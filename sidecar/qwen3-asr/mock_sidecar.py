#!/usr/bin/env python3
"""Deterministic JSONL sidecar for tests. Speaks qwen3-asr-mlx-jsonl-v1."""

import json
import sys


def emit(obj):
    sys.stdout.write(json.dumps(obj) + "\n")
    sys.stdout.flush()


def main():
    emit({"type": "hello", "protocol": "qwen3-asr-mlx-jsonl-v1"})
    for raw in sys.stdin:
        line = raw.strip()
        if not line:
            continue
        msg = json.loads(line)
        kind = msg.get("type")
        if kind == "start":
            emit({"type": "ready", "protocol": "qwen3-asr-mlx-jsonl-v1", "model": msg.get("model")})
        elif kind == "transcribe":
            pts = int(msg.get("pts_ms") or 0)
            emit(
                {
                    "type": "result",
                    "id": msg.get("id"),
                    "text": "hello from mock",
                    "language": "en",
                    "start_ms": pts,
                    "end_ms": pts + 800,
                }
            )
        elif kind == "stop":
            emit({"type": "bye"})
            return 0
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
