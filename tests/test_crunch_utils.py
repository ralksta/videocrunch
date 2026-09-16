"""
test_crunch_utils.py
---------------------
Unit tests for crunch_utils.py — the pure (subprocess-free) helper
logic behind the video optimizer: encode history Q seeding, HDR detection,
loudnorm filter building, scene-window selection, and worker scheduling.
"""
import sys
from datetime import time as dtime
from pathlib import Path

REPO_ROOT = Path(__file__).parent.parent
if str(REPO_ROOT) not in sys.path:
    sys.path.insert(0, str(REPO_ROOT))

from crunch_utils import (  # noqa: E402
    append_encode_history,
    apply_hdr_adjustments,
    battery_from_pmset,
    bitrate_class,
    build_audio_filter_chain,
    build_stream_args,
    clamp_maxrate_to_pass,
    disk_headroom_needed,
    estimate_runtime_sec,
    history_throughput,
    is_hdr_or_10bit,
    is_within_schedule,
    narrow_quality_window,
    nearest_quality_index,
    parse_loudnorm_json,
    parse_schedule,
    read_encode_history,
    resolution_class,
    select_top_windows,
    suggest_q_from_history,
)


class TestHistory:
    def test_bitrate_class_buckets(self):
        assert bitrate_class(1000) == "low"
        assert bitrate_class(5000) == "med"
        assert bitrate_class(15000) == "high"
        assert bitrate_class(50000) == "ultra"

    def test_resolution_class_buckets(self):
        assert resolution_class(480) == "sd"
        assert resolution_class(720) == "720"
        assert resolution_class(1080) == "1080"
        assert resolution_class(1440) == "1440"
        assert resolution_class(2160) == "2160"

    def test_append_and_suggest_median(self, tmp_path):
        hist = tmp_path / "h.jsonl"
        for q in (55, 65, 60, 60, 58):
            append_encode_history(
                {"encoder": "videotoolbox", "height": 1080,
                 "source_kbps": 12000, "q": q, "ssim": 0.97, "saved_pct": 40.0},
                history_path=hist,
            )
        assert suggest_q_from_history("videotoolbox", 1080, 12000, hist) == 60

    def test_suggest_needs_min_samples(self, tmp_path):
        hist = tmp_path / "h.jsonl"
        append_encode_history(
            {"encoder": "videotoolbox", "height": 1080,
             "source_kbps": 12000, "q": 60, "ssim": 0.97, "saved_pct": 40.0},
            history_path=hist,
        )
        assert suggest_q_from_history("videotoolbox", 1080, 12000, hist) is None

    def test_suggest_ignores_other_buckets(self, tmp_path):
        hist = tmp_path / "h.jsonl"
        for _ in range(5):
            append_encode_history(
                {"encoder": "nvenc", "height": 2160,
                 "source_kbps": 40000, "q": 30, "ssim": 0.97, "saved_pct": 40.0},
                history_path=hist,
            )
        assert suggest_q_from_history("videotoolbox", 1080, 12000, hist) is None

    def test_suggest_missing_file_returns_none(self, tmp_path):
        assert suggest_q_from_history("videotoolbox", 1080, 12000, tmp_path / "nope.jsonl") is None

    def test_suggest_survives_corrupt_lines(self, tmp_path):
        hist = tmp_path / "h.jsonl"
        hist.write_text('not json\n{"broken":\n')
        assert suggest_q_from_history("videotoolbox", 1080, 12000, hist) is None

    def test_nearest_quality_index(self):
        assert nearest_quality_index([75, 65, 55, 45], 58) == 2
        assert nearest_quality_index([24, 28, 32, 36, 40, 44], 30) == 1


SDR = {"pix_fmt": "yuv420p", "color_transfer": "bt709", "color_primaries": "bt709"}
HDR10 = {"pix_fmt": "yuv420p10le", "color_transfer": "smpte2084", "color_primaries": "bt2020"}
HLG = {"pix_fmt": "yuv420p10le", "color_transfer": "arib-std-b67", "color_primaries": "bt2020"}


class TestHdr:
    def test_sdr_not_flagged(self):
        assert is_hdr_or_10bit(SDR) is False

    def test_hdr10_and_hlg_flagged(self):
        assert is_hdr_or_10bit(HDR10) is True
        assert is_hdr_or_10bit(HLG) is True

    def test_10bit_sdr_flagged(self):
        assert is_hdr_or_10bit({**SDR, "pix_fmt": "yuv420p10le"}) is True

    def test_missing_fields_not_flagged(self):
        assert is_hdr_or_10bit({}) is False

    def test_videotoolbox_gets_main10_p010(self):
        profile = {"codec": "hevc_videotoolbox",
                   "encoder_args": ["-profile:v", "main", "-allow_sw", "0"],
                   "video_filter": "format=yuv420p,scale=trunc(iw/2)*2:trunc(ih/2)*2"}
        adj = apply_hdr_adjustments(profile, HDR10)
        assert adj is not None
        assert "main10" in adj["encoder_args"]
        assert "main" not in [a for a in adj["encoder_args"] if a == "main"]
        assert "p010le" in adj["video_filter"]
        assert "-color_trc" in adj["color_args"]
        assert "smpte2084" in adj["color_args"]
        assert "bt2020" in " ".join(adj["color_args"])

    def test_hlg_transfer_passes_through(self):
        profile = {"codec": "libx265",
                   "encoder_args": ["-preset", "medium"],
                   "video_filter": "format=yuv420p,scale=trunc(iw/2)*2:trunc(ih/2)*2"}
        adj = apply_hdr_adjustments(profile, HLG)
        assert adj is not None
        assert "arib-std-b67" in adj["color_args"]
        assert "yuv420p10le" in adj["video_filter"]
        assert "main10" in adj["encoder_args"]

    def test_original_profile_not_mutated(self):
        profile = {"codec": "hevc_videotoolbox",
                   "encoder_args": ["-profile:v", "main"],
                   "video_filter": "format=yuv420p,scale=trunc(iw/2)*2:trunc(ih/2)*2"}
        apply_hdr_adjustments(profile, HDR10)
        assert profile["encoder_args"] == ["-profile:v", "main"]

    def test_unsupported_encoder_returns_none(self):
        profile = {"codec": "hevc_qsv", "encoder_args": [], "video_filter": "format=yuv420p"}
        assert apply_hdr_adjustments(profile, HDR10) is None


LOUDNORM_STDERR = """
[Parsed_loudnorm_3 @ 0x600002]
{
\t"input_i" : "-23.61",
\t"input_tp" : "-6.53",
\t"input_lra" : "5.90",
\t"input_thresh" : "-33.79",
\t"output_i" : "-19.02",
\t"output_tp" : "-2.03",
\t"output_lra" : "5.10",
\t"output_thresh" : "-29.13",
\t"normalization_type" : "dynamic",
\t"target_offset" : "0.02"
}
"""


class TestLoudnorm:
    def test_parse_extracts_measurements(self):
        m = parse_loudnorm_json(LOUDNORM_STDERR)
        assert m["input_i"] == "-23.61"
        assert m["target_offset"] == "0.02"

    def test_parse_garbage_returns_none(self):
        assert parse_loudnorm_json("no json here") is None

    def test_dynamic_chain_without_measurement(self):
        chain = build_audio_filter_chain("moderate")
        assert "loudnorm=I=-19:TP=-1.5:LRA=11" in chain
        assert "measured_I" not in chain
        assert chain.startswith("aformat=channel_layouts=stereo")

    def test_linear_chain_with_measurement(self):
        m = parse_loudnorm_json(LOUDNORM_STDERR)
        chain = build_audio_filter_chain("enhanced", measured=m)
        assert "loudnorm=I=-16" in chain
        assert "measured_I=-23.61" in chain
        assert "measured_TP=-6.53" in chain
        assert "measured_LRA=5.90" in chain
        assert "measured_thresh=-33.79" in chain
        assert "offset=0.02" in chain
        assert "linear=true" in chain

    def test_silent_audio_falls_back_to_dynamic(self):
        m = {"input_i": "-inf", "input_tp": "-inf",
             "input_lra": "0.00", "input_thresh": "-inf", "target_offset": "0.00"}
        chain = build_audio_filter_chain("moderate", measured=m)
        assert "measured_I" not in chain

    def test_standard_mode_returns_none(self):
        assert build_audio_filter_chain("standard") is None


class TestSceneWindows:
    def test_picks_heaviest_bucket_per_third(self):
        # 300s video, 5s buckets: heavy spots at 10s, 150s, 250s
        buckets = {i: 100 for i in range(60)}
        buckets[2] = 9000    # 10-15s (first third)
        buckets[30] = 8000   # 150-155s (second third)
        buckets[50] = 7000   # 250-255s (last third)
        starts = select_top_windows(buckets, 300.0, n=3, window=3.0, bucket_len=5.0)
        assert starts == [10.0, 150.0, 250.0]

    def test_empty_buckets_fall_back_to_percentages(self):
        starts = select_top_windows({}, 100.0, n=3, window=3.0)
        assert starts == [25.0, 50.0, 75.0]

    def test_starts_clamped_inside_duration(self):
        buckets = {19: 9999}  # 95-100s of a 100s video
        starts = select_top_windows(buckets, 100.0, n=3, window=3.0, bucket_len=5.0)
        for s in starts:
            assert 0.0 <= s <= 100.0 - 3.0 - 0.5

    def test_returns_sorted_unique(self):
        buckets = {0: 500, 1: 400, 2: 300}
        starts = select_top_windows(buckets, 15.0, n=3, window=3.0, bucket_len=5.0)
        assert starts == sorted(starts)
        assert len(set(starts)) == len(starts)

    def test_zero_duration_falls_back(self):
        assert select_top_windows({0: 100}, 0.0, n=3, window=3.0) == [0.0]


class TestNarrowWindow:
    def test_center(self):
        assert narrow_quality_window(6, 3, radius=1) == (2, 4)

    def test_clamped_at_edges(self):
        assert narrow_quality_window(6, 0, radius=1) == (0, 1)
        assert narrow_quality_window(6, 5, radius=1) == (4, 5)

    def test_single_value(self):
        assert narrow_quality_window(1, 0, radius=1) == (0, 0)


class TestSchedule:
    def test_parse_valid(self):
        assert parse_schedule("01:00-08:30") == (dtime(1, 0), dtime(8, 30))

    def test_parse_invalid(self):
        assert parse_schedule("nonsense") is None
        assert parse_schedule("25:00-08:00") is None
        assert parse_schedule("") is None

    def test_within_normal_window(self):
        win = (dtime(9, 0), dtime(17, 0))
        assert is_within_schedule(win, now=dtime(12, 0)) is True
        assert is_within_schedule(win, now=dtime(8, 59)) is False
        assert is_within_schedule(win, now=dtime(17, 1)) is False

    def test_overnight_window_wraps(self):
        win = (dtime(22, 0), dtime(6, 0))
        assert is_within_schedule(win, now=dtime(23, 30)) is True
        assert is_within_schedule(win, now=dtime(3, 0)) is True
        assert is_within_schedule(win, now=dtime(12, 0)) is False


class TestBattery:
    def test_battery_power_detected(self):
        assert battery_from_pmset("Now drawing from 'Battery Power'\n -InternalBattery-0") is True

    def test_ac_power_not_battery(self):
        assert battery_from_pmset("Now drawing from 'AC Power'\n -InternalBattery-0") is False

    def test_garbage_defaults_to_false(self):
        assert battery_from_pmset("") is False


class TestClampMaxrateToPass:
    """The peak cap has to follow the ladder rung, not the source file."""

    def test_caps_to_twice_the_pass_target(self):
        # Real case: file-wide cap 2346k while the pass aims at 632k — the
        # encoder was free to spend 3.7x its target and overshot the size goal.
        maxrate, bufsize = clamp_maxrate_to_pass(2346.0, 4692.0, 632.0)
        assert maxrate == 1264.0
        assert bufsize == 2528.0

    def test_keeps_file_wide_cap_when_already_tighter(self):
        # A high pass target must never RAISE the source-derived ceiling.
        assert clamp_maxrate_to_pass(1000.0, 2000.0, 900.0) == (1000.0, 2000.0)

    def test_passthrough_without_pass_target(self):
        assert clamp_maxrate_to_pass(2346.0, 4692.0, None) == (2346.0, 4692.0)
        assert clamp_maxrate_to_pass(2346.0, 4692.0, 0) == (2346.0, 4692.0)

    def test_gives_a_cap_even_without_source_analysis(self):
        assert clamp_maxrate_to_pass(None, None, 500.0) == (1000.0, 2000.0)

    def test_ladder_rungs_get_distinct_caps(self):
        # The whole point: different targets must yield different ceilings.
        caps = [clamp_maxrate_to_pass(2346.0, 4692.0, t)[0] for t in (749, 632, 514, 397)]
        assert len(set(caps)) == 4
        assert caps == sorted(caps, reverse=True)


class TestStreamMapping:
    """Which input streams survive the encode, and how.

    ffmpeg's default stream selection keeps exactly one audio track and drops
    everything else — silently. For a tool that re-encodes whole libraries
    that means second language tracks, commentary and subtitles disappear
    without a word. Every stream is either carried over or named in the notes.
    """

    VIDEO = {"codec_type": "video", "codec_name": "hevc"}

    def _audio(self, codec="aac"):
        return {"codec_type": "audio", "codec_name": codec}

    def test_every_audio_track_is_mapped(self):
        args, _ = build_stream_args(
            [self.VIDEO, self._audio(), self._audio()],
            copy_audio=False, audio_filters=None)
        assert "0:a:0" in args and "0:a:1" in args

    def test_only_the_first_audio_track_gets_the_filter_chain(self):
        # The two-pass loudnorm measurement is taken from the first track
        # only; applying its numbers to a second track would normalize it
        # against the wrong signal.
        args, _ = build_stream_args(
            [self.VIDEO, self._audio(), self._audio()],
            copy_audio=False, audio_filters="loudnorm=I=-19")
        assert "-filter:a:0" in args
        assert "-filter:a:1" not in args
        assert "-af" not in args

    def test_undecodable_track_is_skipped_and_named(self):
        # Apple's spatial audio (apple_apac) has no decoder and no mp4 tag:
        # mapping it blindly fails the whole encode.
        args, skipped = build_stream_args(
            [self.VIDEO, self._audio(), self._audio("apple_apac")],
            copy_audio=False, audio_filters=None, decodable={"aac"})
        assert "0:a:1" not in args
        assert any("apple_apac" in note for note in skipped)

    def test_copy_mode_skips_tracks_mp4_cannot_hold(self):
        args, skipped = build_stream_args(
            [self.VIDEO, self._audio(), self._audio("apple_apac")],
            copy_audio=True, audio_filters=None)
        assert "-c:a" in args and args[args.index("-c:a") + 1] == "copy"
        assert "0:a:1" not in args
        assert any("apple_apac" in note for note in skipped)

    def test_text_subtitles_are_converted_for_mp4(self):
        args, _ = build_stream_args(
            [self.VIDEO, self._audio(), {"codec_type": "subtitle", "codec_name": "subrip"}],
            copy_audio=False, audio_filters=None)
        assert "0:s:0" in args
        assert args[args.index("-c:s") + 1] == "mov_text"

    def test_image_subtitles_are_skipped_and_named(self):
        args, skipped = build_stream_args(
            [self.VIDEO, self._audio(), {"codec_type": "subtitle", "codec_name": "hdmv_pgs_subtitle"}],
            copy_audio=False, audio_filters=None)
        assert "0:s:0" not in args
        assert any("hdmv_pgs_subtitle" in note for note in skipped)

    def test_data_streams_are_never_mapped(self):
        # iPhone clips carry timecode and metadata tracks the mp4 muxer
        # rejects; they are dropped on purpose, not by accident.
        args, _ = build_stream_args(
            [self.VIDEO, self._audio(), {"codec_type": "data", "codec_name": "bin_data"}],
            copy_audio=False, audio_filters=None)
        assert not any(a.startswith("0:d") for a in args)


class TestRuntimeEstimate:
    """How long a batch will take, from what past runs actually took.

    A wizard that asks "start 40 files?" without saying whether that is four
    minutes or four hours is asking the user to guess.
    """

    RECORDS = [
        {"size_mb": 100.0, "duration": 50.0},   # 2 MB/s
        {"size_mb": 200.0, "duration": 50.0},   # 4 MB/s
        {"size_mb": 300.0, "duration": 100.0},  # 3 MB/s
    ]

    def test_throughput_is_measured_per_resolution_class(self):
        # 4K and 480p move very different amounts of data per second. Mixing
        # them produced an estimate seven times off on the first real run.
        records = [
            {"size_mb": 100.0, "duration": 10.0, "height": 480},
            {"size_mb": 100.0, "duration": 10.0, "height": 480},
            {"size_mb": 100.0, "duration": 10.0, "height": 480},
            {"size_mb": 100.0, "duration": 100.0, "height": 2160},
            {"size_mb": 100.0, "duration": 100.0, "height": 2160},
            {"size_mb": 100.0, "duration": 100.0, "height": 2160},
        ]
        assert history_throughput(records, height=480) == 10.0
        assert history_throughput(records, height=2160) == 1.0

    def test_a_class_without_history_gets_no_estimate(self):
        # Falling back to the overall median is how the wrong number appeared
        # in the first place.
        records = [{"size_mb": 100.0, "duration": 10.0, "height": 480}] * 3
        assert history_throughput(records, height=2160) is None

    def test_throughput_is_the_median_of_past_runs(self):
        assert history_throughput(self.RECORDS) == 3.0

    def test_too_few_samples_means_no_estimate(self):
        # Two runs are not a basis for a number the user will plan around.
        assert history_throughput(self.RECORDS[:2]) is None

    def test_records_without_timing_are_ignored(self):
        mixed = self.RECORDS + [{"size_mb": 10.0}, {"duration": 5.0}, {}]
        assert history_throughput(mixed) == 3.0

    def test_a_zero_duration_never_becomes_infinite_speed(self):
        assert history_throughput(self.RECORDS + [{"size_mb": 10.0, "duration": 0.0}]) == 3.0

    def test_runtime_follows_the_total_size(self):
        assert estimate_runtime_sec(300.0, 3.0) == 100.0

    def test_no_throughput_means_no_runtime(self):
        assert estimate_runtime_sec(300.0, None) is None


class TestReadEncodeHistory:
    """The raw history records, for callers that need more than one bucket."""

    def test_reads_back_what_was_written(self, tmp_path):
        path = tmp_path / "history.jsonl"
        append_encode_history({"file": "a.mp4", "size_mb": 100.0, "duration": 50.0}, path)
        append_encode_history({"file": "b.mp4", "size_mb": 200.0, "duration": 80.0}, path)
        records = read_encode_history(path)
        assert [r["file"] for r in records] == ["a.mp4", "b.mp4"]

    def test_a_damaged_line_does_not_lose_the_rest(self, tmp_path):
        # A half-written line from a killed run must not hide every record
        # written before it.
        path = tmp_path / "history.jsonl"
        append_encode_history({"file": "a.mp4"}, path)
        with open(path, "a", encoding="utf-8") as f:
            f.write("{not json\n")
        append_encode_history({"file": "c.mp4"}, path)
        assert [r["file"] for r in read_encode_history(path)] == ["a.mp4", "c.mp4"]

    def test_a_missing_history_is_simply_empty(self, tmp_path):
        assert read_encode_history(tmp_path / "nothing.jsonl") == []


class TestDiskHeadroom:
    """How much room a run needs before it starts.

    Nothing in the project ever looked at free space. Running out mid-encode
    produces a truncated file — caught by the integrity check, but the user
    sees a row of unexplained failures instead of the one sentence that
    explains all of them.
    """

    def test_a_run_needs_room_for_more_than_the_result(self):
        # The staging file of the current pass and the best one kept from an
        # earlier pass exist at the same time, and both can approach the size
        # of the source.
        assert disk_headroom_needed(1000) > 1000

    def test_the_estimate_scales_with_the_source(self):
        assert disk_headroom_needed(2000) == 2 * disk_headroom_needed(1000)

    def test_a_batch_needs_room_for_every_file_at_once(self):
        # Workers run in parallel, so their staging files coexist.
        assert disk_headroom_needed(1000, files=4) == 4 * disk_headroom_needed(1000)
