"""The documented invocation contract.

videocrunch is designed to be driven by other software, not only by hand: a
media server or dashboard shells out to `videocrunch.py` per file, or to
`batch.py` for a whole selection, and is told about finished files through
`--port` (`GET /api/mark_optimized?path=<path>`). `mac_worker`-style remote
runners go one step further and import `process_file` directly.

That makes the CLI flags, the `process_file` keyword names and the `_opt.mp4`
output suffix a public interface, not implementation detail. Renaming a flag,
reordering a keyword or changing the output suffix breaks every caller, and
without these tests it would break them silently — the callers live in other
processes, so nothing here would go red.

If a test in this file fails, the change is a breaking change to the
documented interface. That is allowed, but it must be a deliberate release
decision (README + docs/technical-reference.md updated, callers notified) and
never an accidental side effect of a refactor.
"""
import inspect
import json
import sys
from pathlib import Path

import pytest

REPO_ROOT = Path(__file__).parent.parent
if str(REPO_ROOT) not in sys.path:
    sys.path.insert(0, str(REPO_ROOT))

import batch  # noqa: E402
import videocrunch  # noqa: E402


class TestEncoderChoices:
    """Every encoder profile must be selectable by name.

    A profile that `--encoder` rejects is unreachable on purpose-built
    hardware: auto-detection may pick it, but the user cannot force it, and
    cannot override a wrong guess. VAAPI was in exactly that state.
    """

    def test_every_profile_is_an_accepted_encoder_choice(self):
        parser = videocrunch.build_parser()
        action = next(a for a in parser._actions if a.dest == "encoder")
        missing = set(videocrunch.ENCODER_PROFILES) - set(action.choices)
        assert not missing, f"profiles unreachable via --encoder: {sorted(missing)}"

    def test_auto_stays_available(self):
        parser = videocrunch.build_parser()
        action = next(a for a in parser._actions if a.dest == "encoder")
        assert "auto" in action.choices
        assert parser.parse_args(["/videos/a.mp4"]).encoder == "auto"

    def test_each_profile_name_round_trips(self):
        for key in videocrunch.ENCODER_PROFILES:
            args = videocrunch.build_parser().parse_args(["/videos/a.mp4", "--encoder", key])
            assert args.encoder == key


class TestSingleFileInvocation:
    """`videocrunch.py FILE --port … --audio-mode … --video-mode … --preset … --codec …`"""

    def test_full_documented_vector_parses(self):
        args = videocrunch.build_parser().parse_args([
            "/videos/clip.mp4",
            "--port", "8000",
            "--audio-mode", "enhanced",
            "--video-mode", "compress",
            "--preset", "balanced",
            "--codec", "hevc",
        ])
        assert args.files == ["/videos/clip.mp4"]
        assert args.port == 8000
        assert args.audio_mode == "enhanced"
        assert args.video_mode == "compress"
        assert args.preset == "balanced"
        assert args.codec == "hevc"

    def test_optional_trim_and_quality_flags_parse(self):
        args = videocrunch.build_parser().parse_args([
            "/videos/clip.mp4",
            "--port", "8000",
            "--audio-mode", "standard",
            "--video-mode", "copy",
            "--preset", "best",
            "--codec", "av1",
            "--ss", "00:00:10",
            "--to", "00:00:20",
            "--q", "65",
        ])
        assert args.ss == "00:00:10"
        assert args.to == "00:00:20"
        assert args.q == 65
        assert args.codec == "av1"
        assert args.video_mode == "copy"

    @pytest.mark.parametrize("value", ["enhanced", "standard", "moderate"])
    def test_audio_modes_callers_send(self, value):
        assert videocrunch.build_parser().parse_args(
            ["f.mp4", "--audio-mode", value]).audio_mode == value

    @pytest.mark.parametrize("value", ["compress", "copy"])
    def test_video_modes_callers_send(self, value):
        assert videocrunch.build_parser().parse_args(
            ["f.mp4", "--video-mode", value]).video_mode == value

    @pytest.mark.parametrize("value", ["fast", "balanced", "best"])
    def test_presets_callers_send(self, value):
        assert videocrunch.build_parser().parse_args(
            ["f.mp4", "--preset", value]).preset == value

    @pytest.mark.parametrize("value", ["hevc", "av1"])
    def test_codecs_callers_send(self, value):
        assert videocrunch.build_parser().parse_args(
            ["f.mp4", "--codec", value]).codec == value

    def test_scale_height_used_by_the_finder_wrapper(self):
        assert videocrunch.build_parser().parse_args(
            ["f.mp4", "--scale-height", "1080"]).scale_height == 1080


class TestQualityFloorOverride:
    """`--min-ssim` lets a caller move the hard quality floor for one run.

    The default floor (SSIM_MIN) is calibrated for 1080p gameplay captures.
    Material it was never calibrated for — heavily downscaled high-fps real
    footage, for instance — can be visually fine and still land under it, so
    the floor has to be steerable from the outside without editing the source.
    """

    def test_floor_override_parses(self):
        args = videocrunch.build_parser().parse_args(["f.mp4", "--min-ssim", "0.88"])
        assert args.min_ssim == 0.88

    def test_absent_override_keeps_the_built_in_floor(self):
        assert videocrunch.build_parser().parse_args(["f.mp4"]).min_ssim is None

    @pytest.mark.parametrize("value", ["1.5", "0", "-0.2", "94"])
    def test_impossible_floors_are_rejected(self, value):
        # An SSIM score is in (0, 1]; a floor outside it either rejects every
        # encode or accepts every encode. Both are silent disasters.
        with pytest.raises(SystemExit):
            videocrunch.build_parser().parse_args(["f.mp4", "--min-ssim", value])

    def test_override_also_moves_the_fallback_retention_floor(self):
        # The linear search keeps a not-quite-ideal pass only if it clears
        # SSIM_ACCEPTABLE. Were the override to leave that alone, lowering the
        # floor would delete exactly the passes it was meant to rescue: they
        # now clear the floor, so the interactive rescue never fires either.
        assert videocrunch.retention_floor(0.88) == 0.88
        assert videocrunch.retention_floor(0.99) == 0.99

    def test_without_an_override_retention_keeps_its_own_tuning(self):
        assert videocrunch.retention_floor(None) == videocrunch.SSIM_ACCEPTABLE

    def test_process_file_takes_the_floor_as_a_keyword(self):
        params = inspect.signature(videocrunch.process_file).parameters
        assert "min_ssim" in params
        assert params["min_ssim"].default is None


class TestBatchInvocation:
    """`batch.py --files=a,b,c --port=8000 [--audio-mode=…]` — note the `=` form."""

    def test_equals_form_parses(self):
        args = batch.build_parser().parse_args([
            "--files=/a.mp4,/b.mp4",
            "--port=8000",
        ])
        assert args.files == "/a.mp4,/b.mp4"
        assert args.port == 8000

    def test_audio_mode_parses(self):
        args = batch.build_parser().parse_args(
            ["--files=/a.mp4", "--port=8000", "--audio-mode=standard"])
        assert args.audio_mode == "standard"

    def test_files_is_comma_separated_and_required(self):
        with pytest.raises(SystemExit):
            batch.build_parser().parse_args(["--port=8000"])


class TestRejectedResult:
    """What a failed run leaves the user with.

    A run that ends under the quality floor throws away the encode it just
    spent minutes producing, and the message names neither the measured value
    nor the flag that would accept it. The user repeats the whole run to learn
    what the tool already knew.
    """

    def test_hint_names_a_floor_the_result_would_clear(self):
        # Rounding must go DOWN: suggesting 0.86 for a result of 0.8519 sends
        # the user into a second run that fails exactly like the first.
        assert videocrunch.suggested_floor(0.8519) == 0.85
        assert videocrunch.suggested_floor(0.9399) == 0.93

    def test_hint_never_suggests_a_floor_above_the_measurement(self):
        for value in (0.8519, 0.9, 0.93001, 0.999, 0.5):
            assert videocrunch.suggested_floor(value) <= value

    def test_hint_carries_the_measurement_and_the_command(self):
        hint = videocrunch.rejection_hint(quality=65, ssim=0.8519, floor=0.940,
                                          saved_pct=76.0, path=Path("/v/IMG_1438_rejected.mp4"))
        assert "0.8519" in hint
        assert "--min-ssim 0.85" in hint
        assert "IMG_1438_rejected.mp4" in hint


class TestReplaceOriginal:
    """`--replace` closes the loop: the library gets smaller, not bigger.

    Without it a run leaves `<name>_opt.mp4` next to the original and the
    folder grows. Since this touches the user's own files, the original goes
    to the trash — recoverable — and anything ambiguous is refused rather than
    guessed.
    """

    def test_extension_follows_the_container(self, tmp_path):
        # The output is mp4 whatever the source was; a .mov named file holding
        # mp4 would lie about itself.
        target, reason = videocrunch.plan_replacement(tmp_path / "IMG_1438.mov")
        assert target == tmp_path / "IMG_1438.mp4" and reason is None

    def test_same_extension_replaces_in_place(self, tmp_path):
        source = tmp_path / "clip.mp4"
        source.touch()
        target, reason = videocrunch.plan_replacement(source)
        assert target == source and reason is None

    def test_refuses_to_overwrite_an_unrelated_file(self, tmp_path):
        # IMG_1438.mov and IMG_1438.mp4 side by side are two different videos.
        # Replacing the first must not silently destroy the second.
        (tmp_path / "IMG_1438.mov").touch()
        (tmp_path / "IMG_1438.mp4").touch()
        target, reason = videocrunch.plan_replacement(tmp_path / "IMG_1438.mov")
        assert target is None
        assert "IMG_1438.mp4" in reason

    def test_original_lands_in_the_trash_under_its_own_name(self, tmp_path):
        # Asking the Finder to delete looked simpler, but for files in some
        # locations it bypasses the trash and deletes outright — while still
        # reporting success. Moving the file ourselves is the only way to know
        # where it ended up.
        trash = tmp_path / "Trash"
        trash.mkdir()
        source = tmp_path / "clip.mov"
        source.write_bytes(b"data")
        landed = videocrunch.move_to_trash(source, trash_root=trash)
        assert landed == trash / "clip.mov"
        assert landed.read_bytes() == b"data"
        assert not source.exists()

    def test_an_occupied_name_in_the_trash_is_not_overwritten(self, tmp_path):
        trash = tmp_path / "Trash"
        trash.mkdir()
        (trash / "clip.mov").write_bytes(b"older file")
        source = tmp_path / "clip.mov"
        source.write_bytes(b"newer file")
        landed = videocrunch.move_to_trash(source, trash_root=trash)
        assert landed != trash / "clip.mov"
        assert (trash / "clip.mov").read_bytes() == b"older file"
        assert landed.read_bytes() == b"newer file"

    def test_unusable_trash_reports_failure_instead_of_deleting(self, tmp_path):
        # No trash to move into must mean "original kept", never "deleted".
        source = tmp_path / "clip.mov"
        source.write_bytes(b"data")
        assert videocrunch.move_to_trash(source, trash_root=tmp_path / "missing") is None
        assert source.exists()

    def test_a_trim_never_replaces_its_source(self):
        # --ss/--to produce a DIFFERENT video. Replacing the source with an
        # excerpt of itself destroys everything outside the excerpt.
        assert videocrunch.should_replace(True, "compress", is_trim=True) is False

    def test_copy_mode_never_replaces_its_source(self):
        # Copy mode exists to produce a second file (trim/passthrough).
        assert videocrunch.should_replace(True, "copy", is_trim=False) is False

    def test_a_plain_re_encode_replaces_when_asked(self):
        assert videocrunch.should_replace(True, "compress", is_trim=False) is True

    def test_nothing_is_replaced_without_the_flag(self):
        assert videocrunch.should_replace(False, "compress", is_trim=False) is False

    def test_flag_parses_and_defaults_to_off(self):
        assert videocrunch.build_parser().parse_args(["f.mp4"]).replace is False
        assert videocrunch.build_parser().parse_args(["f.mp4", "--replace"]).replace is True

    def test_process_file_takes_it_as_a_keyword(self):
        params = inspect.signature(videocrunch.process_file).parameters
        assert params["replace"].default is False


class TestAbortKeepsWork:
    """Ctrl-C must not silently throw away finished passes — nor litter.

    Interrupting used to delete every staging file, so a run stopped between
    two 4K passes paid for them again on the next attempt. Keeping them is
    only right if the user is there to say so: a script that dies unattended
    should leave the folder as it found it.
    """

    def test_asks_and_keeps_on_yes(self):
        assert videocrunch.keep_stagings_after_abort(
            ["a._staging_q65.mp4"], is_interactive=True, ask=lambda: "j") is True

    def test_default_is_to_clean_up(self):
        # Empty answer = the user just pressed Enter after Ctrl-C.
        assert videocrunch.keep_stagings_after_abort(
            ["a._staging_q65.mp4"], is_interactive=True, ask=lambda: "") is False

    def test_never_asks_when_nobody_is_watching(self):
        def must_not_be_called():
            raise AssertionError("asked without a terminal")
        assert videocrunch.keep_stagings_after_abort(
            ["a._staging_q65.mp4"], is_interactive=False, ask=must_not_be_called) is False

    def test_nothing_to_keep_means_no_question(self):
        def must_not_be_called():
            raise AssertionError("asked with no staging files")
        assert videocrunch.keep_stagings_after_abort(
            [], is_interactive=True, ask=must_not_be_called) is False

    def test_an_unanswerable_prompt_cleans_up(self):
        # Ctrl-C twice, or a closed stdin: no answer means no leftovers.
        def interrupted():
            raise EOFError
        assert videocrunch.keep_stagings_after_abort(
            ["a._staging_q65.mp4"], is_interactive=True, ask=interrupted) is False


class TestJsonResult:
    """`--json-out PATH` — the machine-readable result of a run.

    Callers today learn the outcome by matching strings in stdout (`batch.py`)
    or not at all (the scanner launches the encoder in its own Terminal window
    and never sees its output). Both are accidents waiting to happen: an
    output line is a human-facing thing that may be reworded any day. The JSON
    file is the contract instead, so its shape is pinned here.
    """

    RESULT_KEYS = {
        "filename", "input_path", "output_path", "status", "quality", "ssim",
        "saved_pct", "saved_bytes", "duration", "reason",
    }

    def test_flag_parses(self):
        args = videocrunch.build_parser().parse_args(["f.mp4", "--json-out", "/tmp/r.json"])
        assert args.json_out == "/tmp/r.json"

    def test_absent_flag_stays_unset(self):
        assert videocrunch.build_parser().parse_args(["f.mp4"]).json_out is None

    def test_written_file_carries_the_documented_shape(self, tmp_path):
        target = tmp_path / "r.json"
        videocrunch.write_json_result(target, [dict(videocrunch.last_encode_result)])
        payload = json.loads(target.read_text())
        assert isinstance(payload["results"], list)
        assert self.RESULT_KEYS <= set(payload["results"][0])

    def test_paths_are_absolute(self, tmp_path, monkeypatch):
        # Consumers run from their own working directory; a relative path in
        # the result file points at nothing there.
        monkeypatch.chdir(tmp_path)
        clip = tmp_path / "clip.mp4"
        clip.write_bytes(b"")
        videocrunch.process_file("clip.mp4", videocrunch.ENCODER_PROFILES["libx265"])
        assert Path(videocrunch.last_encode_result["input_path"]).is_absolute()

    def test_unwritable_target_does_not_raise(self, tmp_path):
        # A result file the caller cannot receive must never take down an
        # encode that already succeeded.
        assert videocrunch.write_json_result(tmp_path / "nope" / "r.json", []) is False


class TestBatchReadsJsonResult:
    """`batch.py` takes the worker's verdict from its result file."""

    def test_json_out_reaches_the_per_file_command(self, tmp_path):
        cmd = batch.build_optimizer_command("/a.mp4", port=None, audio_mode="standard",
                                            json_out=tmp_path / "r.json")
        assert cmd[cmd.index("--json-out") + 1] == str(tmp_path / "r.json")

    def test_result_file_is_read_back(self, tmp_path):
        target = tmp_path / "r.json"
        target.write_text(json.dumps({"results": [{"status": "success", "ssim": 0.97}]}))
        assert batch.read_worker_result(target)["ssim"] == 0.97

    def test_missing_file_falls_back_to_stdout_parsing(self, tmp_path):
        assert batch.read_worker_result(tmp_path / "gone.json") is None

    def test_unreadable_file_falls_back_to_stdout_parsing(self, tmp_path):
        target = tmp_path / "broken.json"
        target.write_text("{not json")
        assert batch.read_worker_result(target) is None

    def test_workers_own_verdict_wins_over_scraped_output(self):
        # Scraping reads rounded, human-facing numbers off the screen; the
        # worker knows the real ones.
        scraped = {"status": "success", "ssim": 0.98, "saved_pct": 45.2, "reason": None}
        assert batch.merge_worker_result(scraped, {"status": "failed", "ssim": 0.9123,
                                                   "reason": "Quality too low"}) is True
        assert scraped["status"] == "failed"
        assert scraped["ssim"] == 0.9123
        assert scraped["reason"] == "Quality too low"

    def test_without_a_verdict_the_scraped_values_stand(self):
        scraped = {"status": "success", "ssim": 0.98}
        assert batch.merge_worker_result(scraped, None) is False
        assert scraped["status"] == "success"


class TestBatchQualityFloorForwarding:
    """`batch.py --min-ssim=…` must reach every per-file `videocrunch.py` call.

    The batch controller shells out once per file. A floor it accepts but
    never forwards is worse than no flag at all: the run looks configured and
    every file is still judged against the built-in default.
    """

    def test_floor_parses_in_the_equals_form_callers_use(self):
        args = batch.build_parser().parse_args(["--files=/a.mp4", "--min-ssim=0.85"])
        assert args.min_ssim == 0.85

    def test_absent_floor_stays_unset(self):
        assert batch.build_parser().parse_args(["--files=/a.mp4"]).min_ssim is None

    @pytest.mark.parametrize("value", ["1.4", "0", "-1"])
    def test_impossible_floors_are_rejected(self, value):
        with pytest.raises(SystemExit):
            batch.build_parser().parse_args(["--files=/a.mp4", f"--min-ssim={value}"])

    def test_floor_reaches_the_per_file_command(self):
        cmd = batch.build_optimizer_command("/a.mp4", port=8000,
                                            audio_mode="standard", min_ssim=0.85)
        assert cmd[cmd.index("--min-ssim") + 1] == "0.85"

    def test_without_an_override_the_command_carries_no_floor(self):
        cmd = batch.build_optimizer_command("/a.mp4", port=8000,
                                            audio_mode="standard", min_ssim=None)
        assert "--min-ssim" not in cmd

    def test_command_still_carries_the_documented_basics(self):
        cmd = batch.build_optimizer_command("/a.mp4", port=8000,
                                            audio_mode="standard", min_ssim=None)
        assert cmd[2] == "/a.mp4"
        assert cmd[cmd.index("--audio-mode") + 1] == "standard"
        assert cmd[cmd.index("--port") + 1] == "8000"


class TestProcessFileImportContract:
    """Remote workers import `process_file` and read back `<stem>_opt.mp4`."""

    REQUIRED_KWARGS = {
        "input_path", "profile", "min_size_mb", "copy_audio", "audio_mode",
        "video_mode", "force", "progress_callback", "port", "ss", "to",
        "q_override", "scale_height",
    }

    def test_symbols_are_importable(self):
        from videocrunch import ENCODER_PROFILES, detect_encoder, process_file
        assert callable(detect_encoder)
        assert callable(process_file)
        assert isinstance(ENCODER_PROFILES, dict) and ENCODER_PROFILES

    def test_keyword_names_are_stable(self):
        params = inspect.signature(videocrunch.process_file).parameters
        missing = self.REQUIRED_KWARGS - set(params)
        assert not missing, f"process_file lost documented keyword(s): {sorted(missing)}"

    def test_output_suffix_is_opt_mp4(self):
        """The name callers glob for. Grepped, not called: process_file shells out.

        Matches the assignment, not any mention of the string — a log line
        saying "_opt.mp4 already exists" must not keep this test green after
        the real output name changed.
        """
        source = inspect.getsource(videocrunch.process_file)
        assignment = 'output_path = input_path.parent / f"{input_path.stem}_opt.mp4"'
        count = source.count(assignment)
        assert count >= 2, (
            "process_file must write <stem>_opt.mp4 in all non-trim-only branches "
            "(is_trim and else branches); remote workers depend on this name and "
            f"will report a bogus failure if it changes. Found {count} occurrence(s)")

    def test_encoder_profiles_expose_a_name(self):
        for key, profile in videocrunch.ENCODER_PROFILES.items():
            assert "name" in profile, f"profile {key!r} has no 'name' — callers print it"
