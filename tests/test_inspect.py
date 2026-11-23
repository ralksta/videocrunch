"""Tests for inspect_media.py — media inspection report, warnings and bitrate curve."""
import json
import shutil
import subprocess
import sys
from pathlib import Path

import pytest

REPO_ROOT = Path(__file__).parent.parent
if str(REPO_ROOT) not in sys.path:
    sys.path.insert(0, str(REPO_ROOT))

import inspect_media  # noqa: E402


class TestBuildInspectionReport:
    def _probe_data(self):
        return {
            "format": {
                "format_name": "mov,mp4,m4a,3gp,3g2,mj2",
                "duration": "10.0",
                "bit_rate": "12000000",
                "tags": {
                    "com.apple.quicktime.make": "Apple",
                    "com.apple.quicktime.model": "iPhone 15 Pro",
                    "com.apple.quicktime.creationdate": "2024-10-10T13:44:56+0200",
                    "com.apple.quicktime.location.ISO6709": "+53.5511+009.9937/",
                },
            },
            "streams": [
                {
                    "index": 0,
                    "codec_type": "video",
                    "codec_name": "hevc",
                    "profile": "Main 10",
                    "width": 3840,
                    "height": 2160,
                    "r_frame_rate": "60/1",
                    "pix_fmt": "yuv420p10le",
                    "color_space": "bt2020nc",
                    "color_transfer": "arib-std-b67",
                    "color_primaries": "bt2020",
                    "bit_rate": "11500000",
                    "side_data_list": [
                        {"rotation": -90},
                        {
                            "side_data_type": "DOVI configuration record",
                            "dv_profile": 8,
                            "dv_bl_signal_compatibility_id": 4,
                        },
                    ],
                },
                {
                    "index": 1,
                    "codec_type": "audio",
                    "codec_name": "aac",
                    "channel_layout": "stereo",
                    "sample_rate": "48000",
                    "bit_rate": "192000",
                    "tags": {"language": "deu"},
                },
                {
                    "index": 2,
                    "codec_type": "audio",
                    "codec_name": "apple_apac",
                    "channels": 4,
                },
                {
                    "index": 3,
                    "codec_type": "data",
                    "codec_name": None,
                    "codec_tag_string": "mebx",
                },
            ],
            "chapters": [{"id": 0}, {"id": 1}],
        }

    def test_extracts_hdr_rotation_dv_warnings_and_bitrate_hotspots(self):
        buckets = {0: 1_000_000, 1: 4_000_000, 5: 3_500_000, 9: 2_500_000}
        report = inspect_media.build_inspection_report(
            self._probe_data(),
            Path("/v/IMG_1438.mov"),
            size_bytes=15_000_000,
            buckets=buckets,
            bucket_len=1.0,
            decodable={"aac", "hevc"},
        )
        v = report["video"]
        assert v["width"] == 2160
        assert v["height"] == 3840
        assert v["fps"] == 60.0
        assert v["hdr_label"] == "HLG HDR"
        assert v["is_hdr"] is True
        assert v["bit_depth"] == 10

        assert report["warnings"]["dolby_vision"] == {"profile": "8.4", "kept_as": "HLG"}
        assert any("apple_apac" in note for note in report["warnings"]["dropped"])
        assert any("mebx" in note for note in report["warnings"]["dropped"])

        kept_by_idx = {s["index"]: s["kept"] for s in report["streams"]}
        assert kept_by_idx == {0: True, 1: True, 2: False, 3: False}
        assert report["streams"][1]["language"] == "deu"

        assert report["metadata"] == {
            "creation_time": "2024-10-10T13:44:56+0200",
            "camera": "Apple iPhone 15 Pro",
            "location": "+53.5511+009.9937/",
            "chapters": 2,
        }

        br = report["bitrate"]
        assert len(br["samples_kbps"]) == 10
        assert br["max_kbps"] == 32000.0
        assert br["is_vbr"] is True
        assert len(br["hotspots_sec"]) >= 1

    def test_empty_buckets_gracefully_fall_back_to_stream_bitrate(self):
        data = {
            "format": {"format_name": "mp4", "duration": "5.0", "bit_rate": "2000000"},
            "streams": [{"index": 0, "codec_type": "video", "codec_name": "h264",
                         "width": 1280, "height": 720, "r_frame_rate": "30/1"}],
        }
        report = inspect_media.build_inspection_report(
            data, Path("/v/clip.mp4"), size_bytes=1_250_000, buckets={}, bucket_len=1.0,
        )
        assert report["bitrate"]["samples_kbps"] == []
        assert report["bitrate"]["avg_kbps"] == 2000.0
        assert report["video"]["hdr_label"] == "SDR"


@pytest.mark.skipif(
    shutil.which("ffmpeg") is None or shutil.which("ffprobe") is None,
    reason="ffmpeg/ffprobe not installed",
)
def test_cli_json_inspects_real_clip(tmp_path):
    clip = tmp_path / "sample.mp4"
    subprocess.run(
        ["ffmpeg", "-y", "-v", "error",
         "-f", "lavfi", "-i", "testsrc2=duration=2:size=320x240:rate=24",
         "-f", "lavfi", "-i", "sine=frequency=440:duration=2",
         "-c:v", "libx264", "-preset", "ultrafast", "-c:a", "aac", "-shortest", str(clip)],
        check=True,
    )
    run = subprocess.run(
        [sys.executable, str(REPO_ROOT / "inspect_media.py"), str(clip), "--json"],
        capture_output=True, text=True, check=True,
    )
    payload = json.loads(run.stdout)
    assert payload["filename"] == "sample.mp4"
    assert payload["video"]["codec"] == "h264"
    assert len(payload["streams"]) == 2
    assert len(payload["bitrate"]["samples_kbps"]) >= 2
