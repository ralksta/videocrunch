"""Unit tests for batch_controller output parsing (pure logic, no ffmpeg)."""
import subprocess
import sys
from pathlib import Path

import pytest

REPO_ROOT = Path(__file__).parent.parent
if str(REPO_ROOT) not in sys.path:
    sys.path.insert(0, str(REPO_ROOT))

import batch  # noqa: E402
from batch import terminal_verdict  # noqa: E402


class TestTerminalVerdict:
    """Only `>>> SUCCESS` / `>>> FAILED:` end a file. Everything else is chatter."""

    def test_success_line(self):
        assert terminal_verdict(" >>> SUCCESS! 102.1 MB (47.2%) saved in 3:11.") == \
            ("success", None)

    def test_fallback_success_line(self):
        assert terminal_verdict(" >>> SUCCESS (fallback)! 4.0 MB (14.1%) saved.")[0] == \
            "success"

    def test_failed_line_carries_the_reason(self):
        status, reason = terminal_verdict(
            " >>> FAILED: Binary search: no quality level produced acceptable results")
        assert status == "failed"
        assert reason == "Binary search: no quality level produced acceptable results"

    def test_failed_line_without_reason_gets_a_default(self):
        assert terminal_verdict(">>> FAILED")[1] == "Encoding failed"

    def test_rejected_ladder_rung_is_not_a_failure(self):
        # Regression: a run that rejects Q=55 and then succeeds at Q=45 was
        # reported as FAILED, even with the _opt.mp4 sitting on disk.
        assert terminal_verdict("    -> Quality too low for this level.") == (None, None)

    def test_aborted_pass_is_not_a_failure(self):
        assert terminal_verdict(
            " -> Size exceeded mid-encode (499.3 MB >= 498.7 MB). Aborting pass...") == \
            (None, None)

    def test_per_pass_result_is_not_a_verdict(self):
        assert terminal_verdict(" -> Result: Q=65 | Saved: 53.20% | SSIM: 0.9444") == \
            (None, None)

    def test_progress_line_is_not_a_verdict(self):
        assert terminal_verdict(
            " hevc_videotoolbox [████░░░░░░] 40% | 17.8x | 691kbits/s") == (None, None)

    def test_empty_line(self):
        assert terminal_verdict("") == (None, None)


# Stands in for videocrunch.py: same SIGTERM handling, says it is ready, then
# waits to be cancelled. SIGINT is ignored the way a background job inherits
# it, so only the real cancel path can end it with 7.
FAKE_WORKER = (
    "import signal, sys, time\n"
    f"sys.path.insert(0, {str(REPO_ROOT)!r})\n"
    "from videocrunch import abort_on_sigterm\n"
    "signal.signal(signal.SIGINT, signal.SIG_IGN)\n"
    "signal.signal(signal.SIGTERM, abort_on_sigterm)\n"
    "print('ready', flush=True)\n"
    "try:\n"
    "    time.sleep(30)\n"
    "except KeyboardInterrupt:\n"
    "    sys.exit(7)\n"
)


class TestAbort:
    """Cancelling the batch must stop the encodes, not just batch.py.

    The wizard cancels with SIGTERM. Without forwarding, batch.py died and
    every videocrunch.py with its ffmpeg kept encoding on its own.
    """

    @pytest.fixture(autouse=True)
    def fresh_state(self):
        batch.abort_requested.clear()
        batch.active_workers.clear()
        yield
        for process in list(batch.active_workers):
            process.kill()
        batch.abort_requested.clear()
        batch.active_workers.clear()

    def _start(self):
        process = batch.start_worker([sys.executable, "-c", FAKE_WORKER])
        assert process.stdout.readline().strip() == "ready"
        return process

    def test_running_worker_gets_its_own_abort_path(self):
        # Ends in videocrunch.py's KeyboardInterrupt path, which stops ffmpeg
        # and removes the half-written pass.
        process = self._start()
        batch.abort_workers()
        assert process.wait(timeout=10) == 7

    def test_no_new_worker_starts_after_abort(self):
        batch.abort_workers()
        assert batch.start_worker([sys.executable, "-c", FAKE_WORKER]) is None

    def test_finished_worker_is_forgotten(self):
        process = self._start()
        process.kill()
        process.wait()
        batch.finish_worker(process)
        assert process not in batch.active_workers
