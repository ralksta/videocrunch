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
import sys
from pathlib import Path

import pytest

REPO_ROOT = Path(__file__).parent.parent
if str(REPO_ROOT) not in sys.path:
    sys.path.insert(0, str(REPO_ROOT))

import batch  # noqa: E402
import videocrunch  # noqa: E402


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
        assert assignment in source, (
            "process_file no longer writes <stem>_opt.mp4 — remote workers "
            "look for exactly that name and will report a bogus failure")

    def test_encoder_profiles_expose_a_name(self):
        for key, profile in videocrunch.ENCODER_PROFILES.items():
            assert "name" in profile, f"profile {key!r} has no 'name' — callers print it"
