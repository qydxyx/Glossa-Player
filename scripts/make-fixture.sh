#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="$ROOT/fixtures/hello.mp4"
say -o /tmp/glossa-hello.aiff "Hello. This is Glossa, a language learning player for the Mac. Real time subtitles start from here."
ffmpeg -y -f lavfi -i color=c=black:s=1280x720:d=8 -i /tmp/glossa-hello.aiff \
  -c:v h264 -pix_fmt yuv420p -c:a aac -shortest "$OUT"
echo "wrote $OUT"
