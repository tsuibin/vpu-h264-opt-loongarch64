# Benchmark results and evidence

All numbers measured on 2026-11-18 on Loongson 3B6000M (loongarch64), LG200,
AOSC OS, kernel `7.1.7-aosc-main-16k`, closed VA-API driver
`loonggpu_drv_video.so` (VSI Hantro VCE V6.2 / VCD 1.1.3).

Test clips were generated with `scripts/gen-test-clips.sh` (`testsrc2`,
`libx264 -preset ultrafast`, yuv420p, 60 fps) unless noted.

## 1. The headline comparison

5 s, 3840x2160@60 H.264, 300 frames, `-f null -` output:

| Mode | fps | speed | utime | stime | rtime | 12.4 MB memset |
|---|---:|---:|---:|---:|---:|---:|
| default (no `-hwaccel_output_format`) | 46 | 0.77x | 6.182 s | 1.279 s | 6.527 s | 300 |
| `-hwaccel_output_format vaapi` | **85** | **1.42x** | **0.753 s** | 0.238 s | **3.512 s** | **0** |

Commands:

```sh
# slow path
ffmpeg -benchmark -hwaccel vaapi -hwaccel_device /dev/dri/renderD128 \
  -vaapi_device /dev/dri/renderD128 -i h264_4k60.mp4 -an -f null -

# optimized path
ffmpeg -benchmark -hwaccel vaapi -hwaccel_device /dev/dri/renderD128 \
  -vaapi_device /dev/dri/renderD128 -hwaccel_output_format vaapi \
  -i h264_4k60.mp4 -an -f null -
```

## 2. Resolution scaling (default output format)

| Clip | Frames | fps | speed | utime | rtime |
|---|---:|---:|---:|---:|---:|
| 720p60 H.264 | 300 | 565 | 9.42x | 0.685 s | 0.531 s |
| 1080p60 H.264 | 300 | 220 | 3.66x | 1.481 s | 1.366 s |
| 1440p60 H.264 | 300 | 115 | 1.92x | 2.954 s | 2.609 s |
| 4K60 H.264 (109 Mbps) | 300 | 46 | 0.77x | 6.182 s | 6.527 s |
| 4K60 H.264 (1.6 Mbps, `-crf 45`) | 180 | 48 | 0.80x | 3.907 s | 3.762 s |

Pixel throughput is nearly constant (~400–520 Mpx/s) across resolutions, and
bitrate has no effect — the limiter scales with frame size, not bitstream size.

With explicit `-hwaccel_output_format vaapi`:

| Clip | fps | speed | utime |
|---|---:|---:|---:|
| 1080p60 H.264 | 343 | 5.71x | 0.239 s |
| 4K60 H.264 | 85 | 1.42x | 0.753 s |
| 4K60 HEVC | 115 | 1.91x | 0.478 s |

## 3. Software decode baseline (4K60 H.264, 300 frames)

```
fps=76   speed=1.26x
bench: utime=21.359s stime=0.369s rtime=3.972s
```

Software is faster in wall-clock here, but consumes ~4x the total CPU time by
using multiple cores. Single-core efficiency still favors the VPU path.

## 4. Where the time goes

### LD_PRELOAD interception

`tools/memlog.c` intercepts `memset`/`memmove` larger than 1 MiB. One second
of 4K60 decode (62 frames), default output format:

```
62 x 12,451,840 B  memset
62 x 12,441,600 B  memset
20 x 13,369,344 B  memset     (startup / work buffers)
10 x 15,237,120 B  memset     (startup / work buffers)
```

With `-hwaccel_output_format vaapi`, the two per-frame 12.4 MB entries vanish.
`3840*2160*1.5 = 12,441,600`, i.e. a full NV12 frame, zeroed twice per frame.

### perf

```
Samples: 705 of event cpu/cycles/Pu
  51.89%  dec0:0:h264  libc.so.6  __GI___memmove_lsx
  27.48%  dec0:0:h264  libc.so.6  __GI___memset_lsx
   7.40%  av:h264:df0  libc.so.6  __GI___memset_lsx
```

`perf script` shows `memset` frames attributed to
`/usr/lib/dri/loonggpu_drv_video.so`, confirming the closed driver is doing
the buffer churn on the CPU.

### libva trace

With `LIBVA_TRACE=/tmp/va.trace` (1 s decode), median call durations:

```
BeginPicture    0.038 ms
RenderPicture   0.075 ms
EndPicture      0.145 ms
SyncSurface     0.037 ms
ExportSurfaceHandle 0.042 ms
```

No VA-API call is anywhere near the ~19 ms/frame budget, so submission and
synchronization are not the bottleneck.

## 5. Browser cross-reference

Decoded frames in browsers are already kept as VA-API surfaces, so the exact
memset path above is not taken — but H.264 4K60 still drops roughly half the
frames due to the compositing path, and Chromium reproducibly crashes with
`bo alloc failed: out of memory, file hantro_bufmgr.c, line 268`. HEVC 4K60 in
Firefox drops only ~8%. Full data:
`~/loongvpu-vaapi/docs/BROWSER_HW_DECODE.md` §6.1.

## 6. Reproducibility notes

- `testsrc2` generation is excluded from decode timing: clips are pre-generated
  and decoded from disk with `-an -f null -`.
- Use `-benchmark` and compare `utime` (CPU seconds), `rtime` (wall seconds)
  and the final `frame=... speed=...` line.
- The VPU driver prints `Decoder has 1 core` and `Core[0] used N cmdbuf (100%)`
  during 4K decode; no decode errors were observed in any run.
- `CmaTotal` is 262144 kB with ~150 MB free during these tests, so CMA is not
  the limiting resource.
