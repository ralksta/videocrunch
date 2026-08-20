"""Savings heuristic — how much would re-encoding this file gain?

Pure math, no I/O, no ffmpeg. Answers "is this file worth encoding at all"
before any encoder starts, and ranks folders in scan.py.

The same math lives in arcade-video-scanner's optimization_advisor.py, which
feeds its dashboard candidate list. The two copies are pinned to identical
behaviour by savings_parity.json, committed to both repos — see the parity
test. Change the math here and that test fails on both sides, which is the
point: neither project has to import the other.

The fixture covers estimate_savings_pct, bitrate_class and resolution_class,
plus scan.py's MIN_LISTED_SAVED_PCT listing threshold — everything duplicated
across the two repos. Anything you add here that the other copy also carries
belongs in the fixture too, or it drifts unnoticed.
"""
from typing import Optional

# Bitrate multiplier for the same perceived quality when going source -> target.
# 0.65 means "HEVC needs 65% of the bitrate H.264 needed".
CODEC_EFFICIENCY: dict = {
    ("h264", "hevc"):  0.65,
    ("h264", "h265"):  0.65,
    ("h264", "av1"):   0.55,
    ("hevc", "h264"):  1.40,
    ("h265", "h264"):  1.40,
    ("hevc", "av1"):   0.80,
    ("h265", "av1"):   0.80,
    ("av1",  "h264"):  1.70,
    ("av1",  "hevc"):  1.25,
    ("av1",  "h265"):  1.25,
    ("mpeg4", "h264"): 0.60,
    ("mpeg4", "hevc"): 0.45,
    ("mpeg2video", "h264"): 0.50,
    ("mpeg2video", "hevc"): 0.35,
    ("vp8",  "h264"):  0.75,
    ("vp9",  "hevc"):  0.90,
    ("vp9",  "h264"):  1.10,
}

# Reference bitrates (kbps) for a well-compressed HEVC encode at ~30 fps.
_REF_KBPS = {"sd": 1500.0, "720": 2500.0, "1080": 4000.0, "1440": 8000.0, "2160": 12000.0}
_AV1_REF_FACTOR = 0.85    # AV1 hits the same quality a bit leaner
_SAME_CODEC_EFF = 0.85    # re-encoding within the same codec gains little
_DEFAULT_EFF = 0.65       # unknown source codec: assume h264-like gains
_MAX_SAVED_PCT = 85.0     # never predict more than this
_TARGET_ALIASES = {"hevc": {"hevc", "h265"}, "av1": {"av1"}}


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


def _is_same_codec(source_codec: str, target_codec: str) -> bool:
    """True when re-encoding `source_codec` to `target_codec` is a same-codec pass."""
    src = (source_codec or "").lower()
    return src in _TARGET_ALIASES.get(target_codec, {target_codec})


def _codec_efficiency(source_codec: str, target_codec: str) -> tuple:
    """(bitrate multiplier source->target, is the pair actually known?, is_same_codec)."""
    if _is_same_codec(source_codec, target_codec):
        return _SAME_CODEC_EFF, True, True
    src = (source_codec or "").lower()
    eff = CODEC_EFFICIENCY.get((src, target_codec))
    if eff is not None:
        return eff, True, False
    return _DEFAULT_EFF, False, False


def _reference_kbps(height: int, target_codec: str, fps: float) -> float:
    """Reference bitrate (kbps) for a clean target-codec encode at this resolution/fps."""
    ref = _REF_KBPS[resolution_class(height)]
    if target_codec == "av1":
        ref *= _AV1_REF_FACTOR
    if fps > 0:
        ref *= min(max(fps / 30.0, 0.5), 2.0)
    return ref


def estimate_savings_pct(source_kbps: float, height: int, fps: float,
                         source_codec: str, target_codec: str) -> Optional[tuple]:
    """Estimated saved percentage (0-100) for re-encoding.

    Returns (saved_pct, known_codec_pair) or None when the inputs are too
    incomplete to say anything (no bitrate or no height from ffprobe).
    """
    if source_kbps <= 0 or height <= 0:
        return None

    eff, known, is_same_codec = _codec_efficiency(source_codec or "", target_codec)
    ref = _reference_kbps(height, target_codec, fps or 0.0)

    if is_same_codec:
        # Same-codec: apply efficiency without ref cap (already efficiently encoded).
        # How much is left depends on how fat the source is RELATIVE to a clean
        # encode at this resolution. A source already far below `ref` has been
        # squeezed once; a second pass in the same codec gets almost nothing
        # (measured: a 683 kbps 720p HEVC file yielded 5.7%, not the flat 15%
        # `eff` implies). Scale the gain by source/ref so leanness is priced in.
        leanness = min(1.0, source_kbps / ref) if ref > 0 else 1.0
        effective_eff = 1.0 - (1.0 - eff) * leanness
        predicted_kbps = source_kbps * effective_eff
        predicted_kbps = max(predicted_kbps, source_kbps * (1 - _MAX_SAVED_PCT / 100))
    else:
        # Different-codec: cap at reference rate
        predicted_kbps = min(source_kbps * eff, max(ref, source_kbps * (1 - _MAX_SAVED_PCT / 100)))

    saved_pct = max(0.0, (1.0 - predicted_kbps / source_kbps) * 100.0)
    return min(saved_pct, _MAX_SAVED_PCT), known
