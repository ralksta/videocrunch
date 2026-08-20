"""Tests for hardware encoder detection. Requires ffmpeg on PATH."""
import shutil
import sys
from pathlib import Path

import pytest

REPO_ROOT = Path(__file__).parent.parent
if str(REPO_ROOT) not in sys.path:
    sys.path.insert(0, str(REPO_ROOT))

from encoders import (  # noqa: E402
    detect_h264_encoder,
    detect_hevc_optimizer_encoder,
    get_optimal_workers,
)

pytestmark = pytest.mark.skipif(
    shutil.which("ffmpeg") is None, reason="ffmpeg not installed")


def test_detect_h264_encoder_returns_a_usable_pair():
    encoder, extra_args = detect_h264_encoder(log_fn=lambda _: None)
    assert isinstance(encoder, str) and encoder
    assert isinstance(extra_args, list)


def test_detect_hevc_optimizer_encoder_names_a_known_profile():
    key = detect_hevc_optimizer_encoder()
    # 'vaapi' is reachable on Linux (encoders.py:118) and is a real
    # ENCODER_PROFILES key — leaving it out makes this test pass on macOS
    # and fail on a VAAPI box.
    assert key in {"nvenc", "videotoolbox", "qsv", "vaapi", "libx265",
                   "av1_nvenc", "av1_software"}


def test_get_optimal_workers_is_at_least_one():
    assert get_optimal_workers(log_fn=lambda _: None) >= 1
