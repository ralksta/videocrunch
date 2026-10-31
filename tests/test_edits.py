"""Edits beyond quality: half the frame rate, no black bars, no audio.

Each is one switch in the app. These tests pin what the switch decides
(which footage it touches) and what reaches ffmpeg.
"""
import shutil
import subprocess
import sys
from pathlib import Path

import pytest

REPO_ROOT = Path(__file__).parent.parent
if str(REPO_ROOT) not in sys.path:
    sys.path.insert(0, str(REPO_ROOT))

import batch  # noqa: E402
from videocrunch import (  # noqa: E402
    ENCODER_PROFILES,
    EditRequest,
    Edits,
    bars_crop,
    build_ffmpeg_command,
    edits_bitrate_scale,
    get_multi_ssim,
    half_frame_rate,
    settle_edits,
)

VT = ENCODER_PROFILES["libx265"]


class TestHalfFrameRate:
    def test_sixty_becomes_thirty(self):
        assert half_frame_rate({"fps_frac": "60/1"}) == "60/2"

    def test_ntsc_rates_stay_exact(self):
        # 59.94 -> 29.97, not a rounded 30 that drifts against the audio.
        assert half_frame_rate({"fps_frac": "60000/1001"}) == "60000/2002"

    def test_fifty_becomes_twenty_five(self):
        assert half_frame_rate({"fps_frac": "50/1"}) == "50/2"

    def test_thirty_has_nothing_to_spare(self):
        assert half_frame_rate({"fps_frac": "30/1"}) is None

    def test_slow_motion_is_left_alone(self):
        # 120/240 fps iPhone footage: those frames are the slow motion.
        assert half_frame_rate({"fps_frac": "120/1"}) is None
        assert half_frame_rate({"fps_frac": "240/1"}) is None

    def test_unknown_rate(self):
        assert half_frame_rate({}) is None


class TestBlackBars:
    def test_letterbox_is_cut(self):
        found = [(1920, 800, 0, 140)] * 5
        assert bars_crop(found, 1920, 1080) == "1920:800:0:140"

    def test_points_disagreeing_keep_everything_any_of_them_saw(self):
        # A dark scene that "detects" a smaller picture cannot cut into a bright one.
        found = [(1920, 800, 0, 140), (1920, 700, 0, 190), (1920, 800, 0, 140)]
        assert bars_crop(found, 1920, 1080) == "1920:800:0:140"

    def test_no_bars_no_crop(self):
        assert bars_crop([(1920, 1072, 0, 4)] * 5, 1920, 1080) is None

    def test_a_dark_video_is_not_all_bars(self):
        assert bars_crop([(640, 360, 640, 360)] * 5, 1920, 1080) is None

    def test_a_black_frame_makes_it_unsure(self):
        # cropdetect on an all-black frame answers with a negative size.
        found = [(1920, 800, 0, 140), (-1904, -1064, 1912, 1072), (1920, 800, 0, 140)]
        assert bars_crop(found, 1920, 1080) is None

    def test_too_few_points(self):
        assert bars_crop([(1920, 800, 0, 140)] * 2, 1920, 1080) is None


class TestSettle:
    def test_nothing_requested(self):
        assert settle_edits(None, {"fps_frac": "60/1"}, "x.mov", VT) == Edits()

    def test_gpu_decoding_keeps_the_bars(self, capsys):
        cuda = {"hwaccel_input": ["-hwaccel", "cuda", "-hwaccel_output_format", "cuda"]}
        edits = settle_edits(EditRequest(crop_bars=True), {}, "x.mov", cuda)
        assert edits.crop is None
        assert "GPU" in capsys.readouterr().out

    def test_fewer_frames_need_fewer_bits(self):
        assert edits_bitrate_scale(Edits(fps="60/2"), {}) < 1

    def test_a_smaller_picture_needs_fewer_bits(self):
        scale = edits_bitrate_scale(Edits(crop="1920:800:0:140"), {"width": 1920, "height": 1080})
        assert abs(scale - 800 / 1080) < 1e-6


class TestCommand:
    def _cmd(self, edits, streams=None):
        return build_ffmpeg_command("in.mov", "out.mp4", VT, 28, audio_mode="standard",
                                    edits=edits, streams=streams)

    def test_crop_and_rate_come_before_the_profile_filters(self):
        cmd = self._cmd(Edits(fps="60/2", crop="1920:800:0:140"))
        vf = cmd[cmd.index("-vf") + 1]
        assert vf.startswith("crop=1920:800:0:140,fps=60/2,")
        assert vf.endswith(VT["video_filter"])

    def test_mute_maps_no_audio(self):
        streams = [{"codec_type": "video", "codec_name": "h264"},
                   {"codec_type": "audio", "codec_name": "aac"},
                   {"codec_type": "audio", "codec_name": "aac"}]
        cmd = self._cmd(Edits(mute=True), streams)
        assert not any(a.startswith("0:a") for a in cmd)
        assert "-c:a" not in cmd

    def test_mute_without_an_inventory(self):
        assert "-an" in self._cmd(Edits(mute=True))

    def test_no_edits_changes_nothing(self):
        assert self._cmd(None) == self._cmd(Edits())


class TestBatchForwards:
    def test_switches_reach_every_file(self):
        args = batch.build_parser().parse_args(
            ["--files", "/a.mov", "--half-fps", "--crop-bars", "--no-audio"])
        cmd = batch.build_optimizer_command("/a.mov", None, "standard",
                                            edit_flags=batch.edit_flags(args))
        assert {"--half-fps", "--crop-bars", "--no-audio"} <= set(cmd)

    def test_unset_switches_are_not_sent(self):
        args = batch.build_parser().parse_args(["--files", "/a.mov"])
        assert batch.edit_flags(args) == ()


HAS_FFMPEG = shutil.which("ffmpeg") is not None


@pytest.mark.skipif(not HAS_FFMPEG, reason="needs ffmpeg")
class TestQualityCheckSeesTheEdit:
    """The SSIM reference gets the same crop and rate as the encode.

    Without that, frame N of a 30 fps encode is compared with frame N of
    the 60 fps source — a different moment — and a fine encode fails.
    """

    def test_a_good_edited_encode_scores_high(self, tmp_path):
        src = tmp_path / "src.mp4"
        subprocess.run(
            ["ffmpeg", "-v", "error", "-f", "lavfi",
             "-i", "testsrc2=duration=3:size=640x272:rate=60",
             "-vf", "pad=640:360:0:44:black", "-c:v", "libx264", "-qp", "0", str(src)],
            check=True)
        edits = Edits(fps="60/2", crop="640:272:0:44")
        out = tmp_path / "out.mp4"
        cmd = build_ffmpeg_command(src, out, VT, 18, audio_mode="standard", edits=edits)
        subprocess.run(cmd, check=True, capture_output=True)
        assert get_multi_ssim(src, out, [0.5], [0.5], 1.5, edits=edits) > 0.97
