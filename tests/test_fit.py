"""fit.py: under a size limit, the best picture that fits.

The bitrate follows from the limit and the length; the resolution follows
from the bitrate. Too long for the limit is said, not attempted.
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

import fit  # noqa: E402

HAS_FFMPEG = shutil.which("ffmpeg") is not None


class TestBudget:
    def test_audio_comes_off_the_top(self):
        # 25 MB over 60 s with one 192k track.
        kbps = fit.video_kbps_for(25e6, 60, 192)
        assert kbps == pytest.approx(25e6 * 8 * fit.OVERHEAD / 60 / 1000 - 192)

    def test_a_short_clip_keeps_its_resolution(self):
        assert fit.pick_short_side(20000, 3840, 2160, 30) == 2160

    def test_less_bitrate_means_fewer_pixels(self):
        # ~1 Mbit/s for 4K30 is mush; 720p it can carry.
        assert fit.pick_short_side(1000, 3840, 2160, 30) <= 720

    def test_vertical_video_by_its_short_side(self):
        assert fit.pick_short_side(20000, 1080, 1920, 30) == 1080

    def test_never_upscales(self):
        assert fit.pick_short_side(50000, 640, 360, 30) == 360

    def test_too_long_is_said(self):
        p = fit.plan(10e6, 3600, {"width": 1920, "height": 1080, "fps": 30}, 1)
        assert "zu lang" in p["error"]

    def test_sixty_fps_is_halved_before_going_below_360p(self):
        info = {"width": 1920, "height": 1080, "fps": 60, "fps_frac": "60/1"}
        kbps = 360 * 640 * 30 * fit.MIN_BPP / 1000 * 1.1  # 360p fits at 30, not at 60
        seconds = 100
        p = fit.plan((kbps * 1000 * seconds / 8 + 0) / fit.OVERHEAD, seconds, info, 0)
        assert p["fps"] == "60/2"


class TestOutputName:
    def test_named_after_the_limit(self, tmp_path):
        assert fit.output_path_for(tmp_path / "Urlaub, Tag 1.mov", 25) == tmp_path / "Urlaub, Tag 1_25MB.mp4"

    def test_never_replaces(self, tmp_path):
        (tmp_path / "a_25MB.mp4").write_bytes(b"x")
        assert fit.output_path_for(tmp_path / "a.mov", 25) == tmp_path / "a_25MB 2.mp4"


@pytest.mark.skipif(not HAS_FFMPEG, reason="needs ffmpeg")
class TestRealRun:
    def test_comes_in_under_the_limit(self, tmp_path):
        src = tmp_path / "Clip, groß.mp4"
        subprocess.run(
            ["ffmpeg", "-v", "error", "-f", "lavfi", "-i", "testsrc2=duration=6:size=1280x720:rate=30",
             "-f", "lavfi", "-i", "sine=duration=6", "-vf", "noise=alls=20:allf=t",
             "-c:v", "libx264", "-b:v", "8M", "-c:a", "aac", "-shortest", str(src)],
            check=True)
        assert src.stat().st_size > 2e6
        report = tmp_path / "r.json"
        run = subprocess.run([sys.executable, str(REPO_ROOT / "fit.py"), str(src), "--max-mb", "1",
                              "--json-out", str(report), "--events"],
                             capture_output=True, text=True, timeout=300)
        assert run.returncode == 0, run.stdout + run.stderr
        result = json.loads(report.read_text())["results"][0]
        assert result["status"] == "success"
        out = Path(result["output_path"])
        assert out.stat().st_size <= 1e6
        assert not list(tmp_path.glob(".*part*"))
        events = [json.loads(line) for line in run.stdout.splitlines() if line.startswith("{")]
        assert events[0]["event"] == "start"
        assert events[-1]["event"] == "summary" and events[-1]["succeeded"] == 1

    def test_already_small_enough_is_skipped(self, tmp_path):
        src = tmp_path / "klein.mp4"
        subprocess.run(["ffmpeg", "-v", "error", "-f", "lavfi", "-i", "testsrc2=duration=2:size=320x180",
                        "-c:v", "libx264", str(src)], check=True)
        run = subprocess.run([sys.executable, str(REPO_ROOT / "fit.py"), str(src), "--max-mb", "25"],
                             capture_output=True, text=True, timeout=120)
        assert run.returncode == 0
        assert "skipped" in run.stdout
        assert not (tmp_path / "klein_25MB.mp4").exists()
