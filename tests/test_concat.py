"""Tests for concat.py — lossless stream-copy concatenation."""
import json
import shutil
import subprocess
import sys
from pathlib import Path

import pytest

REPO_ROOT = Path(__file__).parent.parent
if str(REPO_ROOT) not in sys.path:
    sys.path.insert(0, str(REPO_ROOT))

import concat  # noqa: E402

HAS_FFMPEG = shutil.which("ffmpeg") is not None and shutil.which("ffprobe") is not None


class TestCompatibility:
    def _info(self, codec="h264", width=1920, height=1080, pix_fmt="yuv420p",
              color_transfer="bt709", color_primaries="bt709"):
        return {
            "codec": codec, "width": width, "height": height, "pix_fmt": pix_fmt,
            "color_transfer": color_transfer, "color_primaries": color_primaries,
            "duration": 10.0,
        }

    def test_requires_at_least_two_clips(self):
        ok, reason = concat.check_concat_compatibility([self._info()])
        assert not ok
        assert "zwei" in reason.lower()

    def test_matching_clips_are_compatible(self):
        ok, reason = concat.check_concat_compatibility([self._info(), self._info()])
        assert ok is True
        assert reason is None

    def test_rejects_codec_mismatch(self):
        ok, reason = concat.check_concat_compatibility([self._info("h264"), self._info("hevc")])
        assert not ok
        assert "Codec" in reason

    def test_rejects_resolution_mismatch(self):
        ok, reason = concat.check_concat_compatibility(
            [self._info(width=1920, height=1080), self._info(width=3840, height=2160)]
        )
        assert not ok
        assert "Auflösung" in reason

    def test_rejects_mixed_sdr_and_hdr(self):
        hdr = self._info(pix_fmt="yuv420p10le", color_transfer="arib-std-b67", color_primaries="bt2020")
        ok, reason = concat.check_concat_compatibility([self._info(), hdr])
        assert not ok
        assert "HDR" in reason


class TestConcatListAndNaming:
    def test_escapes_single_quotes_and_spaces(self, tmp_path):
        clip = tmp_path / "Urlaub '26, Tag 1.mp4"
        clip.touch()
        listing = concat.format_concat_list([clip])
        assert listing.startswith("file '")
        assert "'\\''26, Tag 1.mp4'\n" in listing

    def test_output_path_never_overwrites(self, tmp_path):
        first = tmp_path / "clip.mov"
        assert concat.output_path_for(first) == tmp_path / "clip_merged.mp4"
        (tmp_path / "clip_merged.mp4").write_bytes(b"existing")
        assert concat.output_path_for(first) == tmp_path / "clip_merged 2.mp4"


@pytest.mark.skipif(not HAS_FFMPEG, reason="needs ffmpeg/ffprobe")
def test_real_concat_merges_without_reencoding(tmp_path):
    clips = []
    for idx, freq in enumerate((440, 880), start=1):
        p = tmp_path / f"part{idx}.mp4"
        subprocess.run(
            ["ffmpeg", "-y", "-v", "error",
             "-f", "lavfi", "-i", "testsrc2=duration=2:size=320x240:rate=24",
             "-f", "lavfi", "-i", f"sine=frequency={freq}:duration=2",
             "-c:v", "libx264", "-preset", "ultrafast", "-c:a", "aac", "-shortest", str(p)],
            check=True,
        )
        clips.append(p)

    report = tmp_path / "merge.json"
    run = subprocess.run(
        [sys.executable, str(REPO_ROOT / "concat.py"),
         str(clips[0]), str(clips[1]),
         "--json-out", str(report), "--events"],
        capture_output=True, text=True, timeout=60,
    )
    assert run.returncode == 0, run.stdout + run.stderr
    res = json.loads(report.read_text())["results"][0]
    assert res["status"] == "success"
    out = Path(res["output_path"])
    assert out.name == "part1_merged.mp4"
    assert out.exists()

    probed = json.loads(subprocess.run(
        ["ffprobe", "-v", "error", "-show_entries", "format=duration:stream=codec_name",
         "-of", "json", str(out)],
        capture_output=True, text=True, check=True,
    ).stdout)
    assert float(probed["format"]["duration"]) == pytest.approx(4.0, abs=0.35)
    assert probed["streams"][0]["codec_name"] == "h264"

    events = [json.loads(ln) for ln in run.stdout.splitlines() if ln.startswith("{")]
    assert events[0]["event"] == "start"
    assert events[-1]["event"] == "summary" and events[-1]["succeeded"] == 1
