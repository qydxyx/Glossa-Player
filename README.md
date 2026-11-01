# Glossa Player

macOS language-learning video player. Play any local file, generate subtitles with live ASR, and show a second translated track.

Not a port of [LLPlayer](https://github.com/umlx5h/LLPlayer). Same job, native Mac stack.

- **Playback:** libmpv (VideoToolbox)
- **Shell:** SwiftUI
- **Engine:** Rust process (FFmpeg audio decode, ASR, translation)
- **Local ASR:** whisper.cpp (Metal), Qwen3-ASR (MLX sidecar)
- **Cloud ASR:** Alibaba Bailian (`qwen-audio-3.1-asr-flash-streaming`, `fun-asr-realtime`, `qwen3-asr-flash-realtime`), Gemini 3.5 Transcribe Live
- **Translation:** DeepL, LibreTranslate, Google, OpenAI, Ollama / LM Studio, any OpenAI-compatible endpoint

Requires **Apple Silicon** and **macOS 14+**. Version **1.0.1**.

Release builds bundle libmpv and FFmpeg. A local build still needs Homebrew `mpv`, `ffmpeg`, and `pkg-config`.

## Dev

```bash
# Homebrew: mpv, ffmpeg, pkg-config
brew install mpv ffmpeg pkg-config xcodegen

# Engine
cargo build -p glossa-engine

# App
make app
make run
```

Whisper models live in `~/Library/Application Support/Glossa/models`. Example:

```bash
mkdir -p ~/Library/Application\ Support/Glossa/models
curl -L -o ~/Library/Application\ Support/Glossa/models/ggml-tiny.en.bin \
  https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-tiny.en.bin
```

Then in the app: Open a video → Start ASR. Default translation is Google (no key). DeepL, LibreTranslate, OpenAI-compatible, Bailian, and Gemini keys go in Settings (Keychain).

### Local Qwen3-ASR (MLX)

```bash
make sidecar
# first ASR run downloads mlx-community/Qwen3-ASR-0.6B-bf16 (~1 GB)
```

Settings → ASR → Qwen3-ASR (local). Sidecar is `qwen3-asr-mlx` over JSONL.

### LibreTranslate

Self-host `libretranslate` on `http://127.0.0.1:5000`, or set the official URL plus API key in Settings.

### Keys

`[` / `]` sentence jump · `L` loop sentence · `D` Look Up · `C`/`T` toggle tracks · Space pause. Re-opening a file restores the last ASR cache for that engine.

## License

GPL-3.0-or-later. libmpv / FFmpeg are bundled or linked in ways that require GPL.
