#!/usr/bin/env python3
"""Bring videos under a size: for a mail, a chat, an upload limit.

The quality search (videocrunch.py) asks "how small can it get and still
look the same?". This asks the other question: "it has to fit in 25 MB —
what is the best it can look?". The bitrate follows from size and length;
the resolution follows from the bitrate, so a long video comes out smaller
in pixels rather than as a smeared 4K.

    fit.py clip.mov --max-mb 25
    fit.py --files-from list.txt --max-mb 10 --events --json-out report.json

Each result goes next to its video as "clip_25MB.mp4"; the original stays.
--json-out and --events speak batch.py's formats, so the app shows the run
like any other.
"""
import argparse
import json
import math
import signal
import subprocess
import sys
import time
from pathlib import Path
from typing import Optional

from crunch_utils import apply_hdr_adjustments, is_hdr_or_10bit
from videocrunch import (
    EditRequest,
    Edits,
    abort_on_sigterm,
    build_ffmpeg_command,
    get_video_info,
    half_frame_rate,
    parse_time_to_seconds,
    probe_stream_inventory,
    select_profile,
    settle_edits,
    stop_encoder,
)

AUDIO_KBPS = 192           # what build_ffmpeg_command gives every AAC track
OVERHEAD = 0.95            # container and rate-control slack: first try usually fits
MAX_TRIES = 3
# Bits per pixel per frame below which HEVC turns to mush; under it the
# picture gets smaller instead.
MIN_BPP = 0.045
SHORT_SIDES = (2160, 1440, 1080, 720, 540, 360)
MIN_VIDEO_KBPS = 120

event_stream = None


def emit(event: str, **fields) -> None:
    """One machine-readable line, in batch.py's --events format."""
    if event_stream is None:
        return
    event_stream.write(json.dumps({"event": event, **fields}, ensure_ascii=False) + "\n")
    event_stream.flush()


def video_kbps_for(max_bytes: float, seconds: float, audio_kbps: float) -> float:
    """The video bitrate that lands the whole file at `max_bytes`."""
    if seconds <= 0:
        return 0.0
    return max(0.0, max_bytes * 8 * OVERHEAD / seconds / 1000 - audio_kbps)


def pick_short_side(kbps: float, width: int, height: int, fps: float) -> Optional[int]:
    """The largest short side (never above the source's) that kbps can fill, or None."""
    short, long_ = min(width, height), max(width, height)
    if short <= 0 or fps <= 0:
        return None
    sides = [short] + [s for s in SHORT_SIDES if s < short]
    for side in sides:
        pixels = side * long_ * side / short
        if kbps * 1000 / (pixels * fps) >= MIN_BPP:
            return side
    return None


def plan(max_bytes: float, seconds: float, info: dict, audio_tracks: int) -> dict:
    """Bitrate, size and frame rate for one video; "error" when it cannot fit."""
    kbps = video_kbps_for(max_bytes, seconds, AUDIO_KBPS * audio_tracks)
    if kbps < MIN_VIDEO_KBPS:
        mb = max_bytes / 1e6
        longest = max_bytes * 8 * OVERHEAD / ((MIN_VIDEO_KBPS + AUDIO_KBPS * audio_tracks) * 1000)
        return {"error": f"zu lang für {mb:g} MB (höchstens etwa {math.floor(longest)} s)"}
    width, height, fps = info.get("width") or 0, info.get("height") or 0, info.get("fps") or 30
    side = pick_short_side(kbps, width, height, fps)
    half = None
    if side is None and half_frame_rate(info):
        half = half_frame_rate(info)
        side = pick_short_side(kbps, width, height, fps / 2)
    if side is None:
        side = min(min(width, height), SHORT_SIDES[-1])
    return {"video_kbps": round(kbps), "short_side": side,
            "scale_height": side if side < min(width, height) else None, "fps": half}


def output_path_for(src: Path, max_mb: float) -> Path:
    """`clip_25MB.mp4` next to the video, `clip_25MB 2.mp4` when that exists."""
    base = f"{src.stem}_{max_mb:g}MB"
    candidate = src.with_name(base + ".mp4")
    n = 2
    while candidate.exists():
        candidate = src.with_name(f"{base} {n}.mp4")
        n += 1
    return candidate


def _encode(cmd, seconds: float, on_percent) -> bool:
    proc = subprocess.Popen(cmd, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
    try:
        for line in proc.stdout:
            if line.startswith("out_time_us=") and seconds > 0:
                try:
                    done = int(line.split("=", 1)[1]) / 1e6
                except ValueError:
                    continue
                on_percent(min(99, int(done * 100 / seconds)))
        return proc.wait() == 0
    except KeyboardInterrupt:
        stop_encoder(proc)
        raise


def fit_file(src: Path, max_mb: float, profile: dict, request: EditRequest,
             audio_mode: str, ss=None, to=None) -> dict:
    """Encode one video under max_mb. Returns a batch.py-style result."""
    result = {"filename": src.name, "path": str(src.resolve()), "status": "failed", "quality": None,
              "ssim": None, "saved_pct": None, "saved_bytes": None, "duration": 0,
              "reason": None, "output_path": None}
    started = time.time()
    info = get_video_info(src) if src.is_file() else None
    if not info or info["duration"] <= 0:
        result["reason"] = "Video nicht lesbar"
        return result
    start = parse_time_to_seconds(ss) if ss else 0.0
    end = min(parse_time_to_seconds(to), info["duration"]) if to else info["duration"]
    seconds = end - start
    max_bytes = max_mb * 1e6
    size_before = src.stat().st_size
    if size_before <= max_bytes and not (ss or to):
        result.update(status="skipped", reason=f"schon unter {max_mb:g} MB")
        return result

    if is_hdr_or_10bit(info):
        profile = apply_hdr_adjustments(profile, info) or profile
    streams = probe_stream_inventory(src)
    edits = settle_edits(request, info, src, profile, start, seconds)
    audio = 0 if edits.mute else sum(1 for s in streams if s.get("codec_type") == "audio")
    p = plan(max_bytes, seconds, info, audio)
    if "error" in p:
        result["reason"] = p["error"]
        return result
    # The size plan may halve the rate too, when even 360p is too much.
    edits = Edits(fps=edits.fps or p["fps"], crop=edits.crop, mute=edits.mute)

    out = output_path_for(src, max_mb)
    part = out.with_name(f".{out.stem}.part.mp4")  # ffmpeg picks the muxer by extension
    kbps = p["video_kbps"]
    try:
        for attempt in range(1, MAX_TRIES + 1):
            cmd = build_ffmpeg_command(
                src, part, profile, 0, audio_mode=audio_mode, ss=ss, to=to,
                target_bitrate_kbps=kbps, maxrate_kbps=kbps * 1.5, bufsize_kbps=kbps * 2,
                color_args=profile.get("color_args"), scale_height=p["scale_height"],
                streams=streams, edits=edits)
            ok = _encode(cmd, seconds, lambda pct, a=attempt: emit(
                "progress", worker=1, file=str(src), phase="encode", **{"pass": a}, percent=pct))
            if not ok or not part.exists():
                result["reason"] = "Encoder-Fehler"
                return result
            size = part.stat().st_size
            print(f"Versuch {attempt}: {size / 1e6:.1f} MB bei {kbps} kbit/s "
                  f"({p['short_side']}p)", flush=True)
            if size <= max_bytes:
                part.replace(out)
                result.update(status="success", output_path=str(out.resolve()),
                              saved_bytes=size_before - size,
                              saved_pct=round(100 - size * 100 / size_before, 1))
                return result
            kbps = int(kbps * max_bytes / size * 0.96)
            if kbps < MIN_VIDEO_KBPS:
                break
        result["reason"] = f"nicht unter {max_mb:g} MB zu bringen"
        return result
    except KeyboardInterrupt:
        result.update(status="cancelled", reason="Abgebrochen")
        return result
    finally:
        part.unlink(missing_ok=True)
        result["duration"] = round(time.time() - started, 1)


def build_parser():
    p = argparse.ArgumentParser(description="Bring videos under a size (mail, chat, upload)")
    p.add_argument("files", nargs="*")
    p.add_argument("--files-from", metavar="PATH", help="Paths, one per line")
    p.add_argument("--max-mb", type=float, required=True, help="Upper limit per video in MB")
    p.add_argument("--codec", choices=["hevc", "av1"], default="hevc")
    p.add_argument("--audio-mode", choices=["enhanced", "standard"], default="standard")
    p.add_argument("--no-audio", action="store_true")
    p.add_argument("--half-fps", action="store_true")
    p.add_argument("--crop-bars", action="store_true")
    p.add_argument("--ss", metavar="TIME")
    p.add_argument("--to", metavar="TIME")
    p.add_argument("--json-out", metavar="PATH", help="All results, as batch.py writes them")
    p.add_argument("--events", action="store_true", help="JSON lines on stdout, like batch.py")
    return p


def main() -> int:
    global event_stream
    args = build_parser().parse_args()
    signal.signal(signal.SIGTERM, abort_on_sigterm)
    files = list(args.files)
    if args.files_from:
        files += [ln for ln in Path(args.files_from).read_text(encoding="utf-8").splitlines()
                  if ln.strip()]
    if not files or args.max_mb <= 0:
        build_parser().error("needs files and a positive --max-mb")
    if args.events:
        event_stream = sys.stdout

    profile = select_profile("auto", args.codec)
    request = EditRequest(half_fps=args.half_fps, crop_bars=args.crop_bars, mute=args.no_audio)
    started = time.time()
    emit("start", total=len(files), workers=1, files=files)
    results = []
    for f in files:
        src = Path(f).expanduser()
        emit("file_start", worker=1, file=str(src), name=src.name)
        r = fit_file(src, args.max_mb, profile, request, args.audio_mode, args.ss, args.to)
        results.append(r)
        emit("file_done", worker=1, file=str(src), status=r["status"], quality=None, ssim=None,
             saved_pct=r["saved_pct"], reason=r["reason"])
        if r["status"] == "cancelled":
            break
    ok = sum(1 for r in results if r["status"] in ("success", "skipped"))
    if args.json_out:
        Path(args.json_out).write_text(json.dumps({"videocrunch": 1, "results": results},
                                                  ensure_ascii=False), encoding="utf-8")
    emit("summary", succeeded=ok, failed=len(results) - ok,
         elapsed_sec=round(time.time() - started, 1), log=None)
    if not args.events:
        for r in results:
            print(f"{r['filename']}: {r['status']}"
                  + (f" → {r['output_path']}" if r["output_path"] else f" ({r['reason']})"))
    return 0 if ok == len(results) else 1


if __name__ == "__main__":
    sys.exit(main())
