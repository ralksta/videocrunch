"""Unit tests for the savings heuristic (pure math, no ffmpeg, no I/O)."""
import sys
from pathlib import Path

REPO_ROOT = Path(__file__).parent.parent
if str(REPO_ROOT) not in sys.path:
    sys.path.insert(0, str(REPO_ROOT))

from savings import (  # noqa: E402
    bitrate_class,
    estimate_savings_pct,
    resolution_class,
)


class TestClasses:
    def test_bitrate_class_boundaries(self):
        assert bitrate_class(0) == "low"
        assert bitrate_class(2499) == "low"
        assert bitrate_class(2500) == "med"
        assert bitrate_class(7999) == "med"
        assert bitrate_class(8000) == "high"
        assert bitrate_class(19999) == "high"
        assert bitrate_class(20000) == "ultra"

    def test_resolution_class_boundaries(self):
        assert resolution_class(0) == "sd"
        assert resolution_class(576) == "sd"
        assert resolution_class(577) == "720"
        assert resolution_class(800) == "720"
        assert resolution_class(801) == "1080"
        assert resolution_class(1200) == "1080"
        assert resolution_class(1201) == "1440"
        assert resolution_class(1600) == "1440"
        assert resolution_class(1601) == "2160"


class TestEstimateSavingsPct:
    def test_needs_metadata(self):
        assert estimate_savings_pct(0.0, 1080, 30.0, "h264", "hevc") is None
        assert estimate_savings_pct(5000.0, 0, 30.0, "h264", "hevc") is None

    def test_fat_4k_h264_saves_a_lot(self):
        saved, known = estimate_savings_pct(45000.0, 2160, 30.0, "h264", "hevc")
        assert known is True
        assert saved > 60

    def test_lean_1080p_h264_saves_moderately(self):
        saved, _ = estimate_savings_pct(3500.0, 1080, 30.0, "h264", "hevc")
        assert 20 < saved < 50

    def test_same_codec_lean_source_saves_almost_nothing(self):
        # Measured: a 683 kbps 720p HEVC file really only yielded 5.7%.
        saved, _ = estimate_savings_pct(683.0, 720, 25.0, "hevc", "hevc")
        assert saved < 8.0

    def test_same_codec_fat_source_still_worth_it(self):
        saved, _ = estimate_savings_pct(20000.0, 1080, 30.0, "hevc", "hevc")
        assert saved >= 14.0

    def test_unknown_codec_pair_is_flagged(self):
        _, known = estimate_savings_pct(5000.0, 1080, 30.0, "prores", "hevc")
        assert known is False

    def test_av1_target_beats_hevc_target(self):
        av1, _ = estimate_savings_pct(45000.0, 2160, 30.0, "h264", "av1")
        hevc, _ = estimate_savings_pct(45000.0, 2160, 30.0, "h264", "hevc")
        assert av1 >= hevc

    def test_never_predicts_more_than_the_cap(self):
        saved, _ = estimate_savings_pct(500000.0, 2160, 30.0, "mpeg2video", "hevc")
        assert saved <= 85.0

    def test_high_frame_rate_raises_the_reference(self):
        # 60 fps needs more bitrate for the same quality, so a 60 fps source at a
        # given bitrate is comparatively leaner than a 30 fps one.
        sixty, _ = estimate_savings_pct(6000.0, 1080, 60.0, "hevc", "hevc")
        thirty, _ = estimate_savings_pct(6000.0, 1080, 30.0, "hevc", "hevc")
        assert sixty < thirty
