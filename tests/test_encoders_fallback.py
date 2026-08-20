"""Fallback-path coverage for encoders.detect_h264_encoder.

Deliberately outside test_encoders.py's ``skipif(ffmpeg missing)`` guard:
these tests patch ``subprocess.run`` directly, so they exercise the exact
"ffmpeg itself is not installed" code path (a bare ``FileNotFoundError`` from
the subprocess call) on every machine — including the CI/dev boxes without
ffmpeg where test_encoders.py's tests all skip. Without this file, nothing
would catch a regression where detect_h264_encoder stops swallowing that
error or returns something other than the ('libx264', [...]) fallback pair,
which would raise a TypeError on any caller doing
``codec, args = detect_h264_encoder()``.

Ported from the test suite of the project this encoder was extracted from,
which covered this scenario before the encoder moved into its own repo.
"""
import sys
from pathlib import Path
from unittest.mock import patch

REPO_ROOT = Path(__file__).parent.parent
if str(REPO_ROOT) not in sys.path:
    sys.path.insert(0, str(REPO_ROOT))

from encoders import detect_h264_encoder  # noqa: E402


@patch("subprocess.run", side_effect=FileNotFoundError)
def test_falls_back_to_libx264_when_ffmpeg_is_missing(_mock_run):
    """When ffmpeg can't even be found, still return a usable (codec, args) pair."""
    codec, args = detect_h264_encoder(log_fn=lambda _: None)
    assert codec == "libx264"
    assert isinstance(args, list)
    assert len(args) > 0


@patch("subprocess.run", side_effect=FileNotFoundError)
def test_no_log_fn_argument_does_not_crash(_mock_run):
    """Calling without an explicit log_fn (the caller's default) must not raise."""
    codec, args = detect_h264_encoder()
    assert isinstance(codec, str) and codec
    assert isinstance(args, list)
