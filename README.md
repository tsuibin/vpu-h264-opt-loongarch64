# vpu-h264-opt-loongarch64

[![build](https://github.com/tsuibin/vpu-h264-opt-loongarch64/actions/workflows/build.yml/badge.svg)](https://github.com/tsuibin/vpu-h264-opt-loongarch64/actions/workflows/build.yml)

H.264 hardware-decode optimization for the Loongson **LoongVPU** on
loongarch64 (3B6000M / LG200, AOSC OS). This repo documents the measured
root cause of poor H.264 VA-API throughput and the one switch that fixes it.

> Status: **documentation + reproducible benchmark scripts**. No driver
> source here. The optimization is in how the client keeps decoded frames,
> not in the VPU itself.

## 中文速览

- 症状：ffmpeg 用 `-hwaccel vaapi` 解 4K60 H.264 只有 46 fps，比软件解码还慢。
- 根因：**默认输出格式会把每帧 VAAPI surface 下载回内存**，闭源驱动每帧做
  两次约 12.4 MB 的 `memset`（4K NV12 帧大小），CPU 时间被吃光。
- 解法：显式加 `-hwaccel_output_format vaapi`，把帧留在显存里。4K60 从
  46 fps → **85 fps**（1.42x 实时），CPU 时间 6.18s → 0.75s，大块 memset 归零。
- 浏览器里 H.264 4K60 仍会掉帧（Firefox ~57%，Chromium ~51% 且 GPU 崩溃）；
  浏览器侧结论见 `loongvpu-vaapi/docs/BROWSER_HW_DECODE.md`，本项目只管解码管线。

## Root cause (measured)

With plain `-hwaccel vaapi -f null -`, ffmpeg lets the output format fall back
to a system-memory pixel format. The closed `loonggpu_drv_video.so` then, for
every decoded frame, zeroes two frame-sized buffers:

```
1 s / 62-frame 4K60 decode, LD_PRELOAD interception:
  62 x 12,451,840 B  memset
  62 x 12,441,600 B  memset
```

`3840 x 2160 x 1.5 = 12,441,600 B` is exactly one 4K NV12 frame. At ~54 fps
that is ~1.3 GB/s of memset traffic on one core.

`perf` on the same decode:

```
51.89%  __GI___memmove_lsx
27.48%  __GI___memset_lsx
 7.40%  __GI___memset_lsx   (libavcodec side)
```

libva call trace shows the VA-API calls themselves are cheap
(`BeginPicture` 0.038 ms, `RenderPicture` 0.075 ms, `EndPicture` 0.145 ms,
`SyncSurface` 0.037 ms median), so the cost is the CPU-side buffer churn in
the driver, not hardware decode or ioctl waiting.

## The fix

```sh
ffmpeg -hwaccel vaapi \
  -hwaccel_device /dev/dri/renderD128 \
  -vaapi_device /dev/dri/renderD128 \
  -hwaccel_output_format vaapi \
  -i input_4k60.mp4 -an -f null -
```

`-hwaccel_output_format vaapi` keeps frames as VA-API surfaces. Do **not**
replace it with `nv12` / `yuv420p` — those force the download path and bring
the memsets back. Note that any downstream filter requiring CPU-side frames
will force a download again (this driver also lacks `hwdownload`), so this
optimization applies to decode-only or VAAPI-render pipelines.

## Measured results

| Resolution / codec | Default output | `-hwaccel_output_format vaapi` |
|---|---|---|
| 720p60 H.264 | 565 fps (9.4x) | not separately measured |
| 1080p60 H.264 | 220 fps (3.66x) | **343 fps (5.71x)** |
| 1440p60 H.264 | 115 fps (1.92x) | not separately measured |
| 4K60 H.264 | 46 fps (0.77x), 300 x 12.4 MB memset | **85 fps (1.42x), 0 memset** |
| 4K60 H.264 low bitrate (1.6 Mbps) | 48 fps | not separately measured |
| 4K60 HEVC | 48 fps | **115 fps (1.91x)** |

Bitrate is not the limiter: dropping 4K H.264 from 109 Mbps to 1.6 Mbps
changes nothing. Full data and commands are in
[`docs/BENCHMARK_RESULTS.md`](docs/BENCHMARK_RESULTS.md).

## Reproduce

```sh
bash scripts/gen-test-clips.sh /tmp/vpu-h264-bench   # generate clips
bash scripts/bench-h264.sh /tmp/vpu-h264-bench/h264_4k60.mp4
bash scripts/bench-h264.sh --with-memlog /tmp/vpu-h264-bench/h264_4k60.mp4
```

`--with-memlog` builds `tools/memlog.c` and intercepts >1 MiB `memset`/
`memmove`, so you can see the per-frame buffer churn directly. Everything is
read-only with respect to the system; no sudo, no package changes.

## Repo layout

- `docs/BENCHMARK_RESULTS.md` — raw numbers, perf and libva trace evidence.
- `scripts/gen-test-clips.sh` — generate deterministic H.264 test clips.
- `scripts/bench-h264.sh` — default vs zero-copy VAAPI benchmark.
- `tools/memlog.c` — LD_PRELOAD interceptor for large memory operations.
- `.github/workflows/build.yml` — on push/PR: native build of `memlog.so`,
  symbol check, `bash -n` on scripts, and a LoongArch64 cross-compile check.

## Limitations

- Only the closed `loonggpu_drv_video.so` is functional here. The open
  `loongvpu-vaapi` scaffold has no VPU render node and is not a substitute.
- The fix keeps frames in VA-API surfaces; it does not make CPU-side frame
  export work (`hwdownload` still returns -38).
- Upstream Mesa 26.2.6 has no LoongGPU Gallium driver; the GL stack is the
  vendor `loonggl` (Mesa 24.0.5 fork).
- 4K60 H.264 in browsers remains poor even with this knowledge — use HEVC
  there, or cap at 1080p60. See the browser document linked above.

## References

- AOSC LoongGPU/VPU preview: https://aosc.io/news/2025-12-31-loonggpu-and-loongvpu-preview
- libva: https://github.com/intel/libva
- Companion docs: `~/loongvpu-vaapi/docs/BROWSER_HW_DECODE.md`, `~/mesa-loonggpu-loongarch64/`
