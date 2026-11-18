#!/usr/bin/env bash
#
# gen-test-clips.sh - generate deterministic H.264 VA-API benchmark clips.
# No sudo, no system changes. Output goes to the directory given as $1.

set -eu
OUT="${1:-/tmp/vpu-h264-bench}"
mkdir -p "$OUT"

gen() {
    name="$1"; size="$2"; secs="$3"; shift 3
    echo "generating $name ($size, ${secs}s)"
    ffmpeg -y -loglevel error \
        -f lavfi -i "testsrc2=size=${size}:rate=60" \
        -t "$secs" -c:v libx264 -preset ultrafast \
        -pix_fmt yuv420p -g 120 "$@" "$OUT/$name"
}

gen h264_720p60.mp4  1280x720  5
gen h264_1080p60.mp4 1920x1080 5
gen h264_1440p60.mp4 2560x1440 5
gen h264_4k60.mp4    3840x2160 5

# Low-bitrate control: proves bitstream size is not the bottleneck.
echo "generating h264_4k60_lowbitrate.mp4 (3840x2160, 3s, CRF 45)"
ffmpeg -y -loglevel error \
    -f lavfi -i "testsrc2=size=3840x2160:rate=60" \
    -t 3 -c:v libx264 -preset veryfast -crf 45 \
    -pix_fmt yuv420p "$OUT/h264_4k60_lowbitrate.mp4"

echo "done: $OUT"
ls -lh "$OUT"
