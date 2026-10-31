"""GIF export (gif.py): the pure decisions, then real runs through ffmpeg.

The app's GIF mode hands one video to gif.py, the way Gifski does: a few
seconds, a width, a frame rate, a quality. gifski makes the GIF where it is
installed; ffmpeg's palette filters stand in where it is not.
"""
import io
import json
import shutil
import subprocess
import sys
from pathlib import Path

import pytest

REPO_ROOT = Path(__file__).parent.parent
if str(REPO_ROOT) not in sys.path:
    sys.path.insert(0, str(REPO_ROOT))

import gif  # noqa: E402

HAS_FFMPEG = shutil.which("ffmpeg") is not None and shutil.which("ffprobe") is not None


class TestOutputPath:
    """The GIF goes next to the video and never replaces anything."""

    def test_named_after_the_video(self, tmp_path):
        src = tmp_path / "Urlaub, Tag 1.mov"
        assert gif.output_path_for(src) == tmp_path / "Urlaub, Tag 1.gif"

    def test_an_existing_gif_is_kept(self, tmp_path):
        src = tmp_path / "clip.mov"
        (tmp_path / "clip.gif").write_bytes(b"GIF89a")
        (tmp_path / "clip 2.gif").write_bytes(b"GIF89a")
        assert gif.output_path_for(src) == tmp_path / "clip 3.gif"


class TestFilters:
    def test_never_upscales(self):
        # A 320 px clip asked for 480 stays 320: bigger is only blurrier and heavier.
        assert "scale=w='min(480,iw)':h=-2" in gif.video_filter(fps=15, width=480, hdr=False)

    def test_frame_rate_comes_first(self):
        # Scaling frames that are then dropped is wasted work.
        vf = gif.video_filter(fps=12, width=480, hdr=False)
        assert vf.index("fps=12") < vf.index("scale=")

    def test_hdr_is_tone_mapped(self):
        # iPhone HLG read as SDR looks grey and washed out in a GIF.
        assert "tonemap_opencl" in gif.video_filter(fps=15, width=480, hdr=True)
        assert "tonemap" not in gif.video_filter(fps=15, width=480, hdr=False)

    def test_ends_in_8_bit_for_the_pipe(self):
        # A 10-bit iPhone clip (or the tone-mapper's NV12) cannot go through y4m.
        for hdr in (True, False):
            assert gif.video_filter(fps=15, width=480, hdr=hdr).endswith("format=yuv420p")

    def test_speed_comes_before_the_frame_rate(self):
        # Twice as fast at 15 fps: every other source frame, still 15 per second.
        vf = gif.video_filter(fps=15, width=480, hdr=False, speed=2)
        assert vf.startswith("setpts=PTS/2,fps=15")

    def test_normal_speed_adds_nothing(self):
        assert "setpts" not in gif.video_filter(fps=15, width=480, hdr=False, speed=1)

    def test_hdr_is_recognised_by_its_transfer(self):
        assert gif.is_hdr({"color_transfer": "arib-std-b67"})
        assert gif.is_hdr({"color_transfer": "smpte2084"})
        assert not gif.is_hdr({"color_transfer": "bt709", "pix_fmt": "yuv420p10le"})


class TestRange:
    def test_whole_clip_without_trim(self):
        assert gif.clip_range(None, None, 12.0) == (0.0, 12.0)

    def test_trim_is_honoured(self):
        assert gif.clip_range("2.5", "6", 12.0) == (2.5, 6.0)

    def test_the_end_never_runs_past_the_video(self):
        assert gif.clip_range("2", "30", 12.0) == (2.0, 12.0)

    def test_the_sample_sits_in_the_middle(self):
        # The start of a clip is often a still frame; it would underestimate.
        assert gif.sample_window(0.0, 10.0, 2.0) == (4.0, 6.0)

    def test_a_short_range_is_its_own_sample(self):
        assert gif.sample_window(1.0, 2.5, 2.0) == (1.0, 2.5)

    def test_frames_follow_the_rate(self):
        assert gif.expected_frames(4.0, 15) == 60


class TestProgress:
    def test_gifski_frame_counter(self):
        text = "Frame 1 / 100  _....  2s \rFrame 37 / 100  ###_...  1s 900KB GIF; "
        assert gif.gifski_frames(text) == 37

    def test_no_counter_yet(self):
        assert gif.gifski_frames("gifski created out.gif") is None

    def test_estimate_scales_with_length(self):
        assert gif.extrapolate(500_000, sample_sec=2.0, total_sec=6.0) == 1_500_000


class TestEvents:
    """--events speaks batch.py's language, so the app reuses its progress view."""

    def test_progress_event(self, monkeypatch):
        out = io.StringIO()
        monkeypatch.setattr(gif, "event_stream", out)
        gif.emit("progress", worker=1, phase="gif", percent=40)
        assert json.loads(out.getvalue()) == {"event": "progress", "worker": 1,
                                              "phase": "gif", "percent": 40}


@pytest.fixture(scope="module")
def clip(tmp_path_factory):
    """3 s, 640x360, with a comma and an umlaut in its name."""
    path = tmp_path_factory.mktemp("gifclips") / "Clip, mit Ümlaut.mp4"
    subprocess.run(
        ["ffmpeg", "-y", "-f", "lavfi", "-i", "testsrc=duration=3:size=640x360:rate=30",
         "-c:v", "libx264", "-preset", "ultrafast", str(path)],
        check=True, capture_output=True)
    return path


@pytest.mark.skipif(not HAS_FFMPEG, reason="needs ffmpeg")
class TestRealExport:

    def _run(self, *args):
        return subprocess.run([sys.executable, str(REPO_ROOT / "gif.py"), *map(str, args)],
                              capture_output=True, text=True, timeout=120)

    def _check(self, clip, tmp_path, *extra):
        out = tmp_path / "out.gif"
        report = tmp_path / "r.json"
        run = self._run(clip, "--width", 200, "--fps", 10, "--ss", 1, "--to", 2.5,
                        "--output", out, "--json-out", report, *extra)
        assert run.returncode == 0, run.stdout + run.stderr
        assert out.read_bytes()[:6] == b"GIF89a"
        result = json.loads(report.read_text())
        assert result["status"] == "success"
        assert result["width"] == 200
        assert result["size_bytes"] == out.stat().st_size
        frames = subprocess.run(
            ["ffprobe", "-v", "error", "-count_frames", "-select_streams", "v:0",
             "-show_entries", "stream=nb_read_frames", "-of", "csv=p=0", str(out)],
            capture_output=True, text=True).stdout.strip()
        assert 13 <= int(frames) <= 17  # 1.5 s at 10 fps
        assert not list(tmp_path.glob("*.part"))

    @pytest.mark.skipif(shutil.which("gifski") is None, reason="needs gifski")
    def test_with_gifski(self, clip, tmp_path):
        self._check(clip, tmp_path)

    def test_with_ffmpeg_alone(self, clip, tmp_path):
        self._check(clip, tmp_path, "--encoder", "ffmpeg")

    def test_twice_as_fast_has_half_the_frames(self, clip, tmp_path):
        out = tmp_path / "fast.gif"
        report = tmp_path / "fast.json"
        run = self._run(clip, "--width", 160, "--fps", 10, "--speed", 2, "--to", 3,
                        "--output", out, "--json-out", report)
        assert run.returncode == 0, run.stdout + run.stderr
        result = json.loads(report.read_text())
        assert result["frames"] == 15
        assert result["duration_sec"] == 1.5
        frames = subprocess.run(
            ["ffprobe", "-v", "error", "-count_frames", "-select_streams", "v:0",
             "-show_entries", "stream=nb_read_frames", "-of", "csv=p=0", str(out)],
            capture_output=True, text=True).stdout.strip()
        assert 13 <= int(frames) <= 17  # 3 s at 2x = 1.5 s at 10 fps

    def test_events_are_json_lines(self, clip, tmp_path):
        run = self._run(clip, "--width", 160, "--fps", 8, "--to", 1,
                        "--output", tmp_path / "e.gif", "--events")
        events = [json.loads(line) for line in run.stdout.splitlines()]
        assert events[0]["event"] == "start"
        assert events[1]["event"] == "file_start"
        assert events[-2]["event"] == "file_done"
        assert events[-2]["status"] == "success"
        assert events[-1] == {**events[-1], "event": "summary", "succeeded": 1, "failed": 0}

    def test_estimate_is_close(self, clip, tmp_path):
        out = tmp_path / "full.gif"
        assert self._run(clip, "--width", 200, "--fps", 10, "--output", out).returncode == 0
        run = self._run(clip, "--width", 200, "--fps", 10, "--estimate")
        estimate = json.loads(run.stdout)
        assert estimate["width"] == 200
        assert 0.5 < estimate["estimated_bytes"] / out.stat().st_size < 1.5
