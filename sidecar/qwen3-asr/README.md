# Qwen3-ASR MLX sidecar

Local Qwen3-ASR (0.6B / 1.7B) via [`qwen3-asr-mlx`](https://github.com/gabrimatic/qwen3-asr-mlx). Runs in this process so Metal memory stays isolated from Glossa Player.

Protocol: JSONL on stdin/stdout (`qwen3-asr-mlx-jsonl-v1`).

```bash
make sidecar
```

Uses Homebrew `python3.13` (MLX does not track Python 3.15 yet). First ASR run downloads weights from Hugging Face (`mlx-community/Qwen3-ASR-0.6B-bf16`, ~1 GB).

Then in Glossa Player: Settings → ASR → Qwen3-ASR (local).
