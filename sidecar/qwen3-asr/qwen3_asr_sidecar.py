#!/usr/bin/env python3
"""Glossa Qwen3-ASR sidecar. Protocol: qwen3-asr-mlx-jsonl-v1 (JSONL stdin/stdout)."""

from __future__ import annotations

import json
import os
import sys
import traceback

PROTOCOL = "qwen3-asr-mlx-jsonl-v1"

LANG = {
    "en": "English",
    "zh": "Chinese",
    "ja": "Japanese",
    "ko": "Korean",
    "fr": "French",
    "de": "German",
    "es": "Spanish",
    "auto": None,
    "": None,
}


def emit(obj: dict) -> None:
    sys.stdout.write(json.dumps(obj, ensure_ascii=False) + "\n")
    sys.stdout.flush()


def result_text(result) -> tuple[str, str | None]:
    """Never stringify the result object. Empty .text must stay empty."""
    if result is None:
        return "", None
    if isinstance(result, str):
        if result.startswith("TranscriptionResult(") or result.startswith("TranscriptResult"):
            return "", None
        return result, None
    text = getattr(result, "text", None)
    if text is None:
        text = ""
    elif not isinstance(text, str):
        text = str(text)
    lang = getattr(result, "language", None)
    if isinstance(lang, str) and lang:
        return text, lang
    return text, None


def map_lang(code: str | None) -> str | None:
    if not code:
        return None
    if code in LANG:
        return LANG[code]
    return code


def load_backend(model_id: str):
    try:
        from qwen3_asr_mlx import Qwen3ASR  # type: ignore

        emit({"type": "status", "message": f"loading qwen3_asr_mlx {model_id}"})
        model = Qwen3ASR.from_pretrained(model_id)

        def transcribe(path: str, language: str | None):
            kwargs = {}
            if language:
                kwargs["language"] = language
            result = model.transcribe(path, **kwargs)
            return result_text(result)

        return transcribe
    except ImportError:
        pass

    try:
        from mlx_qwen3_asr import Session  # type: ignore

        emit({"type": "status", "message": f"loading mlx_qwen3_asr {model_id}"})
        session = Session(model=model_id)

        def transcribe(path: str, language: str | None):
            result = session.transcribe(path)
            return result_text(result)

        return transcribe
    except ImportError:
        pass

    try:
        from mlx_audio.stt import load  # type: ignore

        emit({"type": "status", "message": f"loading mlx_audio {model_id}"})
        model = load(model_id)

        def transcribe(path: str, language: str | None):
            if language:
                result = model.generate(path, language=language)
            else:
                result = model.generate(path)
            if isinstance(result, list):
                result = result[0]
            return result_text(result)

        return transcribe
    except ImportError:
        pass

    emit(
        {
            "type": "error",
            "message": (
                "Qwen3-ASR sidecar needs a Python MLX package. Install one of:\n"
                "  pip install qwen3-asr-mlx\n"
                "  pip install mlx-audio"
            ),
        }
    )
    sys.exit(2)


def default_model() -> str:
    return os.environ.get("GLOSSA_QWEN3_MODEL", "mlx-community/Qwen3-ASR-0.6B-bf16")


def main() -> int:
    if hasattr(sys.stdout, "reconfigure"):
        sys.stdout.reconfigure(line_buffering=True)

    transcribe = None
    default_language = None

    emit({"type": "hello", "protocol": PROTOCOL})

    for raw in sys.stdin:
        line = raw.strip()
        if not line:
            continue
        try:
            msg = json.loads(line)
        except json.JSONDecodeError as e:
            emit({"type": "error", "message": f"bad json: {e}"})
            continue

        kind = msg.get("type")
        if kind == "start":
            model_id = msg.get("model") or default_model()
            aliases = {
                "0.6b": "mlx-community/Qwen3-ASR-0.6B-bf16",
                "0.6B": "mlx-community/Qwen3-ASR-0.6B-bf16",
                "qwen3-asr-0.6b": "mlx-community/Qwen3-ASR-0.6B-bf16",
                "1.7b": "mlx-community/Qwen3-ASR-1.7B-bf16",
                "1.7B": "mlx-community/Qwen3-ASR-1.7B-bf16",
                "qwen3-asr-1.7b": "mlx-community/Qwen3-ASR-1.7B-bf16",
            }
            model_id = aliases.get(model_id, model_id)
            default_language = map_lang(msg.get("language"))
            try:
                transcribe = load_backend(model_id)
                emit({"type": "ready", "protocol": PROTOCOL, "model": model_id})
            except SystemExit:
                return 2
            except Exception as e:
                emit({"type": "error", "message": f"load failed: {e}"})
                traceback.print_exc(file=sys.stderr)
                return 1
        elif kind == "transcribe":
            if transcribe is None:
                emit({"type": "error", "id": msg.get("id"), "message": "call start first"})
                continue
            path = msg.get("path") or msg.get("audio")
            if not path or not os.path.isfile(path):
                emit({"type": "error", "id": msg.get("id"), "message": f"audio not found: {path}"})
                continue
            language = map_lang(msg.get("language")) or default_language
            try:
                text, lang = transcribe(path, language)
                text = (text or "").strip()
                pts = int(msg.get("pts_ms") or 0)
                emit(
                    {
                        "type": "result",
                        "id": msg.get("id"),
                        "text": text,
                        "language": lang,
                        "start_ms": pts,
                        "end_ms": pts + int(msg.get("duration_ms") or 800),
                    }
                )
            except Exception as e:
                traceback.print_exc(file=sys.stderr)
                emit({"type": "error", "id": msg.get("id"), "message": str(e)})
        elif kind == "stop":
            emit({"type": "bye"})
            return 0
        else:
            emit({"type": "error", "message": f"unknown type: {kind}"})
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
