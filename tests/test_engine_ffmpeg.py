"""
test_optimizer_ffmpeg.py
------------------------
Integration tests for the ffmpeg-invoking optimizer helpers (output
integrity verification, probe clip extraction). Skipped entirely when
ffmpeg/ffprobe are not on PATH.
"""
import json
import shutil
import subprocess
import sys
from pathlib import Path

import pytest

REPO_ROOT = Path(__file__).parent.parent
if str(REPO_ROOT) not in sys.path:
    sys.path.insert(0, str(REPO_ROOT))

pytestmark = pytest.mark.skipif(
    shutil.which("ffmpeg") is None or shutil.which("ffprobe") is None,
    reason="ffmpeg/ffprobe not installed",
)


@pytest.fixture(scope="module")
def tiny_clip(tmp_path_factory):
    """2s synthetic H.264 clip with audio."""
    path = tmp_path_factory.mktemp("clips") / "tiny.mp4"
    subprocess.run(
        ["ffmpeg", "-y", "-f", "lavfi", "-i", "testsrc=duration=2:size=320x240:rate=24",
         "-f", "lavfi", "-i", "sine=frequency=440:duration=2",
         "-c:v", "libx264", "-preset", "ultrafast", "-c:a", "aac",
         "-shortest", str(path)],
        check=True, capture_output=True,
    )
    return path


class TestGetVideoInfo:
    def test_returns_real_stream_fields(self, tiny_clip):
        # Regression: codec_type must be in -show_entries or the video-stream
        # lookup silently fails and width/height/pix_fmt are always empty.
        from videocrunch import get_video_info
        info = get_video_info(tiny_clip)
        assert info["width"] == 320
        assert info["height"] == 240
        assert info["codec"] == "h264"
        assert info["pix_fmt"] != ""

    def test_10bit_clip_detected_as_hdr(self, tmp_path):
        from crunch_utils import is_hdr_or_10bit
        from videocrunch import get_video_info
        clip = tmp_path / "ten_bit.mp4"
        subprocess.run(
            ["ffmpeg", "-y", "-f", "lavfi", "-i", "testsrc=duration=1:size=320x240:rate=24",
             "-c:v", "libx264", "-preset", "ultrafast", "-pix_fmt", "yuv420p10le", str(clip)],
            check=True, capture_output=True,
        )
        info = get_video_info(clip)
        assert is_hdr_or_10bit(info) is True

    def test_rotated_clip_swaps_width_and_height(self):
        from unittest.mock import patch

        from videocrunch import get_video_info
        mock_stdout = {
            "format": {"duration": "10.0"},
            "streams": [{
                "codec_type": "video",
                "width": 3840,
                "height": 2160,
                "codec_name": "hevc",
                "r_frame_rate": "60/1",
                "pix_fmt": "yuv420p",
                "side_data_list": [{"rotation": -90}],
            }]
        }
        with patch("subprocess.run") as mock_run:
            mock_run.return_value.stdout = json.dumps(mock_stdout)
            info = get_video_info(Path("/dummy.mov"))
            assert info["width"] == 2160
            assert info["height"] == 3840
            assert info["rotation"] == -90


@pytest.fixture(scope="module")
def drifting_pair(tmp_path_factory):
    """A reference clip and an encode of it whose timestamp grid slowly drifts.

    Real-world case: iPhone 120 fps clips carry a 1/2400 timebase whose frame
    timestamps creep away from the encoder's 1/15360 output grid. Frame N holds
    the same picture in both files, but its presentation time does not match.
    Content is per-frame random noise, so any misalignment by even one frame
    drops the score to near zero while a correct comparison scores 1.0.
    """
    d = tmp_path_factory.mktemp("drift")
    ref, enc = d / "ref.mp4", d / "enc.mp4"
    subprocess.run(
        ["ffmpeg", "-y", "-v", "error",
         "-f", "lavfi", "-i", "color=black:s=96x72:r=120:d=3,geq=random(1)*255:128:128",
         "-c:v", "libx264", "-qp", "0", "-pix_fmt", "yuv420p",
         "-video_track_timescale", "2400", str(ref)],
        check=True, capture_output=True,
    )
    subprocess.run(
        ["ffmpeg", "-y", "-v", "error", "-i", str(ref),
         "-vf", "setpts=PTS*1.01",
         "-c:v", "libx264", "-qp", "0", "-pix_fmt", "yuv420p",
         "-video_track_timescale", "15360", "-fps_mode", "passthrough", str(enc)],
        check=True, capture_output=True,
    )
    return ref, enc


class TestGetMultiSsim:
    def test_drifting_timestamps_still_compare_the_same_frames(self, drifting_pair):
        # The encode is lossless: every sample must score 1.0. Anything less
        # means the filter paired frame N of the reference with a different
        # frame of the encode.
        from videocrunch import get_multi_ssim
        ref, enc = drifting_pair
        score = get_multi_ssim(ref, enc, [2.0], [2.0], 0.5)
        assert score > 0.99


class TestVerifyIntegrity:
    def test_valid_file_passes(self, tiny_clip):
        from videocrunch import verify_output_integrity
        ok, reason = verify_output_integrity(tiny_clip, expected_duration=2.0)
        assert ok, reason

    def test_wrong_duration_fails(self, tiny_clip):
        from videocrunch import verify_output_integrity
        ok, reason = verify_output_integrity(tiny_clip, expected_duration=60.0)
        assert not ok
        assert "duration" in reason.lower()

    def test_truncated_file_fails(self, tiny_clip, tmp_path):
        from videocrunch import verify_output_integrity
        broken = tmp_path / "broken.mp4"
        data = tiny_clip.read_bytes()
        broken.write_bytes(data[: len(data) // 3])
        ok, _reason = verify_output_integrity(broken, expected_duration=2.0)
        assert not ok

    def test_promote_staging_renames_on_success(self, tiny_clip, tmp_path):
        from videocrunch import promote_staging
        staging = tmp_path / "s.mp4"
        shutil.copy(tiny_clip, staging)
        out = tmp_path / "final.mp4"
        assert promote_staging(staging, out, expected_duration=2.0) is True
        assert out.exists() and not staging.exists()

    def test_promote_staging_refuses_broken_file(self, tiny_clip, tmp_path):
        from videocrunch import promote_staging
        staging = tmp_path / "s.mp4"
        data = tiny_clip.read_bytes()
        staging.write_bytes(data[: len(data) // 3])
        out = tmp_path / "final.mp4"
        assert promote_staging(staging, out, expected_duration=2.0) is False
        assert not out.exists() and not staging.exists()

    def test_output_with_a_missing_audio_track_is_rejected(self, tiny_clip):
        # The encode plans how many tracks it carries over; an output that
        # comes back with fewer lost data on the way and must never replace
        # anything. Duration and decode alone would wave this through.
        from videocrunch import verify_output_integrity
        ok, reason = verify_output_integrity(tiny_clip, expected_duration=2.0,
                                             expected_audio=2)
        assert ok is False
        assert "audio" in reason

    def test_output_with_the_planned_tracks_passes(self, tiny_clip):
        from videocrunch import verify_output_integrity
        ok, _ = verify_output_integrity(tiny_clip, expected_duration=2.0,
                                        expected_audio=1)
        assert ok is True


@pytest.fixture(scope="module")
def long_clip(tmp_path_factory):
    """30s synthetic clip for probe extraction."""
    path = tmp_path_factory.mktemp("clips") / "long.mp4"
    subprocess.run(
        ["ffmpeg", "-y", "-f", "lavfi", "-i", "testsrc=duration=30:size=320x240:rate=24",
         "-c:v", "libx264", "-preset", "ultrafast", "-g", "24", str(path)],
        check=True, capture_output=True,
    )
    return path


class TestProbeExtraction:
    def test_probe_is_short_and_valid(self, long_clip, tmp_path):
        from videocrunch import extract_probe_clip, get_video_info
        probe = extract_probe_clip(long_clip, [2.0, 12.0, 22.0], segment_sec=4.0, work_dir=tmp_path)
        assert probe is not None and probe.exists()
        info = get_video_info(probe)
        assert 6.0 <= info["duration"] <= 18.0  # ~3x4s, keyframe-aligned slack

    def test_probe_segments_cleaned_up(self, long_clip, tmp_path):
        from videocrunch import extract_probe_clip
        extract_probe_clip(long_clip, [2.0, 12.0, 22.0], segment_sec=4.0, work_dir=tmp_path)
        leftovers = list(tmp_path.glob("_probe_seg*")) + list(tmp_path.glob("_probe_list*"))
        assert leftovers == []

    def test_missing_input_returns_none(self, tmp_path):
        from videocrunch import extract_probe_clip
        probe = extract_probe_clip(tmp_path / "nope.mp4", [1.0], segment_sec=4.0, work_dir=tmp_path)
        assert probe is None


@pytest.fixture(scope="module")
def multi_track_clip(tmp_path_factory):
    """A clip with two audio tracks and a capture date, like a real recording."""
    path = tmp_path_factory.mktemp("tracks") / "two_tracks.mp4"
    subprocess.run(
        ["ffmpeg", "-y", "-v", "error",
         "-f", "lavfi", "-i", "testsrc2=duration=2:size=320x240:rate=30",
         "-f", "lavfi", "-i", "sine=frequency=440:duration=2",
         "-f", "lavfi", "-i", "sine=frequency=880:duration=2",
         "-map", "0:v", "-map", "1:a", "-map", "2:a",
         "-c:v", "libx264", "-preset", "ultrafast", "-c:a", "aac",
         "-metadata", "creation_time=2024-10-10T13:44:56.000000Z",
         str(path)],
        check=True, capture_output=True,
    )
    return path


def _probe(path, entries):
    out = subprocess.run(
        ["ffprobe", "-v", "error", "-show_entries", entries, "-of", "json", str(path)],
        check=True, capture_output=True, text=True,
    )
    return json.loads(out.stdout)


class TestStreamPreservation:
    """Every track and the capture date must survive the encode.

    ffmpeg's default stream selection keeps one audio track and drops the
    rest; container metadata is not carried over at all unless asked for. For
    a tool pointed at someone's video library, both are silent data loss.
    """

    def _encode(self, clip, out):
        from videocrunch import (
            ENCODER_PROFILES,
            build_ffmpeg_command,
            probe_stream_inventory,
        )
        cmd = build_ffmpeg_command(
            clip, out, ENCODER_PROFILES["libx265"], 28,
            audio_mode="standard", streams=probe_stream_inventory(clip),
        )
        subprocess.run(cmd, check=True, capture_output=True)

    def test_both_audio_tracks_survive(self, multi_track_clip, tmp_path):
        out = tmp_path / "out.mp4"
        self._encode(multi_track_clip, out)
        kinds = [s["codec_type"] for s in _probe(out, "stream=codec_type")["streams"]]
        assert kinds.count("audio") == 2

    def test_capture_date_survives(self, multi_track_clip, tmp_path):
        out = tmp_path / "out.mp4"
        self._encode(multi_track_clip, out)
        source = _probe(multi_track_clip, "format_tags=creation_time")["format"]["tags"]
        result = _probe(out, "format_tags=creation_time")["format"].get("tags", {})
        assert result.get("creation_time", "").startswith(source["creation_time"][:19])


class TestResumableStaging:
    """A pass that finished before the run was interrupted can be reused.

    Encoding 4K takes minutes per pass; throwing completed passes away
    because the user pressed Ctrl-C between them means paying for them twice.
    What must never be reused is a half-written file — it would be judged as
    if it were the finished encode.
    """

    def test_a_finished_pass_is_reusable(self, tiny_clip):
        from videocrunch import reusable_staging
        assert reusable_staging(tiny_clip, expected_duration=2.0, expected_audio=1) is True

    def test_a_half_written_file_is_not(self, tiny_clip, tmp_path):
        from videocrunch import reusable_staging
        # An encode killed mid-write has no moov atom; judging it would
        # compare a fraction of the video against the whole source.
        partial = tmp_path / "partial.mp4"
        data = tiny_clip.read_bytes()
        partial.write_bytes(data[: len(data) // 3])
        assert reusable_staging(partial, expected_duration=2.0, expected_audio=1) is False

    def test_a_missing_file_is_not(self, tmp_path):
        from videocrunch import reusable_staging
        assert reusable_staging(tmp_path / "gone.mp4", expected_duration=2.0,
                                expected_audio=1) is False

    def test_an_empty_file_is_not(self, tmp_path):
        from videocrunch import reusable_staging
        empty = tmp_path / "empty.mp4"
        empty.touch()
        assert reusable_staging(empty, expected_duration=2.0, expected_audio=1) is False


class TestProgressCallback:
    """scripts/mac_worker.py passes a callback so it can report encode
    progress upstream; the local CLI passes none."""

    def test_process_file_accepts_a_progress_callback(self):
        import inspect

        from videocrunch import process_file
        params = inspect.signature(process_file).parameters
        assert params["progress_callback"].default is None
        # Positional callers (mac_worker, main) must keep working.
        assert list(params).index("progress_callback") == len(params) - 1

    def test_a_broken_callback_never_kills_the_encode(self):
        from videocrunch import _report_progress

        def boom(*_args):
            raise RuntimeError("callback exploded")

        _report_progress(boom, 1.0, 2.0, "encode")  # must not raise

    def test_no_callback_is_a_no_op(self):
        from videocrunch import _report_progress
        _report_progress(None, 1.0, 2.0, "encode")

    def test_the_callback_receives_position_duration_and_label(self):
        from videocrunch import _report_progress
        seen = []
        _report_progress(lambda *a: seen.append(a), 30, 60, "encode Q=60")
        assert seen == [(30.0, 60.0, "encode Q=60")]
