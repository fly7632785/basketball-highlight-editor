#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="${1:-$ROOT/dist/macos-runtime}"
PYTHON_RUNTIME="${BHE_PYTHON_RUNTIME:-}"

if [[ -z "$PYTHON_RUNTIME" || ! -x "$PYTHON_RUNTIME/bin/python3" ]]; then
  echo "BHE_PYTHON_RUNTIME must point to a portable Python runtime with bin/python3" >&2
  exit 2
fi

while IFS= read -r -d '' link; do
  target="$(readlink "$link")"
  if [[ "$target" = /* ]]; then
    echo "Python runtime contains an absolute symlink: $link -> $target" >&2
    echo "Use a relocatable Python distribution, not a developer virtualenv." >&2
    exit 2
  fi
done < <(find "$PYTHON_RUNTIME/bin" -type l -print0)

FFMPEG="${BHE_FFMPEG:-$(command -v ffmpeg || true)}"
FFPROBE="${BHE_FFPROBE:-$(command -v ffprobe || true)}"
if [[ -z "$FFMPEG" || -z "$FFPROBE" ]]; then
  echo "ffmpeg and ffprobe are required; set BHE_FFMPEG and BHE_FFPROBE if needed" >&2
  exit 2
fi
if [[ "$FFMPEG" -ef "$FFPROBE" ]] || cmp -s "$FFMPEG" "$FFPROBE"; then
  echo "ffmpeg and ffprobe resolve to the same binary; provide a real ffprobe executable" >&2
  exit 2
fi

if [[ "$(uname -s)" == "Darwin" && "${BHE_ALLOW_EXTERNAL_FFMPEG:-0}" != "1" ]]; then
  external_deps="$(otool -L "$FFMPEG" "$FFPROBE" | grep -E '/(usr/local|opt/homebrew|opt/local)/' || true)"
  if [[ -n "$external_deps" ]]; then
    echo "The selected FFmpeg depends on Homebrew/foreign dylibs and is not portable:" >&2
    echo "$external_deps" >&2
    echo "Use a self-contained/static FFmpeg build, or set BHE_ALLOW_EXTERNAL_FFMPEG=1 for local-only testing." >&2
    exit 2
  fi
fi

MODEL="${BHE_MODEL:-$ROOT/models/bball_model.pt}"
if [[ ! -f "$MODEL" ]]; then
  MODEL="$ROOT/third_party/basketball-shot-detection/bball_model.pt"
fi
if [[ ! -f "$MODEL" ]]; then
  echo "Model not found; place it at models/bball_model.pt or set BHE_MODEL" >&2
  exit 2
fi

rm -rf "$OUT"
mkdir -p "$OUT"/bin "$OUT"/python "$OUT"/engine "$OUT"/scripts "$OUT"/src "$OUT"/docs/architecture "$OUT"/models

cp -R "$PYTHON_RUNTIME"/. "$OUT/python/"
cp -R "$ROOT/engine/python" "$OUT/engine/"
cp -R "$ROOT/scripts"/. "$OUT/scripts/"
cp -R "$ROOT/src"/. "$OUT/src/"
cp "$ROOT/docs/architecture/SQLITE_SCHEMA_V1.sql" "$OUT/docs/architecture/"
cp "$MODEL" "$OUT/models/bball_model.pt"
cp "$FFMPEG" "$OUT/bin/ffmpeg"
cp "$FFPROBE" "$OUT/bin/ffprobe"

"$OUT/python/bin/python3" "$OUT/scripts/check_runtime.py" \
  --root "$OUT" \
  --python "$OUT/python/bin/python3" \
  --ffmpeg "$OUT/bin/ffmpeg" \
  --ffprobe "$OUT/bin/ffprobe" \
  --model "$OUT/models/bball_model.pt"

echo "Prepared runtime: $OUT"
