#!/usr/bin/env python3
"""Detailed media inspection for VideoCrunch (streams, warnings, bitrate curve).

    inspect_media.py clip.mov --json
"""
from __future__ import annotations

import argparse
import json
import math
import statistics
import subprocess
import sys
from pathlib import Path
from typing import Any

from crunch_utils import (
    MOV_TEXT_SUBTITLES,
    build_stream_args,
    dolby_vision_info,
    first_video_stream,
    is_attached_pic,
    is_hdr,
    is_hdr_or_10bit,
    select_top_windows,
)
from videocrunch import analyze_packet_hotspots, available_decoders


def _parse_fps(stream: dict | None) -> float:
    if not stream:
        return 0.0
    raw = stream.get("r_frame_rate") or stream.get("avg_frame_rate") or "0/1"
    try:
        if "/" in str(raw):
            num, den = str(raw).split("/", 1)
            d = float(den)
            return round(float(num) / d, 2) if d else 0.0
        return round(float(raw), 2)
    except (ValueError, ZeroDivisionError):
        return 0.0


def _stream_rotation(stream: dict | None) -> int:
    if not stream:
        return 0
    for sd in stream.get("side_data_list") or []:
        if "rotation" in sd:
            try:
                return int(float(sd["rotation"]))
            except (TypeError, ValueError):
                pass
    rot_tag = (stream.get("tags") or {}).get("rotate")
    if rot_tag is not None:
        try:
            return int(float(rot_tag))
        except (TypeError, ValueError):
            pass
    return 0


def _bit_depth(stream: dict | None) -> int:
    if not stream:
        return 8
    raw = stream.get("bits_per_raw_sample")
    if raw is not None:
        try:
            val = int(raw)
            if val > 0:
                return val
        except (TypeError, ValueError):
            pass
    pix = str(stream.get("pix_fmt") or "")
    if "12" in pix:
        return 12
    if "10" in pix or "p010" in pix or "p210" in pix:
        return 10
    return 8


def _hdr_label(stream: dict | None) -> str:
    if not stream:
        return "SDR"
    trc = str(stream.get("color_transfer") or "")
    if trc == "arib-std-b67":
        return "HLG HDR"
    if trc == "smpte2084":
        return "HDR10 (PQ)"
    if is_hdr(stream):
        return "BT.2020 HDR"
    if is_hdr_or_10bit(stream):
        return "10-Bit SDR"
    return "SDR"


def _stream_detail(stream: dict, width: int, height: int, fps: float, bit_depth: int) -> str:
    kind = stream.get("codec_type")
    if kind == "video":
        if is_attached_pic(stream):
            return "Cover-Bild"
        parts = [f"{width}×{height}"] if width and height else []
        if fps > 0:
            parts.append(f"{fps:g} fps")
        if bit_depth > 8:
            parts.append(f"{bit_depth}-Bit")
        return " · ".join(parts)
    if kind == "audio":
        parts = []
        layout = stream.get("channel_layout")
        channels = stream.get("channels")
        if layout:
            parts.append(str(layout))
        elif channels:
            parts.append(f"{channels}ch")
        sr = stream.get("sample_rate")
        if sr:
            try:
                parts.append(f"{int(sr) / 1000:g} kHz")
            except (TypeError, ValueError):
                pass
        br = stream.get("bit_rate")
        if br:
            try:
                parts.append(f"{round(int(br) / 1000)} kbit/s")
            except (TypeError, ValueError):
                pass
        return " · ".join(parts)
    tag = stream.get("codec_tag_string")
    return str(tag) if tag and tag != "[0][0][0][0]" else ""


def _downsample(values: list[float], max_points: int = 80) -> list[float]:
    if len(values) <= max_points:
        return [round(v, 1) for v in values]
    step = len(values) / max_points
    out = []
    for i in range(max_points):
        lo = int(i * step)
        hi = max(lo + 1, int((i + 1) * step))
        chunk = values[lo:hi]
        out.append(round(sum(chunk) / len(chunk), 1))
    return out


def _build_bitrate_summary(buckets: dict[int, int], duration: float, bucket_len: float,
                           fallback_kbps: float) -> dict[str, Any]:
    if not buckets or duration <= 0 or bucket_len <= 0:
        return {
            "avg_kbps": round(fallback_kbps, 1),
            "max_kbps": round(fallback_kbps, 1),
            "min_kbps": round(fallback_kbps, 1),
            "is_vbr": False,
            "samples_kbps": [],
            "hotspots_sec": [],
        }
    n_buckets = max(1, math.ceil(duration / bucket_len))
    raw_kbps: list[float] = []
    for i in range(n_buckets):
        span = min(bucket_len, max(0.25, duration - i * bucket_len))
        raw_kbps.append((buckets.get(i, 0) * 8.0) / (span * 1000.0))

    avg_kbps = sum(raw_kbps) / len(raw_kbps)
    std_dev = statistics.pstdev(raw_kbps) if len(raw_kbps) > 1 else 0.0
    hotspots = [round(t, 2) for t in select_top_windows(
        buckets, duration, n=3, window=3.0, bucket_len=bucket_len)]
    return {
        "avg_kbps": round(avg_kbps, 1),
        "max_kbps": round(max(raw_kbps), 1),
        "min_kbps": round(min(raw_kbps), 1),
        "is_vbr": (std_dev / avg_kbps > 0.25) if avg_kbps > 0 else False,
        "samples_kbps": _downsample(raw_kbps, max_points=80),
        "hotspots_sec": hotspots,
    }


def _camera_label(tags: dict) -> str | None:
    make = str(tags.get("com.apple.quicktime.make") or "").strip()
    model = str(tags.get("com.apple.quicktime.model") or "").strip()
    if model and make and not model.lower().startswith(make.lower()):
        return f"{make} {model}"
    return model or make or None


def build_inspection_report(probe_data: dict, path: Path, size_bytes: int,
                            buckets: dict[int, int], bucket_len: float,
                            decodable: set[str] | None = None) -> dict[str, Any]:
    """Turn ffprobe JSON + packet buckets into a clean MediaInspection dict."""
    fmt = probe_data.get("format") or {}
    streams = probe_data.get("streams") or []
    chapters = probe_data.get("chapters") or []
    fmt_tags = fmt.get("tags") or {}

    duration = 0.0
    try:
        duration = float(fmt.get("duration") or 0.0)
    except (TypeError, ValueError):
        pass

    vstream = first_video_stream(streams)
    width = int((vstream or {}).get("width") or 0)
    height = int((vstream or {}).get("height") or 0)
    rotation = _stream_rotation(vstream)
    if abs(rotation) % 360 in (90, 270):
        width, height = height, width
    fps = _parse_fps(vstream)
    bit_depth = _bit_depth(vstream)

    v_kbps = 0.0
    for candidate in ((vstream or {}).get("bit_rate"), fmt.get("bit_rate")):
        if candidate:
            try:
                v_kbps = float(candidate) / 1000.0
                break
            except (TypeError, ValueError):
                pass
    if v_kbps <= 0 and duration > 0 and size_bytes > 0:
        v_kbps = (size_bytes * 8.0) / (duration * 1000.0)

    _, dropped = build_stream_args(streams, copy_audio=False, audio_filters=None,
                                   decodable=decodable)
    dv = dolby_vision_info((vstream or {}).get("side_data_list") or []) if vstream else None

    stream_entries = []
    for idx, st in enumerate(streams):
        kind = str(st.get("codec_type") or "unknown")
        codec = str(st.get("codec_name") or st.get("codec_tag_string") or "unknown")
        if kind == "video":
            kept = st is vstream
        elif kind == "audio":
            kept = decodable is None or codec in decodable
        elif kind == "subtitle":
            kept = codec in MOV_TEXT_SUBTITLES
        else:
            kept = False
        lang = str((st.get("tags") or {}).get("language") or "")
        if lang.lower() in ("", "und"):
            lang = ""
        stream_entries.append({
            "index": int(st.get("index", idx)),
            "type": kind,
            "codec": codec,
            "detail": _stream_detail(st, width, height, fps, bit_depth),
            "language": lang or None,
            "kept": kept,
        })

    creation = (fmt_tags.get("com.apple.quicktime.creationdate")
                or fmt_tags.get("creation_time"))
    location = fmt_tags.get("com.apple.quicktime.location.ISO6709")

    container = str(fmt.get("format_name") or path.suffix.lstrip(".")).split(",")[0].upper()

    return {
        "filename": path.name,
        "path": str(path),
        "container": container,
        "size_bytes": int(size_bytes),
        "duration_sec": round(duration, 2),
        "video": {
            "codec": str((vstream or {}).get("codec_name") or "unknown"),
            "profile": (vstream or {}).get("profile"),
            "width": width,
            "height": height,
            "fps": fps,
            "pix_fmt": (vstream or {}).get("pix_fmt"),
            "bit_depth": bit_depth,
            "color_space": (vstream or {}).get("color_space"),
            "color_transfer": (vstream or {}).get("color_transfer"),
            "color_primaries": (vstream or {}).get("color_primaries"),
            "hdr_label": _hdr_label(vstream),
            "is_hdr": is_hdr(vstream) if vstream else False,
            "rotation": rotation,
            "kbps": round(v_kbps, 1),
        },
        "streams": stream_entries,
        "metadata": {
            "creation_time": str(creation) if creation else None,
            "camera": _camera_label(fmt_tags),
            "location": str(location) if location else None,
            "chapters": len(chapters),
        },
        "warnings": {
            "dolby_vision": dv,
            "dropped": dropped,
        },
        "bitrate": _build_bitrate_summary(buckets, duration, bucket_len, v_kbps),
    }


def inspect_file(path: Path) -> dict[str, Any]:
    """Probe streams, metadata and per-bucket packet bitrates for `path`."""
    resolved = path.expanduser().resolve()
    cmd = [
        "ffprobe", "-v", "error",
        "-show_format", "-show_streams", "-show_chapters",
        "-of", "json", str(resolved),
    ]
    proc = subprocess.run(cmd, capture_output=True, text=True, check=True, timeout=30)
    probe_data = json.loads(proc.stdout)
    duration = float((probe_data.get("format") or {}).get("duration") or 0.0)
    bucket_len = max(1.0, round(duration / 60.0, 2)) if duration > 60 else 1.0
    buckets = analyze_packet_hotspots(resolved, bucket_len=bucket_len)
    size_bytes = resolved.stat().st_size if resolved.exists() else 0
    return build_inspection_report(
        probe_data, resolved, size_bytes, buckets, bucket_len,
        decodable=available_decoders(),
    )


def main() -> int:
    parser = argparse.ArgumentParser(description="Inspect video streams, warnings and bitrate curve")
    parser.add_argument("file", help="Path to video file")
    parser.add_argument("--json", action="store_true", help="Output JSON report on stdout")
    args = parser.parse_args()

    target = Path(args.file).expanduser()
    if not target.is_file():
        print(f"Datei nicht gefunden: {target}", file=sys.stderr)
        return 1

    try:
        report = inspect_file(target)
    except (subprocess.SubprocessError, json.JSONDecodeError, OSError) as exc:
        print(f"Analyse fehlgeschlagen: {exc}", file=sys.stderr)
        return 1

    if args.json:
        print(json.dumps(report, ensure_ascii=False))
    else:
        v = report["video"]
        br = report["bitrate"]
        print(f"{report['filename']} ({report['container']}, {report['duration_sec']}s)")
        print(f"  Video: {v['codec']} {v['width']}×{v['height']} @ {v['fps']} fps · {v['hdr_label']}")
        print(f"  Bitrate: avg {br['avg_kbps']} kbit/s, max {br['max_kbps']} kbit/s ({'VBR' if br['is_vbr'] else 'CBR'})")
        for s in report["streams"]:
            status = "übernommen" if s["kept"] else "entfällt"
            print(f"  [{s['index']}] {s['type']} ({s['codec']}) {s['detail']} [{status}]")
        for note in report["warnings"]["dropped"]:
            print(f"  Hinweis: {note}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
