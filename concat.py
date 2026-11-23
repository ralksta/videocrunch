#!/usr/bin/env python3
"""Lossless concatenation of compatible clips (`ffmpeg -f concat -c copy`).

    concat.py clip1.mp4 clip2.mp4 --events --json-out report.json
"""
from __future__ import annotations

import argparse
import json
import signal
import subprocess
import sys
import tempfile
import time
from pathlib import Path
from typing import Optional

from crunch_utils import is_hdr_or_10bit, valid_live_bitrate, valid_live_speed
from fit import publish
from videocrunch import abort_on_sigterm, get_video_info, stop_encoder

event_stream = None


def emit(event: str, **fields) -> None:
    """One machine-readable line, in batch.py's --events format."""
    if event_stream is None:
        return
    event_stream.write(json.dumps({"event": event, **fields}, ensure_ascii=False) + "\n")
    event_stream.flush()


def check_concat_compatibility(infos: list[dict]) -> tuple[bool, Optional[str]]:
    """Verify clips share codec, resolution and HDR/10-bit state for stream-copy concat."""
    if len(infos) < 2:
        return False, "Mindestens zwei Videos erforderlich."

    codecs = {str(info.get("codec") or "").lower() for info in infos}
    if "" in codecs or len(codecs) > 1:
        names = ", ".join(sorted(c.upper() for c in codecs if c)) or "unbekannt"
        return False, f"Unterschiedliche Codecs ({names})."

    dims = {(int(info.get("width") or 0), int(info.get("height") or 0)) for info in infos}
    if (0, 0) in dims or len(dims) > 1:
        labels = ", ".join(sorted(f"{w}×{h}" for w, h in dims))
        return False, f"Unterschiedliche Auflösungen ({labels})."

    hdr_states = {is_hdr_or_10bit(info) for info in infos}
    if len(hdr_states) > 1:
        return False, "SDR und HDR können nicht verlustfrei verbunden werden."

    return True, None


def format_concat_list(paths: list[Path]) -> str:
    """Build an FFmpeg concat-demuxer input list with properly escaped paths."""
    lines = []
    for p in paths:
        escaped = str(p.resolve()).replace("'", "'\\''")
        lines.append(f"file '{escaped}'\n")
    return "".join(lines)


def output_path_for(first: Path, output_dir: Optional[Path] = None) -> Path:
    """`<stem>_merged.mp4` next to the first clip (or in output_dir), incrementing if taken."""
    dest_dir = Path(output_dir).expanduser() if output_dir else first.parent
    base = f"{first.stem}_merged"
    candidate = dest_dir / f"{base}.mp4"
    n = 2
    while candidate.exists():
        candidate = dest_dir / f"{base} {n}.mp4"
        n += 1
    return candidate


def _run_concat(cmd: list[str], total_seconds: float, on_progress) -> bool:
    proc = subprocess.Popen(cmd, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, text=True)
    cur_speed = None
    cur_bitrate = None
    try:
        assert proc.stdout is not None
        for line in proc.stdout:
            if line.startswith("speed="):
                cur_speed = valid_live_speed(line.split("=", 1)[1])
            elif line.startswith("bitrate="):
                cur_bitrate = valid_live_bitrate(line.split("=", 1)[1])
            elif line.startswith("out_time_us=") and total_seconds > 0:
                try:
                    done = int(line.split("=", 1)[1]) / 1e6
                except ValueError:
                    continue
                on_progress(min(99, int(done * 100 / total_seconds)), cur_speed, cur_bitrate)
        return proc.wait() == 0
    except KeyboardInterrupt:
        stop_encoder(proc)
        raise


def concat_files(paths: list[Path], output_dir: Optional[Path] = None) -> dict:
    """Losslessly join `paths` into a single MP4. Returns a batch.py-style result."""
    started = time.time()
    first = paths[0]
    out_hint = output_path_for(first, output_dir=output_dir) if paths else Path("merged.mp4")
    result = {
        "filename": out_hint.name,
        "path": str(first.resolve()),
        "status": "failed",
        "quality": None,
        "ssim": None,
        "saved_pct": 0.0,
        "saved_bytes": 0,
        "duration": 0,
        "reason": None,
        "output_path": None,
    }

    infos = []
    for p in paths:
        info = get_video_info(p) if p.is_file() else None
        if not info or info.get("duration", 0) <= 0:
            result["reason"] = f"Video nicht lesbar: {p.name}"
            return result
        infos.append(info)

    ok_compat, reason = check_concat_compatibility(infos)
    if not ok_compat:
        result["reason"] = reason
        return result

    total_duration = sum(float(i["duration"]) for i in infos)
    common_codec = str(infos[0].get("codec") or "").lower()
    out = output_path_for(first, output_dir=output_dir)
    out.parent.mkdir(parents=True, exist_ok=True)
    result["filename"] = out.name
    part = out.with_name(f".{out.stem}.part.mp4")

    list_file = None
    try:
        with tempfile.NamedTemporaryFile(
            mode="w", suffix=".txt", prefix="videocrunch_concat_",
            delete=False, encoding="utf-8",
        ) as tf:
            tf.write(format_concat_list(paths))
            list_file = Path(tf.name)

        cmd = [
            "ffmpeg", "-y",
            "-f", "concat", "-safe", "0",
            "-i", str(list_file),
            "-c", "copy",
        ]
        if common_codec in ("hevc", "h265"):
            cmd.extend(["-tag:v", "hvc1"])
        cmd.extend([
            "-movflags", "+faststart+use_metadata_tags",
            "-map_metadata", "0",
            "-progress", "pipe:1",
            "-loglevel", "error",
            str(part),
        ])

        def emit_progress(pct: int, speed: Optional[str], bitrate: Optional[str]) -> None:
            extra = {}
            if speed is not None:
                extra["speed"] = speed
            if bitrate is not None:
                extra["bitrate"] = bitrate
            emit("progress", worker=1, file=str(first), phase="encode",
                 **{"pass": 1}, percent=pct,
                 detail=f"Verbinde {len(paths)} Clips verlustfrei …", **extra)

        ok = _run_concat(cmd, total_duration, emit_progress)
        if not ok or not part.exists():
            result["reason"] = "Concat fehlgeschlagen (Streams eventuell nicht kompatibel)"
            return result

        publish(part, out)
        result.update(
            status="success",
            output_path=str(out.resolve()),
            saved_bytes=0,
            saved_pct=0.0,
        )
        return result
    except KeyboardInterrupt:
        result.update(status="cancelled", reason="Abgebrochen")
        return result
    finally:
        part.unlink(missing_ok=True)
        if list_file is not None:
            list_file.unlink(missing_ok=True)
        result["duration"] = round(time.time() - started, 1)


def build_parser() -> argparse.ArgumentParser:
    p = argparse.ArgumentParser(description="Losslessly join compatible videos into one MP4")
    p.add_argument("files", nargs="*")
    p.add_argument("--files-from", metavar="PATH", help="Paths in merge order, one per line")
    p.add_argument("--json-out", metavar="PATH", help="Result JSON, as batch.py writes it")
    p.add_argument("--events", action="store_true", help="JSON lines on stdout, like batch.py")
    p.add_argument("--output-dir", metavar="DIR", help="Write the merged MP4 into DIR")
    return p


def main() -> int:
    global event_stream
    args = build_parser().parse_args()
    signal.signal(signal.SIGTERM, abort_on_sigterm)
    raw_files = list(args.files)
    if args.files_from:
        raw_files += [
            ln for ln in Path(args.files_from).read_text(encoding="utf-8").splitlines()
            if ln.strip()
        ]
    if len(raw_files) < 2:
        build_parser().error("needs at least two input files")

    paths = [Path(f).expanduser() for f in raw_files]
    output_dir = Path(args.output_dir).expanduser() if args.output_dir else None
    if args.events:
        event_stream = sys.stdout

    started = time.time()
    emit("start", total=1, workers=1, files=raw_files)
    emit("file_start", worker=1, file=str(paths[0]), name=f"{len(paths)} Clips zusammenfügen")
    res = concat_files(paths, output_dir=output_dir)
    emit("file_done", worker=1, file=str(paths[0]), status=res["status"],
         quality=None, ssim=None, saved_pct=res["saved_pct"],
         saved_bytes=res.get("saved_bytes"), reason=res["reason"])

    ok = 1 if res["status"] == "success" else 0
    if args.json_out:
        Path(args.json_out).write_text(
            json.dumps({"videocrunch": 1, "results": [res]}, ensure_ascii=False),
            encoding="utf-8",
        )
    emit("summary", succeeded=ok, failed=1 - ok,
         elapsed_sec=round(time.time() - started, 1), log=None)

    if not args.events:
        print(f"{res['filename']}: {res['status']}"
              + (f" → {res['output_path']}" if res["output_path"] else f" ({res['reason']})"))
    return 0 if ok == 1 else 1


if __name__ == "__main__":
    sys.exit(main())
