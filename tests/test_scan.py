"""Unit tests for the folder scanner (pure logic, no ffmpeg).

scan.py ranks a directory's videos by expected re-encode savings and
lets the user mark which ones to run. The ranking itself is
optimization_advisor.build_candidates — covered by its own tests. What is
tested here is the new glue: the folder walk, the ffprobe -> media dict
mapping, and the selection parser.
"""
import sys
from pathlib import Path

import pytest

REPO_ROOT = Path(__file__).parent.parent
if str(REPO_ROOT) not in sys.path:
    sys.path.insert(0, str(REPO_ROOT))

from scan import (  # noqa: E402
    find_videos,
    has_optimized_sibling,
    parse_selection,
    probe_to_media,
)


class TestParseSelection:
    """`1,3,7-10` — the line the user types to mark files for encoding."""

    def test_single_numbers(self):
        assert parse_selection("1,3", 10) == [1, 3]

    def test_range(self):
        assert parse_selection("7-10", 10) == [7, 8, 9, 10]

    def test_mixed_with_whitespace(self):
        assert parse_selection(" 1, 3 , 7-10 ", 10) == [1, 3, 7, 8, 9, 10]

    def test_deduplicates_and_sorts(self):
        assert parse_selection("5,1,5,2-3,3", 10) == [1, 2, 3, 5]

    def test_empty_means_nothing(self):
        assert parse_selection("", 10) == []
        assert parse_selection("   ", 10) == []

    def test_a_means_all(self):
        assert parse_selection("a", 4) == [1, 2, 3, 4]
        assert parse_selection("A", 4) == [1, 2, 3, 4]
        assert parse_selection("alle", 4) == [1, 2, 3, 4]
        assert parse_selection("all", 4) == [1, 2, 3, 4]

    def test_reversed_range_is_forgiving(self):
        assert parse_selection("10-7", 10) == [7, 8, 9, 10]

    def test_out_of_range_is_an_error(self):
        # Silently dropping these would start an encode run the user did not
        # ask for, without saying which entry went missing.
        with pytest.raises(ValueError, match="13"):
            parse_selection("1,13", 10)

    def test_zero_is_an_error(self):
        with pytest.raises(ValueError):
            parse_selection("0", 10)

    def test_garbage_is_an_error(self):
        with pytest.raises(ValueError):
            parse_selection("1,foo", 10)
        with pytest.raises(ValueError):
            parse_selection("1--3", 10)


class TestEntryFromProbe:
    """ffprobe JSON -> media dict, mirroring what the scanner stores."""

    def _probe(self, **fmt):
        base = {"size": "1048576000", "duration": "600.0", "bit_rate": "12000000"}
        base.update(fmt)
        return {
            "format": base,
            "streams": [
                {"codec_type": "video", "codec_name": "h264", "width": 1920,
                 "height": 1080, "avg_frame_rate": "25/1"},
                {"codec_type": "audio", "codec_name": "aac"},
            ],
        }

    def test_maps_the_fields_the_ranking_needs(self):
        e = probe_to_media("/lib/a.mp4", self._probe())
        assert e is not None
        assert e["file_path"] == "/lib/a.mp4"
        assert e["codec"] == "h264"
        assert e["height"] == 1080
        assert e["width"] == 1920
        assert e["frame_rate"] == 25.0
        assert e["bitrate_mbps"] == pytest.approx(12.0)
        assert e["size_mb"] == pytest.approx(1000.0)

    def test_falls_back_to_size_over_duration(self):
        # Matroska frequently omits format.bit_rate. Without a fallback the
        # entry ranks as 0 Mbit/s and drops out of the list entirely.
        e = probe_to_media("/lib/a.mkv", self._probe(bit_rate="N/A"))
        assert e is not None
        assert e["bitrate_mbps"] == pytest.approx(14.0, abs=0.1)  # 1000 MB / 600 s

    def test_rejects_files_without_a_video_stream(self):
        probe = {"format": {"size": "100", "duration": "10"},
                 "streams": [{"codec_type": "audio", "codec_name": "mp3"}]}
        assert probe_to_media("/lib/a.mp3", probe) is None

    def test_rejects_empty_probe(self):
        assert probe_to_media("/lib/a.mp4", {}) is None

    def test_survives_na_frame_rate(self):
        e = probe_to_media("/lib/a.mp4", {
            "format": {"size": "100", "duration": "10", "bit_rate": "80"},
            "streams": [{"codec_type": "video", "codec_name": "hevc",
                         "width": 640, "height": 480, "avg_frame_rate": "0/0"}],
        })
        assert e is not None
        assert e["frame_rate"] == 0.0


class TestFindVideos:
    def test_finds_videos_recursively_and_ignores_other_files(self, tmp_path):
        (tmp_path / "sub").mkdir()
        (tmp_path / "a.mp4").touch()
        (tmp_path / "sub" / "b.mkv").touch()
        (tmp_path / "notes.txt").touch()
        (tmp_path / "cover.jpg").touch()
        found = {p.name for p in find_videos(tmp_path)}
        assert found == {"a.mp4", "b.mkv"}

    def test_extension_match_is_case_insensitive(self, tmp_path):
        (tmp_path / "a.MP4").touch()
        assert [p.name for p in find_videos(tmp_path)] == ["a.MP4"]

    def test_skips_the_optimizer_own_output(self, tmp_path):
        # Listing _opt.mp4 files as re-encode candidates would offer to
        # optimize the optimizer's results.
        (tmp_path / "a.mp4").touch()
        (tmp_path / "a_opt.mp4").touch()
        assert [p.name for p in find_videos(tmp_path)] == ["a.mp4"]

    def test_skips_staging_leftovers(self, tmp_path):
        (tmp_path / "a.mp4").touch()
        (tmp_path / "a_opt._staging_q65.mp4").touch()
        assert [p.name for p in find_videos(tmp_path)] == ["a.mp4"]

    def test_returns_sorted_paths(self, tmp_path):
        for name in ("c.mp4", "a.mp4", "b.mp4"):
            (tmp_path / name).touch()
        assert [p.name for p in find_videos(tmp_path)] == ["a.mp4", "b.mp4", "c.mp4"]


class TestHasOptimizedSibling:
    def test_true_when_opt_file_exists(self, tmp_path):
        src = tmp_path / "a.mp4"
        src.touch()
        (tmp_path / "a_opt.mp4").touch()
        assert has_optimized_sibling(src) is True

    def test_false_without_one(self, tmp_path):
        src = tmp_path / "a.mp4"
        src.touch()
        assert has_optimized_sibling(src) is False

    def test_matches_regardless_of_source_extension(self, tmp_path):
        # The optimizer always writes .mp4, whatever went in.
        src = tmp_path / "a.mkv"
        src.touch()
        (tmp_path / "a_opt.mp4").touch()
        assert has_optimized_sibling(src) is True


class TestRank:
    def _media(self, **kw):
        base = dict(file_path="/lib/a.mp4", size_mb=1000.0, bitrate_mbps=12.0,
                    codec="h264", duration_sec=600.0, width=1920, height=1080,
                    frame_rate=25.0)
        base.update(kw)
        return base

    def test_sorts_by_absolute_savings(self):
        from scan import EncodeHistory, rank
        media = [
            self._media(file_path="/lib/small.mp4", size_mb=100.0),
            self._media(file_path="/lib/big.mp4", size_mb=2000.0),
        ]
        out = rank(media, "hevc", set(), EncodeHistory(Path("/nonexistent")), 10)
        names = [r["file_path"] for r in out["results"]]
        assert names == ["/lib/big.mp4", "/lib/small.mp4"]

    def test_drops_candidates_below_the_threshold(self):
        from scan import EncodeHistory, rank
        # A lean HEVC source has nothing to give and must not be listed.
        media = [self._media(codec="hevc", bitrate_mbps=0.683, height=720,
                             width=1280, size_mb=525.0)]
        out = rank(media, "hevc", set(), EncodeHistory(Path("/nonexistent")), 10)
        assert out["results"] == []
        assert out["summary"]["total_files"] == 0

    def test_excluded_paths_are_skipped(self):
        from scan import EncodeHistory, rank
        media = [self._media(file_path="/lib/done.mp4")]
        out = rank(media, "hevc", {"/lib/done.mp4"},
                   EncodeHistory(Path("/nonexistent")), 10)
        assert out["results"] == []

    def test_limit_truncates_results_but_not_the_summary(self):
        from scan import EncodeHistory, rank
        media = [self._media(file_path=f"/lib/{i}.mp4") for i in range(5)]
        out = rank(media, "hevc", set(), EncodeHistory(Path("/nonexistent")), 2)
        assert len(out["results"]) == 2
        assert out["summary"]["total_files"] == 5
