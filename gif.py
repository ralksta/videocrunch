#!/usr/bin/env python3
"""Turn (part of) a video into a GIF — the app's GIF mode, the Gifski way.

ffmpeg reads the video, keeps the chosen range, drops to the frame rate,
scales and tone-maps HDR; gifski makes the GIF (its palettes and dithering
are what make Gifski's GIFs look good). Without gifski, ffmpeg's
palettegen/paletteuse stand in.

    gif.py clip.mov --ss 3 --to 7 --width 480 --fps 15 --quality 90
    gif.py clip.mov --estimate          # expected size, from a short sample
    gif.py clip.mov --events            # JSON lines, as batch.py --events

The GIF goes next to the video ("clip.gif", "clip 2.gif", …); nothing is
ever replaced, and a cancelled run leaves nothing behind.
"""
import argparse
import json
import re
import shutil
import signal
import subprocess
import sys
import tempfile
import threading
from pathlib import Path

from videocrunch import abort_on_sigterm, get_video_info, parse_time_to_seconds, stop_encoder

DEFAULT_WIDTH = 480
DEFAULT_FPS = 15
DEFAULT_QUALITY = 90
# Long enough to hold real motion, short enough for a size estimate in seconds.
SAMPLE_SEC = 2.0

HDR_TRANSFERS = {"smpte2084", "arib-std-b67"}  # PQ (HDR10), HLG
# HLG/PQ to BT.709 on the GPU — this ffmpeg has neither zscale nor libplacebo.
TONEMAP = ("format=p010le,hwupload,"
           "tonemap_opencl=tonemap=hable:desat=0:t=bt709:m=bt709:p=bt709:r=tv:format=nv12,"
           "hwdownload,format=nv12")

GIFSKI_FRAME_RE = re.compile(r"Frame (\d+) / \d+")

event_stream = None


def emit(event: str, **fields) -> None:
    """One machine-readable line, in batch.py's --events format."""
    if event_stream is None:
        return
    event_stream.write(json.dumps({"event": event, **fields}, ensure_ascii=False) + "\n")
    event_stream.flush()


def output_path_for(src: Path) -> Path:
    """`clip.gif` next to the video, or `clip 2.gif` when that exists."""
    candidate = src.with_suffix(".gif")
    n = 2
    while candidate.exists():
        candidate = src.with_name(f"{src.stem} {n}.gif")
        n += 1
    return candidate


def is_hdr(info: dict) -> bool:
    return str(info.get("color_transfer") or "") in HDR_TRANSFERS


def video_filter(fps: int, width: int, hdr: bool) -> str:
    """Frame rate first (fewer frames to scale), never wider than the source."""
    steps = [f"fps={fps}", f"scale=w='min({width},iw)':h=-2:flags=lanczos"]
    if hdr:
        steps.append(TONEMAP)
    # 8-bit 4:2:0: what yuv4mpegpipe hands gifski (10-bit or NV12 it refuses).
    steps.append("format=yuv420p")
    return ",".join(steps)


def clip_range(ss, to, duration: float) -> tuple:
    start = parse_time_to_seconds(ss) if ss else 0.0
    end = min(parse_time_to_seconds(to), duration) if to else duration
    return (start, end)


def sample_window(start: float, end: float, length: float) -> tuple:
    """A stretch from the middle: the first seconds are often a still frame."""
    if end - start <= length:
        return (start, end)
    middle = (start + end) / 2
    return (middle - length / 2, middle + length / 2)


def expected_frames(seconds: float, fps: int) -> int:
    return max(1, round(seconds * fps))


def gifski_frames(text: str):
    """The last "Frame N / M" gifski printed, or None."""
    found = GIFSKI_FRAME_RE.findall(text)
    return int(found[-1]) if found else None


def extrapolate(sample_bytes: int, sample_sec: float, total_sec: float) -> int:
    return int(round(sample_bytes * total_sec / sample_sec))


def _input_args(src: Path, start: float, end: float, hdr: bool) -> list:
    hw = ["-init_hw_device", "opencl=gpu", "-filter_hw_device", "gpu"] if hdr else []
    return ["ffmpeg", "-v", "error", "-nostdin", *hw,
            "-ss", f"{start:.3f}", "-to", f"{end:.3f}", "-i", str(src), "-an"]


def _pump(stream, sink: list) -> None:
    """Read a pipe in chunks; gifski ends its progress lines with \\r."""
    while True:
        chunk = stream.read1(4096) if hasattr(stream, "read1") else stream.read(4096)
        if not chunk:
            return
        sink.append(chunk.decode("utf-8", "replace"))


def _run_gifski(src, out, start, end, fps, width, quality, hdr, on_frames, procs):
    reader = subprocess.Popen(
        _input_args(src, start, end, hdr)
        + ["-vf", video_filter(fps, width, hdr), "-f", "yuv4mpegpipe", "-"],
        stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    writer = subprocess.Popen(
        ["gifski", "--fps", str(fps), "--quality", str(quality), "--width", str(width),
         "-o", str(out), "-"],
        stdin=reader.stdout, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
    reader.stdout.close()  # gifski owns the pipe now
    procs += [reader, writer]

    printed: list = []
    pump = threading.Thread(target=_pump, args=(writer.stdout, printed), daemon=True)
    pump.start()
    while pump.is_alive():
        pump.join(0.25)
        frames = gifski_frames("".join(printed[-4:]))
        if frames is not None:
            on_frames(frames)
    writer.wait()
    reader_err = reader.communicate()[1].decode("utf-8", "replace")
    if writer.returncode != 0 or reader.returncode != 0:
        raise RuntimeError((reader_err.strip() or "".join(printed).strip())[-300:]
                           or "gifski failed")


def _run_ffmpeg(src, out, start, end, fps, width, hdr, on_frames, procs):
    graph = (f"{video_filter(fps, width, hdr)},split[a][b];"
             f"[a]palettegen=stats_mode=diff[p];[b][p]paletteuse=dither=sierra2_4a")
    proc = subprocess.Popen(
        _input_args(src, start, end, hdr)
        + ["-filter_complex", graph, "-loop", "0", "-f", "gif",
           "-progress", "pipe:1", "-nostats", "-y", str(out)],
        stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
    procs.append(proc)
    for line in proc.stdout:
        if line.startswith("out_time_us="):
            try:
                on_frames(int(int(line.split("=", 1)[1]) / 1_000_000 * fps))
            except ValueError:
                pass
    err = proc.stderr.read()
    if proc.wait() != 0:
        raise RuntimeError(err.strip()[-300:] or "ffmpeg failed")


def encode(src, out, start, end, fps, width, quality, hdr, encoder, on_frames=lambda n: None):
    """Write the GIF to `out`. HDR falls back to no tone-mapping if OpenCL fails."""
    procs: list = []
    try:
        try:
            if encoder == "gifski":
                _run_gifski(src, out, start, end, fps, width, quality, hdr, on_frames, procs)
            else:
                _run_ffmpeg(src, out, start, end, fps, width, hdr, on_frames, procs)
        except RuntimeError:
            if not hdr:
                raise
            # Washed-out colours beat no GIF at all.
            encode(src, out, start, end, fps, width, quality, False, encoder, on_frames)
    finally:
        for p in procs:
            if p.poll() is None:
                stop_encoder(p)


def gif_size(path: Path) -> tuple:
    probe = subprocess.run(
        ["ffprobe", "-v", "error", "-select_streams", "v:0",
         "-show_entries", "stream=width,height", "-of", "csv=p=0", str(path)],
        capture_output=True, text=True)
    try:
        w, h = probe.stdout.strip().split(",")[:2]
        return int(w), int(h)
    except ValueError:
        return 0, 0


def build_parser():
    p = argparse.ArgumentParser(description="Make a GIF from a video (gifski, else ffmpeg)")
    p.add_argument("input")
    p.add_argument("--ss", metavar="TIME", help="Start (seconds or HH:MM:SS)")
    p.add_argument("--to", metavar="TIME", help="End (seconds or HH:MM:SS)")
    p.add_argument("--width", type=int, default=DEFAULT_WIDTH, help="Maximum width in pixels")
    p.add_argument("--fps", type=int, default=DEFAULT_FPS, help="Frames per second")
    p.add_argument("--quality", type=int, default=DEFAULT_QUALITY, help="1-100 (gifski)")
    p.add_argument("--encoder", choices=["gifski", "ffmpeg"],
                   help="Default: gifski when installed, else ffmpeg")
    p.add_argument("--output", help="Where to write the GIF (default: next to the video)")
    p.add_argument("--json-out", metavar="PATH", help="Write the result as JSON")
    p.add_argument("--estimate", action="store_true",
                   help="Print the expected size as JSON instead of writing a GIF")
    p.add_argument("--events", action="store_true", help="JSON lines on stdout, like batch.py")
    return p


def main() -> int:
    global event_stream
    args = build_parser().parse_args()
    signal.signal(signal.SIGTERM, abort_on_sigterm)
    if args.events:
        event_stream = sys.stdout

    src = Path(args.input)
    encoder = args.encoder or ("gifski" if shutil.which("gifski") else "ffmpeg")
    info = get_video_info(src) if src.is_file() else None
    start, end = clip_range(args.ss, args.to, (info or {}).get("duration") or 0.0)
    hdr = bool(info) and is_hdr(info)

    if args.estimate:
        if not info or end <= start:
            print(json.dumps({"error": "Video nicht lesbar"}))
            return 1
        s0, s1 = sample_window(start, end, SAMPLE_SEC)
        with tempfile.TemporaryDirectory(prefix="videocrunch_gif_") as tmp:
            sample = Path(tmp) / "sample.gif"
            try:
                encode(src, sample, s0, s1, args.fps, args.width, args.quality, hdr, encoder)
            except (RuntimeError, OSError) as e:
                print(json.dumps({"error": str(e)}))
                return 1
            width, height = gif_size(sample)
            print(json.dumps({
                "estimated_bytes": extrapolate(sample.stat().st_size, s1 - s0, end - start),
                "width": width, "height": height,
                "frames": expected_frames(end - start, args.fps), "encoder": encoder,
            }))
        return 0

    out = Path(args.output) if args.output else output_path_for(src)
    part = out.with_name(f".{out.name}.part")
    total = expected_frames(end - start, args.fps)
    emit("start", total=1, workers=1, files=[str(src)])
    emit("file_start", worker=1, file=str(src), name=src.name)

    def on_frames(n):
        percent = min(99, int(n * 100 / total))
        emit("progress", worker=1, file=str(src), phase="gif", percent=percent)

    result = {"input_path": str(src), "output_path": str(out), "encoder": encoder}
    try:
        if not info or end <= start:
            raise RuntimeError("Video nicht lesbar oder leerer Bereich")
        encode(src, part, start, end, args.fps, args.width, args.quality, hdr, encoder, on_frames)
        part.replace(out)
        width, height = gif_size(out)
        result.update(status="success", size_bytes=out.stat().st_size, width=width,
                      height=height, frames=total, duration_sec=round(end - start, 3))
    except KeyboardInterrupt:
        result.update(status="cancelled", reason="Abgebrochen")
    except (RuntimeError, OSError) as e:
        result.update(status="failed", reason=str(e))
    finally:
        part.unlink(missing_ok=True)

    if args.json_out:
        Path(args.json_out).write_text(json.dumps(result, ensure_ascii=False), encoding="utf-8")
    ok = result["status"] == "success"
    emit("file_done", worker=1, file=str(src), status=result["status"],
         reason=result.get("reason"), output_path=str(out) if ok else None,
         size_bytes=result.get("size_bytes"))
    emit("summary", succeeded=int(ok), failed=int(not ok))
    if not args.events:
        if ok:
            print(f"GIF: {out} ({result['size_bytes'] / 1e6:.1f} MB, "
                  f"{result['width']}x{result['height']}, {total} Bilder)")
        else:
            print(f"GIF fehlgeschlagen: {result.get('reason')}", file=sys.stderr)
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
