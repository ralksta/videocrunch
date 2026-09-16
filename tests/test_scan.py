"""Unit tests for the folder scanner (pure logic, no ffmpeg).

scan.py ranks a directory's videos by expected re-encode savings and
lets the user mark which ones to run. Both halves are covered here:
`rank()` itself in TestRank below (this is its only test), and the glue
around it — the folder walk, the ffprobe -> media dict mapping, and the
selection parser.

TestJsonOutput below is the exception to "no ffmpeg": it drives scan.py's
`main()` as a real subprocess (real argparse, real ffprobe where available)
to prove `--json` actually emits a parseable, colour-free document — the
concrete failure mode being tested is "a real run redirected to a file
produces valid JSON", which no amount of mocking `subprocess.run` can prove.
"""
import json
import re
import shutil
import subprocess
import sys
from pathlib import Path

import pytest

REPO_ROOT = Path(__file__).parent.parent
if str(REPO_ROOT) not in sys.path:
    sys.path.insert(0, str(REPO_ROOT))

from scan import (  # noqa: E402
    ask_yes_no,
    batch_runtime_sec,
    disk_shortfall,
    display_name,
    downscale_candidates,
    find_videos,
    format_duration,
    has_optimized_sibling,
    outcome_lines,
    parse_selection,
    probe_to_media,
    retry_floor,
    retry_paths,
    select_candidates,
    summary_lines,
    table_name_width,
)

ANSI_ESCAPE_RE = re.compile(r"\x1b\[[0-9;]*[a-zA-Z]")


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

    def test_skips_rejected_candidates(self, tmp_path):
        # A failed run keeps its best encode as _rejected.mp4 for inspection.
        # Offering it as a re-encode candidate would compress an encode of an
        # encode — and the source it came from is right next to it.
        (tmp_path / "a.mp4").touch()
        (tmp_path / "a_rejected.mp4").touch()
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

    def _write_history(self, tmp_path, records):
        path = tmp_path / "encode_history.jsonl"
        with open(path, "w", encoding="utf-8") as f:
            for rec in records:
                f.write(json.dumps(rec) + "\n")
        return path

    def test_history_override_applies_for_a_different_codec_source(self, tmp_path):
        from scan import EncodeHistory, rank
        # Bucket must match the default _media(): h264, 1080p, 12.0 Mbit/s ->
        # bitrate_class(12000) == "high", resolution_class(1080) == "1080".
        history_path = self._write_history(tmp_path, [
            {"height": 1080, "source_kbps": 12000, "codec": "hevc_nvenc", "saved_pct": 50.0},
            {"height": 1080, "source_kbps": 12000, "codec": "hevc_nvenc", "saved_pct": 48.0},
            {"height": 1080, "source_kbps": 12000, "codec": "hevc_nvenc", "saved_pct": 52.0},
        ])
        media = [self._media()]
        out = rank(media, "hevc", set(), EncodeHistory(history_path), 10)
        assert len(out["results"]) == 1
        result = out["results"][0]
        assert result["source"] == "history"
        assert result["confidence"] == "high"
        assert result["estimated_saved_pct"] == pytest.approx(50.0)
        assert out["summary"]["history_based"] == 1

    def test_same_codec_source_is_excluded_from_the_history_override(self, tmp_path):
        from scan import EncodeHistory, rank
        # Same bucket as above, but the source is already HEVC targeting HEVC:
        # history carries no source codec, so a same-codec entry must not
        # inherit the median of unrelated h264-source encodes in this bucket.
        history_path = self._write_history(tmp_path, [
            {"height": 1080, "source_kbps": 12000, "codec": "hevc_nvenc", "saved_pct": 50.0},
            {"height": 1080, "source_kbps": 12000, "codec": "hevc_nvenc", "saved_pct": 48.0},
            {"height": 1080, "source_kbps": 12000, "codec": "hevc_nvenc", "saved_pct": 52.0},
        ])
        media = [self._media(codec="hevc")]
        out = rank(media, "hevc", set(), EncodeHistory(history_path), 10)
        assert len(out["results"]) == 1
        assert out["results"][0]["source"] == "heuristic"
        assert out["summary"]["history_based"] == 0


class TestJsonOutput:
    """`scan.py FOLDER --json` — stdout must be exactly one JSON document.

    Runs the real CLI as a subprocess rather than calling main() in-process:
    that's the only way to actually observe what lands on stdout vs. stderr,
    which is the entire point of --json (a shell redirect only ever sees
    stdout).
    """

    SCAN_PY = REPO_ROOT / "scan.py"

    def _run(self, folder, *extra_args):
        return subprocess.run(
            [sys.executable, str(self.SCAN_PY), str(folder), "--json", *extra_args],
            capture_output=True, text=True, timeout=30,
        )

    def test_empty_folder_emits_parseable_json_with_both_keys(self, tmp_path):
        # No video files at all — exercises main()'s early-return path, still
        # through the real CLI, still must produce a valid document.
        result = self._run(tmp_path)
        assert result.returncode == 0
        payload = json.loads(result.stdout)
        assert "results" in payload
        assert "summary" in payload
        assert payload["results"] == []

    def test_empty_folder_json_has_no_ansi_escapes(self, tmp_path):
        result = self._run(tmp_path)
        assert ANSI_ESCAPE_RE.search(result.stdout) is None

    def test_empty_folder_stdout_is_only_the_json_line(self, tmp_path):
        # No banner, no progress counter, no table — stdout must be nothing
        # but the JSON document (plus its trailing newline from print()).
        result = self._run(tmp_path)
        assert result.stdout.strip().count("\n") == 0
        json.loads(result.stdout)  # single document, not one-per-line noise

    def test_json_implies_no_interactive_prompt(self, tmp_path):
        # If --json ever tried to read a selection, this run would hang until
        # the timeout instead of exiting — stdin is closed, so input() would
        # raise EOFError if reached, but reaching it at all is the bug.
        result = subprocess.run(
            [sys.executable, str(self.SCAN_PY), str(tmp_path), "--json"],
            capture_output=True, text=True, timeout=30, stdin=subprocess.DEVNULL,
        )
        assert result.returncode == 0
        json.loads(result.stdout)

    @pytest.mark.skipif(
        shutil.which("ffmpeg") is None or shutil.which("ffprobe") is None,
        reason="ffmpeg/ffprobe not installed",
    )
    def test_real_probe_run_redirected_to_a_file_is_valid_json(self, tmp_path):
        # Full real code path: a real encoded file, real ffprobe, real
        # rank()/EncodeHistory, redirected to a file exactly as the README's
        # example does — this is the scenario the review finding was about.
        clip = tmp_path / "clip.mp4"
        subprocess.run(
            ["ffmpeg", "-y", "-f", "lavfi", "-i", "testsrc=duration=1:size=320x240:rate=24",
             "-c:v", "libx264", "-preset", "ultrafast", str(clip)],
            check=True, capture_output=True,
        )
        report = tmp_path / "report.json"
        with open(report, "wb") as f:
            result = subprocess.run(
                [sys.executable, str(self.SCAN_PY), str(tmp_path), "--json"],
                stdout=f, stderr=subprocess.PIPE, timeout=60,
            )
        assert result.returncode == 0
        text = report.read_text()
        payload = json.loads(text)
        assert "results" in payload and "summary" in payload
        assert ANSI_ESCAPE_RE.search(text) is None


class TestDisplayName:
    """What the table calls a file.

    Showing the bare filename makes two candidates indistinguishable whenever
    a folder tree repeats names — which is the normal case for phone imports
    (IMG_1234.mov in every import folder).
    """

    def test_file_in_the_scanned_folder_shows_its_name(self):
        assert display_name(Path("/v/clip.mp4"), Path("/v"), 40) == "clip.mp4"

    def test_file_in_a_subfolder_shows_the_path(self):
        assert display_name(Path("/v/Urlaub/strand.mp4"), Path("/v"), 40) == "Urlaub/strand.mp4"

    def test_long_paths_lose_their_front_not_their_filename(self):
        # Truncating the end would hide the one part that identifies the file.
        shown = display_name(Path("/v/a/very/deeply/nested/folder/strand.mp4"), Path("/v"), 20)
        assert len(shown) <= 20
        assert shown.endswith("strand.mp4")

    def test_a_path_outside_the_scanned_folder_falls_back_to_its_name(self):
        assert display_name(Path("/elsewhere/clip.mp4"), Path("/v"), 40) == "clip.mp4"


class TestTableWidth:
    """The table has to fit the terminal it is printed into."""

    def test_wide_terminal_gets_a_wide_name_column(self):
        assert table_name_width(200) > table_name_width(80)

    def test_narrow_terminal_still_leaves_a_usable_column(self):
        assert table_name_width(60) >= 12

    def test_an_implausible_width_falls_back_instead_of_shrinking(self):
        # A pty with no window size set reports 0 columns. Taken literally
        # that leaves a 12-character name column and every path is elided.
        assert table_name_width(0) == table_name_width(86)
        assert table_name_width(10) == table_name_width(86)

    def test_the_table_stays_inside_the_terminal(self):
        # 40 columns are spent on number, savings, percent and info.
        for cols in (60, 80, 120, 200):
            assert table_name_width(cols) + 40 <= cols


class TestSummaryLines:
    """The numbers under the table must describe what the table shows.

    With --limit in play the summary used to count candidates the user cannot
    select: "5 candidates, ~71 MB" under a table offering two of them worth
    61 MB, and `a = alle` meaning the two.
    """

    SHOWN = [{"estimated_saved_mb": 38.0}, {"estimated_saved_mb": 23.0}]
    SUMMARY = {"total_files": 5, "total_estimated_saved_mb": 71.0, "history_based": 0}

    def _joined(self, **kwargs):
        return " ".join(summary_lines(self.SHOWN, self.SUMMARY, **kwargs))

    def test_totals_describe_the_listed_candidates(self):
        text = self._joined(hidden_below=0, excluded=0)
        assert "61" in text
        assert "71" not in text

    def test_truncation_is_stated(self):
        text = self._joined(hidden_below=0, excluded=0)
        assert "3" in text  # 5 candidates, 2 listed

    def test_nothing_is_said_about_truncation_when_all_are_listed(self):
        summary = {"total_files": 2, "total_estimated_saved_mb": 61.0, "history_based": 0}
        text = " ".join(summary_lines(self.SHOWN, summary, hidden_below=0, excluded=0))
        assert "limit" not in text.lower()


class TestSelectCandidates:
    """The selection line, resolved against the listed candidates.

    Numbers alone force counting rows: "encode everything except the two I
    already did" is a common wish and was only expressible by typing out every
    other number. So is "just the holiday folder".
    """

    NAMES = ["gross.mp4", "Urlaub/strand.mp4", "Urlaub/sonne.mp4",
             "Clips/kurz.mp4", "Clips/strand.mp4"]

    def test_numbers_work_as_before(self):
        assert select_candidates("1,3", self.NAMES) == [1, 3]

    def test_all_except(self):
        assert select_candidates("a -3", self.NAMES) == [1, 2, 4, 5]

    def test_all_except_several(self):
        assert select_candidates("a -3,5", self.NAMES) == [1, 2, 4]

    def test_exclusion_applies_to_a_range_too(self):
        assert select_candidates("1-4 -2", self.NAMES) == [1, 3, 4]

    def test_a_name_selects_what_matches_it(self):
        assert select_candidates("Urlaub", self.NAMES) == [2, 3]

    def test_matching_ignores_case(self):
        assert select_candidates("urlaub", self.NAMES) == [2, 3]

    def test_a_name_can_be_narrowed_by_exclusion(self):
        assert select_candidates("strand -5", self.NAMES) == [2]

    def test_a_name_nothing_matches_is_an_error(self):
        # Silently selecting nothing would look like the user changed their
        # mind, not like a typo.
        with pytest.raises(ValueError, match="Treffer"):
            select_candidates("berge", self.NAMES)

    def test_empty_still_means_nothing(self):
        assert select_candidates("", self.NAMES) == []


class TestWizardQuestions:
    """What the wizard asks after the files are picked.

    It used to ask exactly one thing — which files — while the choices with
    the largest effect (downscaling 4K, replacing the originals) were
    reachable only as command-line flags, by people who chose the guided path
    precisely because they do not know the flags.
    """

    def test_yes_and_no_are_taken_literally(self):
        assert ask_yes_no("?", default=False, ask=lambda: "j") is True
        assert ask_yes_no("?", default=True, ask=lambda: "n") is False

    def test_enter_takes_the_default(self):
        assert ask_yes_no("?", default=True, ask=lambda: "") is True
        assert ask_yes_no("?", default=False, ask=lambda: "") is False

    def test_an_unanswerable_question_never_starts_anything(self):
        # Closed stdin or Ctrl-C: doing nothing is the safe reading, whatever
        # the default would have been.
        def interrupted():
            raise EOFError
        assert ask_yes_no("?", default=True, ask=interrupted) is False

    def test_downscale_is_offered_only_for_taller_material(self):
        entries = [{"height": 2160}, {"height": 1080}, {"height": 3840}]
        assert downscale_candidates(entries, 1080) == 2

    def test_nothing_to_downscale_means_no_question(self):
        entries = [{"height": 1080}, {"height": 720}]
        assert downscale_candidates(entries, 1080) == 0


class TestFormatDuration:
    """Runtime estimates are read at a glance, so they round to something human."""

    def test_short_runs_say_so_rather_than_counting_seconds(self):
        assert format_duration(35) == "unter 1 min"

    def test_minutes(self):
        assert format_duration(100) == "2 min"

    def test_hours_and_minutes(self):
        assert format_duration(4020) == "1 h 7 min"

    def test_whole_hours_drop_the_minutes(self):
        assert format_duration(7200) == "2 h"


class TestOutcome:
    """What the wizard says once the batch is done.

    It used to say nothing: the run ended and the estimate it had shown was
    never held against the result. Files that came in under the quality floor
    were simply gone from view, although the measurement that would let the
    user accept them was right there.
    """

    def test_the_estimate_is_held_against_the_result(self):
        text = " ".join(outcome_lines(estimated_mb=65.0, results=[
            {"status": "success", "saved_bytes": 71 * 1024 * 1024},
        ]))
        assert "65" in text and "71" in text

    def test_failures_are_counted(self):
        text = " ".join(outcome_lines(estimated_mb=10.0, results=[
            {"status": "success", "saved_bytes": 1024 * 1024},
            {"status": "failed", "ssim": 0.87},
            {"status": "failed", "ssim": 0.91},
        ]))
        assert "2" in text

    def test_retry_floor_clears_the_worst_failure(self):
        # One floor has to satisfy every file the user wants to retry, so it
        # follows the lowest score - and rounds down, or the retry fails too.
        assert retry_floor([{"status": "failed", "ssim": 0.8712},
                            {"status": "failed", "ssim": 0.9134}]) == 0.87

    def test_retry_uses_the_paths_the_batch_reports(self):
        # batch.py calls the source "path"; videocrunch.py calls it
        # "input_path". Reading only one of them silently retries nothing.
        assert retry_paths([{"status": "failed", "ssim": 0.87, "path": "/v/a.mp4"}]) == ["/v/a.mp4"]
        assert retry_paths([{"status": "failed", "ssim": 0.87,
                             "input_path": "/v/b.mp4"}]) == ["/v/b.mp4"]

    def test_only_quality_failures_are_retried(self):
        # Moving the floor does not fix an ffmpeg error.
        assert retry_paths([{"status": "failed", "reason": "ffmpeg", "path": "/v/a.mp4"},
                            {"status": "success", "path": "/v/b.mp4"}]) == []

    def test_no_measured_failure_means_nothing_to_retry(self):
        assert retry_floor([{"status": "failed", "reason": "ffmpeg error"}]) is None
        assert retry_floor([{"status": "success", "ssim": 0.99}]) is None


class TestBatchRuntime:
    """How long the selected files will take, added up per file.

    One throughput figure for a mixed selection is meaningless: a 4K clip and
    a 480p clip differ by an order of magnitude. Each file is estimated in its
    own resolution class, and a single file without a basis makes the whole
    estimate unavailable rather than wrong.
    """

    RECORDS = [{"size_mb": 100.0, "duration": 10.0, "height": 1080}] * 3

    def test_sums_the_files(self):
        entries = [{"size_mb": 50.0, "height": 1080}, {"size_mb": 50.0, "height": 1080}]
        assert batch_runtime_sec(entries, self.RECORDS) == 10.0

    def test_one_unknown_class_withholds_the_estimate(self):
        entries = [{"size_mb": 50.0, "height": 1080}, {"size_mb": 50.0, "height": 2160}]
        assert batch_runtime_sec(entries, self.RECORDS) is None

    def test_no_history_at_all_means_no_estimate(self):
        assert batch_runtime_sec([{"size_mb": 50.0, "height": 1080}], []) is None


class TestWizardDiskCheck:
    """The wizard adds up what the whole selection needs before starting.

    Per-file checks catch the problem, but only once the batch is running and
    files start failing one after another. The selection is known up front.
    """

    ENTRIES = [{"size_mb": 100.0}, {"size_mb": 50.0}]

    def test_enough_room_reports_no_shortfall(self):
        assert disk_shortfall(self.ENTRIES, free_bytes=10 * 1024**3) == 0

    def test_a_shortfall_is_reported_in_bytes(self):
        # 150 MB of source needs headroom for staging on top.
        assert disk_shortfall(self.ENTRIES, free_bytes=1024) > 0

    def test_an_empty_selection_needs_nothing(self):
        assert disk_shortfall([], free_bytes=0) == 0
