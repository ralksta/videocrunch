"""crunch_utils.py — pure helper logic for the video optimizer.

Kept free of ffmpeg/subprocess calls so it is unit-testable and importable
by the encode engine and the test suite alike.
"""
from __future__ import annotations

import json
import math
import os
import re
import statistics
import threading
from datetime import datetime
from datetime import time as dtime
from pathlib import Path

DEFAULT_HISTORY_PATH = Path.home() / ".videocrunch" / "logs" / "encode_history.jsonl"


def default_log_dir() -> Path:
    """Return the active log directory, honoring VIDEOCRUNCH_LOG_DIR when set."""
    override = os.environ.get("VIDEOCRUNCH_LOG_DIR", "").strip()
    if override:
        return Path(override).expanduser()
    return Path.home() / ".videocrunch" / "logs"


def resolve_history_path(history_path: Path = DEFAULT_HISTORY_PATH) -> Path:
    """Redirect the default history path into VIDEOCRUNCH_LOG_DIR when overridden."""
    if history_path == DEFAULT_HISTORY_PATH and os.environ.get("VIDEOCRUNCH_LOG_DIR", "").strip():
        return default_log_dir() / "encode_history.jsonl"
    return history_path


# ---------------------------------------------------------------------------
# Encode history — learn the winning starting Q from past encodes
# ---------------------------------------------------------------------------

def bitrate_class(kbps: float) -> str:
    if kbps < 2500:
        return "low"
    if kbps < 8000:
        return "med"
    if kbps < 20000:
        return "high"
    return "ultra"


def resolution_class(height: int) -> str:
    if height <= 576:
        return "sd"
    if height <= 800:
        return "720"
    if height <= 1200:
        return "1080"
    if height <= 1600:
        return "1440"
    return "2160"


def append_encode_history(record: dict, history_path: Path = DEFAULT_HISTORY_PATH) -> None:
    history_path = resolve_history_path(history_path)
    try:
        history_path.parent.mkdir(parents=True, exist_ok=True)
        with open(history_path, "a", encoding="utf-8") as f:
            f.write(json.dumps(record) + "\n")
    except OSError:
        pass  # history is best-effort, never break an encode over it


def suggest_q_from_history(encoder_key: str, height: int, source_kbps: float,
                           history_path: Path = DEFAULT_HISTORY_PATH,
                           min_samples: int = 3, min_ssim: float | None = None) -> int | None:
    """Median winning Q for this (encoder, resolution class, bitrate class) bucket.

    `min_ssim` drops wins that would not count as wins today: records made
    under a laxer quality floor would otherwise keep seeding the search at
    the rung that no longer passes.
    """
    history_path = resolve_history_path(history_path)
    try:
        if not history_path.exists():
            return None
        want = (encoder_key, resolution_class(height), bitrate_class(source_kbps))
        qs = []
        with open(history_path, encoding="utf-8") as f:
            for line in f:
                try:
                    rec = json.loads(line)
                except json.JSONDecodeError:
                    continue
                key = (rec.get("encoder"),
                       resolution_class(int(rec.get("height", 0))),
                       bitrate_class(float(rec.get("source_kbps", 0))))
                if key != want or rec.get("q") is None:
                    continue
                if min_ssim is not None and float(rec.get("ssim") or 0) < min_ssim:
                    continue
                qs.append(int(rec["q"]))
        if len(qs) < min_samples:
            return None
        return int(statistics.median(qs))
    except (OSError, ValueError, TypeError):
        return None


def _as_int_or_zero(value) -> int:
    try:
        return int(value)
    except (TypeError, ValueError):
        return 0


def read_encode_history(history_path: Path = DEFAULT_HISTORY_PATH) -> list:
    """Every readable record in the encode history, oldest first.

    A damaged line — the tail of a run that was killed mid-write — is skipped
    rather than taken as the end of the file: the records before and after it
    are still good.
    """
    history_path = resolve_history_path(history_path)
    records = []
    try:
        with open(history_path, encoding="utf-8") as f:
            for line in f:
                try:
                    records.append(json.loads(line))
                except json.JSONDecodeError:
                    continue
    except OSError:
        return []
    return records


# A pass writes its staging file while the best earlier pass is still on
# disk, and both can approach the size of the source.
STAGING_COPIES_PER_FILE = 2


def disk_headroom_needed(source_bytes: int, files: int = 1) -> int:
    """Bytes that must be free before encoding may start.

    Running out of space mid-encode yields a truncated file: the integrity
    check rejects it, so nothing is lost — but the user sees a row of
    unexplained failures instead of the one sentence that explains them.
    Workers run in parallel, so a batch needs room for every file at once.
    """
    return int(source_bytes) * STAGING_COPIES_PER_FILE * max(1, int(files))


def history_throughput(records: list, height: int | None = None,
                       min_samples: int = 3) -> float | None:
    """Median encode throughput in MB of source per second, or None.

    Measured per resolution class when `height` is given: 4K and 480p move
    very different amounts of data per second, and pooling them produced an
    estimate seven times off. A class with too little history gets None — a
    made-up number is worse than no number, because the user plans around it.
    """
    want_class = resolution_class(height) if height else None
    rates = []
    for rec in records:
        if want_class and resolution_class(_as_int_or_zero(rec.get("height"))) != want_class:
            continue
        try:
            size_mb = float(rec.get("size_mb") or 0)
            duration = float(rec.get("duration") or 0)
        except (TypeError, ValueError):
            continue
        if size_mb > 0 and duration > 0:
            rates.append(size_mb / duration)
    if len(rates) < min_samples:
        return None
    return statistics.median(rates)


def estimate_runtime_sec(total_mb: float, throughput: float | None) -> float | None:
    """Seconds a batch of this size should take at that throughput."""
    if not throughput or throughput <= 0:
        return None
    return total_mb / throughput


def nearest_quality_index(quality_values: list[int], q: int) -> int:
    return min(range(len(quality_values)), key=lambda i: abs(quality_values[i] - q))


def narrow_quality_window(n_values: int, predicted_idx: int, radius: int = 1) -> tuple[int, int]:
    """Clamped (low, high) index window around a pre-search prediction."""
    lo = max(0, predicted_idx - radius)
    hi = min(n_values - 1, predicted_idx + radius)
    return (lo, hi)


# ---------------------------------------------------------------------------
# Worker scheduling / battery awareness
# ---------------------------------------------------------------------------

def parse_schedule(spec: str) -> tuple[dtime, dtime] | None:
    """Parse "HH:MM-HH:MM" into a (start, end) time window. None if invalid."""
    try:
        start_s, end_s = spec.strip().split("-")
        sh, sm = (int(x) for x in start_s.split(":"))
        eh, em = (int(x) for x in end_s.split(":"))
        return (dtime(sh, sm), dtime(eh, em))
    except (ValueError, AttributeError):
        return None


def is_within_schedule(window: tuple[dtime, dtime], now: dtime | None = None) -> bool:
    """True if `now` falls inside the window; handles overnight wrap (22:00-06:00)."""
    if now is None:
        now = datetime.now().time()
    start, end = window
    if start <= end:
        return start <= now <= end
    return now >= start or now <= end


def battery_from_pmset(output: str) -> bool:
    """True if macOS `pmset -g batt` output indicates battery power."""
    return "Battery Power" in output


# ---------------------------------------------------------------------------
# HDR / 10-bit safety
# ---------------------------------------------------------------------------

_HDR_TRANSFERS = {"smpte2084", "arib-std-b67"}  # PQ (HDR10), HLG

# Per-codec 10-bit adjustments; codecs not listed cannot safely encode HDR here.
_HDR_CAPABLE = {
    "hevc_videotoolbox": {"profile": "main10", "pix_fmt": "p010le"},
    "hevc_nvenc":        {"profile": "main10", "pix_fmt": "p010le"},
    "libx265":           {"profile": "main10", "pix_fmt": "yuv420p10le"},
}


def is_hdr(info: dict) -> bool:
    """True when the source carries HDR transfer or BT.2020 wide-gamut primaries.

    10-bit pixel depth alone (e.g. GoPro HERO 10-bit SDR yuv420p10le in BT.709)
    is a container/pixel property, not HDR.
    """
    if str(info.get("color_transfer") or "") in _HDR_TRANSFERS:
        return True
    return str(info.get("color_primaries") or "") == "bt2020"


def is_hdr_or_10bit(info: dict) -> bool:
    pix = str(info.get("pix_fmt") or "")
    if "10" in pix or "12" in pix:
        return True
    return is_hdr(info)


def apply_hdr_adjustments(profile: dict, info: dict) -> dict | None:
    """Return a profile copy adjusted for a 10-bit/HDR source, or None if the
    encoder can't do it safely (caller should skip the file instead of
    silently mistagging BT.2020/PQ content as BT.709)."""
    caps = _HDR_CAPABLE.get(profile.get("codec", ""))
    if not caps:
        return None
    target_profile = caps["profile"]
    target_pix_fmt = caps["pix_fmt"]
    src_pix_fmt = str(info.get("pix_fmt") or "")
    if profile.get("codec") == "hevc_videotoolbox" and ("422p10" in src_pix_fmt or "p210" in src_pix_fmt):
        target_profile = "main42210"
        target_pix_fmt = "p210le"

    adj = dict(profile)
    args = list(profile.get("encoder_args", []))
    if "-profile:v" in args:
        args[args.index("-profile:v") + 1] = target_profile
    else:
        args.extend(["-profile:v", target_profile])
    adj["encoder_args"] = args
    # 8-bit surface format in the filter chain -> 10-bit
    vf = profile.get("video_filter", "")
    for fmt8 in ("yuv420p", "nv12"):
        vf = vf.replace(f"format={fmt8}", f"format={target_pix_fmt}")
    adj["video_filter"] = vf
    # Only pass BT.2020/HDR tags through when the source actually carries HDR/BT.2020;
    # 10-bit SDR (e.g. GoPro 10-bit BT.709) keeps the default BT.709 color tags.
    if is_hdr(info):
        trc = str(info.get("color_transfer") or "smpte2084")
        adj["color_args"] = [
            "-colorspace", "bt2020nc",
            "-color_primaries", "bt2020",
            "-color_trc", trc,
            "-color_range", "tv",
        ]
    return adj


# ---------------------------------------------------------------------------
# Two-pass loudnorm
# ---------------------------------------------------------------------------

LOUDNORM_TARGETS = {"moderate": -19, "enhanced": -16}
LOUDNORM_TP = -1.5
LOUDNORM_LRA = 11.0
ROOM_TONE_FLOOR_LUFS = -40.0

# Pre-chain must be identical between measurement and encode pass so the
# loudnorm measurement reflects the gated/filtered signal it will normalize.
AUDIO_PRE_CHAIN = ("aformat=channel_layouts=stereo,highpass=f=100,"
                   "agate=threshold=-55dB:range=0.05:ratio=2")


def parse_loudnorm_json(stderr_text: str) -> dict | None:
    """Extract the loudnorm measurement JSON block from ffmpeg stderr."""
    matches = re.findall(r"\{[^{}]*\"input_i\"[^{}]*\}", stderr_text, re.DOTALL)
    if not matches:
        return None
    try:
        return json.loads(matches[-1])
    except json.JSONDecodeError:
        return None


def is_room_tone(measured: dict | None, floor_lufs: float = ROOM_TONE_FLOOR_LUFS) -> bool:
    """True when measured integrated loudness is at or below room-tone floor.

    Normalizing ambient noise (<= -40 LUFS) to -19/-16 LUFS boosts the noise
    floor by 20+ dB. Unmeasurable ('-inf') is handled separately as fallback.
    """
    if not measured:
        return False
    try:
        val = float(measured.get("input_i", ""))
    except (TypeError, ValueError):
        return False
    return math.isfinite(val) and val <= floor_lufs


def loudnorm_will_be_linear(measured: dict | None, target_i: float,
                            target_tp: float = LOUDNORM_TP,
                            target_lra: float = LOUDNORM_LRA) -> bool:
    """Whether FFmpeg's af_loudnorm will actually stay in linear mode.

    Even with linear=true, af_loudnorm.c falls back to dynamic mode when the
    linear gain would push true peak above target_tp or measured LRA exceeds
    target_lra.
    """
    if not measured:
        return False
    try:
        mi, mtp, mlra, mth, _ = (
            float(measured[k])
            for k in ("input_i", "input_tp", "input_lra", "input_thresh", "target_offset")
        )
    except (KeyError, TypeError, ValueError):
        return False
    if not all(math.isfinite(x) for x in (mi, mtp, mlra, mth)):
        return False
    if mtp == 99 or mth == -70 or mlra <= 0 or mi == 0:
        return False
    return (mtp + (target_i - mi) <= target_tp) and (mlra <= target_lra)


def build_audio_filter_chain(audio_mode: str, measured: dict | None = None) -> str | None:
    """Audio filter chain for the given mode; None = no filtering (plain AAC).

    With a valid measurement, loudnorm runs in linear (transparent) mode
    instead of the pumping-prone dynamic mode. Room tone (<= -40 LUFS) skips
    normalization so ambient noise is not boosted by 20+ dB.
    """
    target_i = LOUDNORM_TARGETS.get(audio_mode)
    if target_i is None:
        return None
    if is_room_tone(measured):
        return None
    ln = f"loudnorm=I={target_i}:TP={LOUDNORM_TP:g}:LRA={LOUDNORM_LRA:g}"
    if measured:
        keys = ("input_i", "input_tp", "input_lra", "input_thresh", "target_offset")
        vals = {k: str(measured.get(k, "")) for k in keys}
        usable = all(vals[k] not in ("", "-inf", "inf", "nan", "None") for k in keys)
        if usable:
            ln += (f":measured_I={vals['input_i']}:measured_TP={vals['input_tp']}"
                   f":measured_LRA={vals['input_lra']}:measured_thresh={vals['input_thresh']}"
                   f":offset={vals['target_offset']}:linear=true")
    return f"{AUDIO_PRE_CHAIN},{ln}"


# ---------------------------------------------------------------------------
# Stream selection
# ---------------------------------------------------------------------------

# Audio codecs the mp4 muxer can hold as-is. Apple's spatial audio
# (apple_apac) is deliberately absent: it has neither an mp4 tag nor a
# decoder in ffmpeg, so mapping it aborts the whole encode.
MP4_MUXABLE_AUDIO = {
    "aac", "ac3", "eac3", "mp3", "mp2", "alac", "flac", "opus",
}

# Text subtitle codecs that survive conversion to mov_text. Image-based subs
# (PGS, VobSub) cannot be converted and would abort the encode.
MOV_TEXT_SUBTITLES = {"subrip", "srt", "ass", "ssa", "mov_text", "webvtt", "text"}

DEFAULT_AUDIO_KBPS = 192
MIN_AUDIO_KBPS = 48


def audio_bitrate_kbps(streams: list[dict] | None,
                       default_kbps: int = DEFAULT_AUDIO_KBPS) -> int:
    """Target AAC bitrate (kbps), never inflating a compact source track.

    Lossless or high-bitrate sources (PCM, FLAC, AC3 384k) cap at
    `default_kbps` (192k); already-lean tracks (e.g. 64-128k AAC) keep their
    source bitrate down to `MIN_AUDIO_KBPS`.
    """
    rates = []
    for s in streams or []:
        if s.get("codec_type") != "audio":
            continue
        try:
            bps = float(s.get("bit_rate") or 0)
        except (TypeError, ValueError):
            continue
        if bps > 0:
            rates.append(round(bps / 1000))
    if not rates:
        return default_kbps
    return max(MIN_AUDIO_KBPS, min(default_kbps, max(rates)))


def is_attached_pic(stream: dict) -> bool:
    """True when a video stream is an embedded cover/thumbnail picture."""
    disp = stream.get("disposition")
    return isinstance(disp, dict) and bool(disp.get("attached_pic"))


def first_video_stream(streams: list[dict]) -> dict | None:
    """First real video stream, ignoring embedded cover art (attached_pic)."""
    for s in streams or []:
        if s.get("codec_type") == "video" and not is_attached_pic(s):
            return s
    return None


def build_stream_args(streams: list[dict], copy_audio: bool,
                      audio_filters: str | None,
                      decodable: set[str] | None = None,
                      audio_codec: str = "aac") -> tuple[list[str], list[str]]:
    """Map every usable input stream into the output, explicitly.

    Without `-map`, ffmpeg keeps one video and one audio stream and silently
    discards the rest — second language tracks, commentary, subtitles. This
    builds the mapping instead, and returns a note for every stream it had to
    leave behind so the loss is announced rather than hidden.

    Returns (ffmpeg args, notes about skipped streams).

    `decodable` is the set of codec names ffmpeg can decode here; None means
    "assume it can". Data streams (iPhone timecode/metadata tracks) are never
    mapped: the mp4 muxer rejects most of them.
    """
    args: list[str] = ["-map", "0:V:0"]
    skipped: list[str] = []

    audio = [s for s in streams if s.get("codec_type") == "audio"]
    subs = [s for s in streams if s.get("codec_type") == "subtitle"]

    mapped_audio = 0
    for i, stream in enumerate(audio):
        codec = str(stream.get("codec_name") or "")
        if copy_audio:
            usable = codec in MP4_MUXABLE_AUDIO
            why = "mp4 cannot hold it"
        else:
            usable = decodable is None or codec in decodable
            why = "no decoder available"
        if not usable:
            skipped.append(f"audio track {i} ({codec or 'unknown'}): {why}")
            continue
        args.extend(["-map", f"0:a:{i}"])
        mapped_audio += 1

    mapped_subs = 0
    for i, stream in enumerate(subs):
        codec = str(stream.get("codec_name") or "")
        if codec not in MOV_TEXT_SUBTITLES:
            skipped.append(f"subtitle track {i} ({codec or 'unknown'}): not convertible to mov_text")
            continue
        args.extend(["-map", f"0:s:{i}"])
        mapped_subs += 1

    if mapped_audio:
        if copy_audio:
            args.extend(["-c:a", "copy"])
        else:
            audio_kbps = audio_bitrate_kbps(streams)
            args.extend(["-c:a", audio_codec, "-b:a", f"{audio_kbps}k", "-ar", "48000"])
            if audio_filters:
                # Output stream 0, not input: the filter chain belongs to the
                # primary track, and that is whichever track was mapped first.
                args.extend(["-filter:a:0", audio_filters])
    if mapped_subs:
        args.extend(["-c:s", "mov_text"])

    data = [s for s in streams if s.get("codec_type") == "data"]
    if data:
        names = sorted({str(s.get("codec_name") or s.get("codec_tag_string") or "unknown")
                        for s in data})
        noun = "data track" if len(data) == 1 else "data tracks"
        skipped.append(f"{len(data)} {noun} ({', '.join(names)}): metadata mp4 cannot hold")

    return (args, skipped)


# What a Dolby Vision file's base layer is, by dv_bl_signal_compatibility_id.
# 0 means none: profile 5's IPT-PQ-c2 base layer only looks right after the
# Dolby Vision processing an ffmpeg re-encode does not do.
_DV_BASE_LAYER = {1: "HDR10", 2: "SDR", 4: "HLG", 6: "HDR10"}


def dolby_vision_info(side_data: list) -> dict | None:
    """Dolby Vision profile and what a re-encode keeps of it, or None.

    The encoders here write no Dolby Vision metadata, so a re-encode keeps
    only the base layer: `kept_as` names it ("HLG" for iPhone footage), or is
    None when there is no usable base layer at all.
    """
    for entry in side_data or []:
        if entry.get("side_data_type") != "DOVI configuration record":
            continue
        profile = entry.get("dv_profile")
        compat = entry.get("dv_bl_signal_compatibility_id")
        label = f"{profile}.{compat}" if compat else f"{profile}"
        return {"profile": label, "kept_as": _DV_BASE_LAYER.get(compat)}
    return None


# ---------------------------------------------------------------------------
# Scene-aware SSIM sample selection
# ---------------------------------------------------------------------------

def select_top_windows(bucket_bytes: dict[int, int], duration: float, n: int = 3,
                       window: float = 3.0, bucket_len: float = 5.0) -> list[float]:
    """Pick the highest-bitrate bucket in each of n equal regions of the video.

    High packet density = high motion/complexity = where compression artifacts
    live. Fixed 25/50/75%% points can land on static menus and overestimate
    quality. Falls back to those percentages when no packet data exists.
    Returns sorted, de-duplicated window start times clamped into the video.
    """
    max_start = max(0.0, duration - window - 0.5)

    def _fallback() -> list[float]:
        return sorted({min(duration * p, max_start) for p in (0.25, 0.50, 0.75)})[:n]

    if not bucket_bytes or duration <= 0:
        return _fallback()

    region_len = duration / n
    starts: set = set()
    for r in range(n):
        lo_t, hi_t = r * region_len, (r + 1) * region_len
        lo_b = int(lo_t / bucket_len)
        hi_b = max(lo_b + 1, int(hi_t / bucket_len))
        candidates = {b: sz for b, sz in bucket_bytes.items() if lo_b <= b < hi_b}
        if candidates:
            best_bucket = max(candidates, key=candidates.get)
            starts.add(max(0.0, min(best_bucket * bucket_len, max_start)))
        else:
            starts.add(max(0.0, min(lo_t + region_len / 2, max_start)))
    return sorted(starts)[:n]


# ---------------------------------------------------------------------------
# Rate control
# ---------------------------------------------------------------------------

# A pass may peak at this multiple of its own average target before the
# encoder is reined in. 2x leaves room for I-frames and hotspots while
# keeping the pass anywhere near the size it is aiming for.
PASS_MAXRATE_FACTOR = 2.0


def clamp_maxrate_to_pass(maxrate_kbps: float | None, bufsize_kbps: float | None,
                          target_bitrate_kbps: float | None,
                          factor: float = PASS_MAXRATE_FACTOR) -> tuple:
    """Tighten a file-wide peak cap down to what THIS pass is aiming for.

    The file-wide maxrate comes from analysing the source, so it sits far above
    the individual quality-ladder targets. Left alone, the encoder is free to
    spend several times a pass's target bitrate in busy scenes and overshoot the
    size goal — which makes the ladder rungs nearly indistinguishable.

    Returns (maxrate, bufsize); passes the originals straight through when
    there is no per-pass target to clamp against.
    """
    if not target_bitrate_kbps or target_bitrate_kbps <= 0:
        return maxrate_kbps, bufsize_kbps
    cap = target_bitrate_kbps * factor
    if maxrate_kbps and maxrate_kbps > 0:
        cap = min(maxrate_kbps, cap)
    if maxrate_kbps and cap >= maxrate_kbps:
        return maxrate_kbps, bufsize_kbps  # file-wide cap already tighter
    return cap, cap * 2.0


_LIVE_SPEED_RE = re.compile(r"^(\d+(?:\.\d+)?)x$", re.IGNORECASE)
_LIVE_BITRATE_RE = re.compile(
    r"^(\d+(?:\.\d+)?)\s*(kbits/s|kb/s|mbits/s|mb/s|m|k)$", re.IGNORECASE
)


def valid_live_speed(raw: str | None) -> str | None:
    """Return a positive encoder speed token (e.g. '3.1x'), or None if zero/invalid."""
    if not raw:
        return None
    token = raw.strip()
    m = _LIVE_SPEED_RE.match(token)
    if not m or float(m.group(1)) <= 0:
        return None
    return token


def valid_live_bitrate(raw: str | None) -> str | None:
    """Return a positive encoder bitrate token (e.g. '6420kbits/s'), or None."""
    if not raw:
        return None
    token = raw.strip()
    m = _LIVE_BITRATE_RE.match(token)
    if not m or float(m.group(1)) <= 0:
        return None
    return token


def drain_pipe_async(stream):
    """Drain a subprocess pipe on a daemon thread to prevent 64 KB two-pipe deadlocks."""
    chunks = []
    if stream is None or not hasattr(stream, "read"):
        return None, chunks

    def _reader():
        try:
            data = stream.read()
            if data:
                chunks.append(data)
        except (OSError, ValueError):
            pass

    thread = threading.Thread(target=_reader, daemon=True)
    thread.start()
    return thread, chunks


def finish_pipe_drain(thread, chunks, *, is_bytes: bool = False):
    """Wait briefly for a drain thread and return the collected output."""
    if thread is not None:
        thread.join(timeout=5.0)
    return b"".join(chunks) if is_bytes else "".join(chunks)
