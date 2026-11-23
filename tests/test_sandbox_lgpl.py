"""Tests for Stage 2 Mac App Store Sandbox & LGPL Python Engine extensions."""
import sys
from pathlib import Path

REPO_ROOT = Path(__file__).parent.parent
if str(REPO_ROOT) not in sys.path:
    sys.path.insert(0, str(REPO_ROOT))

import batch  # noqa: E402
import concat  # noqa: E402
import crunch_utils  # noqa: E402
import fit  # noqa: E402
import gif  # noqa: E402
import scan  # noqa: E402
import videocrunch  # noqa: E402


def _make_luma_frame(width: int, height: int, fill_fn) -> bytes:
    buf = bytearray(width * height)
    for y in range(height):
        for x in range(width):
            buf[y * width + x] = fill_fn(x, y)
    return bytes(buf)


class TestLumaFrameBbox:
    def test_letterbox_bars_detected(self):
        frame = _make_luma_frame(16, 16, lambda x, y: 120 if 4 <= y < 12 else 0)
        assert videocrunch.luma_frame_bbox(frame, 16, 16) == (16, 8, 0, 4)

    def test_pillarbox_bars_detected(self):
        frame = _make_luma_frame(16, 16, lambda x, y: 120 if 4 <= x < 12 else 0)
        assert videocrunch.luma_frame_bbox(frame, 16, 16) == (8, 16, 4, 0)

    def test_full_frame_and_all_black(self):
        bright = _make_luma_frame(16, 16, lambda x, y: 100)
        assert videocrunch.luma_frame_bbox(bright, 16, 16) == (16, 16, 0, 0)
        black = _make_luma_frame(16, 16, lambda x, y: 0)
        assert videocrunch.luma_frame_bbox(black, 16, 16) is None


class TestSandboxLogDirOverride:
    def test_history_uses_videocrunch_log_dir_env(self, tmp_path, monkeypatch):
        log_dir = tmp_path / "sandbox-logs"
        monkeypatch.setenv("VIDEOCRUNCH_LOG_DIR", str(log_dir))

        assert crunch_utils.default_log_dir() == log_dir
        assert crunch_utils.resolve_history_path() == log_dir / "encode_history.jsonl"
        assert scan.EncodeHistory().path == log_dir / "encode_history.jsonl"

        record = {
            "encoder": "videotoolbox",
            "height": 1080,
            "source_kbps": 12000,
            "q": 60,
            "ssim": 0.991,
            "saved_pct": 48.0,
        }
        crunch_utils.append_encode_history(record)
        assert (log_dir / "encode_history.jsonl").exists()
        loaded = crunch_utils.read_encode_history()
        assert len(loaded) == 1
        assert loaded[0]["q"] == 60


class TestOutputDirRouting:
    def test_cli_parsers_accept_output_dir(self, tmp_path):
        out = str(tmp_path)
        assert videocrunch.build_parser().parse_args(["a.mp4", "--output-dir", out]).output_dir == out
        assert batch.build_parser().parse_args(["--files", "a.mp4", "--output-dir", out]).output_dir == out
        assert fit.build_parser().parse_args(["a.mp4", "--max-mb", "10", "--output-dir", out]).output_dir == out
        assert concat.build_parser().parse_args(["a.mp4", "b.mp4", "--output-dir", out]).output_dir == out
        assert gif.build_parser().parse_args(["a.mp4", "--output-dir", out]).output_dir == out

    def test_batch_forwards_output_dir(self, tmp_path):
        cmd = batch.build_optimizer_command("a.mp4", None, "standard", output_dir=tmp_path)
        assert "--output-dir" in cmd
        idx = cmd.index("--output-dir")
        assert cmd[idx + 1] == str(tmp_path)

    def test_helper_output_paths_use_custom_dir_and_increment(self, tmp_path):
        src = tmp_path / "src" / "clip.mov"
        out_dir = tmp_path / "out"
        out_dir.mkdir()

        fit_first = fit.output_path_for(src, 25, output_dir=out_dir)
        assert fit_first == out_dir / "clip_25MB.mp4"
        fit_first.touch()
        assert fit.output_path_for(src, 25, output_dir=out_dir) == out_dir / "clip_25MB 2.mp4"

        merge_first = concat.output_path_for(src, output_dir=out_dir)
        assert merge_first == out_dir / "clip_merged.mp4"
        merge_first.touch()
        assert concat.output_path_for(src, output_dir=out_dir) == out_dir / "clip_merged 2.mp4"

        gif_first = gif.output_path_for(src, output_dir=out_dir)
        assert gif_first == out_dir / "clip.gif"
        gif_first.touch()
        assert gif.output_path_for(src, output_dir=out_dir) == out_dir / "clip 2.gif"

    def test_prepare_encode_places_output_in_output_dir(self, tmp_path, monkeypatch):
        src_dir = tmp_path / "readonly-in"
        out_dir = tmp_path / "writable-out"
        src_dir.mkdir()
        src = src_dir / "clip.mov"
        src.write_bytes(b"\x00" * 4096)

        monkeypatch.setattr(videocrunch, "get_video_info", lambda _p: {
            "width": 1920,
            "height": 1080,
            "duration": 20.0,
            "bitrate": 25_000_000,
            "codec": "h264",
            "fps": 30.0,
        })
        monkeypatch.setattr(videocrunch, "probe_stream_inventory", lambda _p: [
            {"index": 0, "codec_type": "video", "codec_name": "h264"},
        ])
        monkeypatch.setattr(videocrunch, "available_decoders", lambda: {"h264"})
        monkeypatch.setattr(videocrunch, "analyze_bitrate", lambda *_a, **_kw: None)

        profile = videocrunch.select_profile("videotoolbox", "hevc", "balanced")
        plan = videocrunch.prepare_encode(src, profile, copy_audio=True, audio_mode="standard",
                                          force=True, output_dir=out_dir)
        assert plan is not None
        assert plan.output_path == out_dir / "clip_opt.mp4"
        assert out_dir.is_dir()
