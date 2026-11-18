#!/usr/bin/env bash
#
# bench-h264.sh - compare default VAAPI decode vs zero-copy (surface-retained)
# decode. Read-only; no sudo. With --with-memlog, intercepts >1 MiB
# memset/memmove to show the driver's per-frame buffer churn.

set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WITH_MEMLOG=0
if [ "${1:-}" = "--with-memlog" ]; then
    WITH_MEMLOG=1
    shift
fi
CLIP="${1:?usage: bench-h264.sh [--with-memlog] /path/to/clip.mp4}"
[ -f "$CLIP" ] || { echo "not found: $CLIP" >&2; exit 1; }

DEV=/dev/dri/renderD128
[ -e "$DEV" ] || { echo "missing $DEV" >&2; exit 1; }

if [ "$WITH_MEMLOG" -eq 1 ]; then
    if [ ! -f "$ROOT/tools/memlog.so" ]; then
        gcc -shared -fPIC -o "$ROOT/tools/memlog.so" "$ROOT/tools/memlog.c" -ldl
    fi
fi

run() {
    label="$1"; shift
    log="$(mktemp)"
    if [ "$WITH_MEMLOG" -eq 1 ]; then
        env LD_PRELOAD="$ROOT/tools/memlog.so" ffmpeg -hide_banner -benchmark \
            -hwaccel vaapi -hwaccel_device "$DEV" -vaapi_device "$DEV" \
            "$@" -i "$CLIP" -an -f null - >"$log" 2>&1 || true
    else
        ffmpeg -hide_banner -benchmark \
            -hwaccel vaapi -hwaccel_device "$DEV" -vaapi_device "$DEV" \
            "$@" -i "$CLIP" -an -f null - >"$log" 2>&1 || true
    fi
    echo "--- $label ---"
    grep -E 'frame=.*Lsize|bench: utime|bench: rtime' "$log" | tail -3 | sed 's/^/  /'
    if [ "$WITH_MEMLOG" -eq 1 ]; then
        printf '  12.4MB memset count: '
        grep -c '\[MEMSET\] 12451840' "$log" || true
    fi
    rm -f "$log"
}

echo "clip: $CLIP"
ffprobe -v error -select_streams v:0 \
    -show_entries stream=codec_name,width,height,r_frame_rate,nb_frames \
    -of default=nw=1 "$CLIP" | sed 's/^/  /'
echo

run "default output format (download path)" -loglevel info
run "explicit -hwaccel_output_format vaapi" -loglevel info -hwaccel_output_format vaapi

echo
echo "Expected: explicit vaapi shows higher fps, lower utime, 0 large memsets."
