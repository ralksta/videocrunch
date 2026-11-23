"""Unit tests for batch_controller output parsing (pure logic, no ffmpeg)."""
import sys
import threading
import time
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
        batch.file_results.clear()
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

    def test_cancelled_file_is_reported_as_cancelled(self, monkeypatch):
        # Not "failed": the wizard would count it as an error and offer a
        # quality-floor retry for a file nobody let finish.
        monkeypatch.setattr(batch, "build_optimizer_command",
                            lambda *a, **kw: [sys.executable, "-c", FAKE_WORKER])
        outcome = {}
        worker = threading.Thread(target=lambda: outcome.update(
            r=batch.run_optimizer(("/v/a.mov", None, "standard", None, None, False, "hevc", None, None, (), 1))))
        worker.start()
        for _ in range(100):
            if batch.active_workers:
                break
            time.sleep(0.05)
        time.sleep(0.3)  # let the fake worker install its handler
        batch.abort_workers()
        worker.join(timeout=10)
        _, ok, result = outcome["r"]
        assert not ok
        assert result["status"] == "cancelled"

    def test_file_never_started_is_cancelled_too(self):
        batch.abort_workers()
        _, ok, result = batch.run_optimizer(
            ("/v/a.mov", None, "standard", None, None, False, "hevc", None, None, (), 1))
        assert not ok
        assert result["status"] == "cancelled"


class TestProgressTracker:
    """Per-file progress, read from videocrunch.py's output into plain fields.

    The app used to regex its way through the redrawn terminal table: names
    cut to 30 characters, no idea which pass or phase a percentage belonged to.
    """

    def _feed(self, *lines):
        tracker = batch.ProgressTracker()
        changes = [tracker.feed(line) for line in lines]
        return tracker, changes

    def test_a_pass_starts_with_its_quality(self):
        tracker, _ = self._feed("\x1b[0;32mPass:\x1b[0m Q=65 (maxrate 8M)")
        assert tracker.state() == {"phase": "encode", "pass": 1, "q": 65, "percent": 0}

    def test_encode_percent_belongs_to_the_pass(self):
        tracker, _ = self._feed("Pass: Q=75", " hevc_videotoolbox [==>   ] 42% | 3.1x | 8M")
        assert tracker.state()["percent"] == 42

    def test_colour_codes_do_not_hide_the_figure(self):
        # videocrunch.py colours the number: "] \x1b[1;32m42%" — on real
        # encodes the bar stood at 0 % for the whole pass.
        tracker, _ = self._feed("Pass: Q=65",
                                " \x1b[0;32mhevc_videotoolbox\x1b[0m [####----] \x1b[1;32m42%\x1b[0m | 2x")
        assert tracker.state()["percent"] == 42

    def test_the_quality_check_is_its_own_phase(self):
        tracker, _ = self._feed("Pass: Q=75", " hevc [=====] 100%",
                                " -> Checking quality... [==>  ] 30%")
        assert tracker.state()["phase"] == "check"
        assert tracker.state()["percent"] == 30

    def test_the_next_pass_counts_up_and_restarts(self):
        tracker, _ = self._feed("Pass: Q=75", " hevc [=====] 100%", "Pass: Q=65")
        assert tracker.state() == {"phase": "encode", "pass": 2, "q": 65, "percent": 0}

    def test_savings_lines_are_not_progress(self):
        tracker, changes = self._feed("Pass: Q=75", " -> Result: Q=75 | Saved: 45.23% | SSIM: 0.98")
        assert tracker.state()["percent"] == 0
        assert changes[-1] is False

    def test_result_percentages_are_not_progress(self):
        # "(54.1%)" once read as 1 %: the bar fell back at the very end.
        tracker, _ = self._feed("Pass: Q=45", " hevc [=====] 100%",
                                "   -> Early exit: 54.1% savings is excellent!",
                                ">>> SUCCESS! 7.4 MB (54.1%) saved in 0:09.")
        assert tracker.state()["percent"] == 100

    def test_unchanged_percent_reports_no_change(self):
        _, changes = self._feed("Pass: Q=75", " hevc [=] 10%", " hevc [=] 10%")
        assert changes == [True, True, False]

    def test_before_the_first_pass_it_is_preparing(self):
        tracker, _ = self._feed("Analysing source...")
        assert tracker.state()["phase"] == "prepare"

    def test_live_speed_and_bitrate_are_extracted_and_cleared(self):
        tracker, changes = self._feed(
            "Pass: Q=75",
            " hevc_videotoolbox [==>   ] 42% | 3.1x | 6420kbits/s | 0:05 / 0:12",
        )
        assert changes == [True, True]
        assert tracker.state() == {
            "phase": "encode", "pass": 1, "q": 75, "percent": 42,
            "speed": "3.1x", "bitrate": "6420kbits/s",
        }
        # Zero/placeholder values are ignored rather than surfaced as 0x / 0kb/s.
        tracker.feed(" hevc_videotoolbox [==>   ] 45% | 0x | 0kb/s | 0:06 / 0:12")
        assert "speed" not in tracker.state()
        assert "bitrate" not in tracker.state()
        # Quality check and next pass clear live stats.
        tracker.feed(" hevc_videotoolbox [==>   ] 60% | 4.5x | 8.2M")
        assert tracker.state()["speed"] == "4.5x"
        assert tracker.state()["bitrate"] == "8.2M"
        tracker.feed(" -> Checking quality... [==>  ] 30%")
        assert tracker.state() == {"phase": "check", "pass": 1, "q": 75, "percent": 30}

    def test_milestones_emit_and_clear_detail_without_breaking_progress_state(self):
        tracker, changes = self._feed(
            "\x1b[0;33mBitrate Analysis:\x1b[0m Source avg=106400kbps, max=120000kbps, VBR=True",
            "\x1b[0;33mAudio Analysis:\x1b[0m measured -18.4 LUFS → standard",
            "\x1b[0;33mSample Windows:\x1b[0m 0:12, 1:40, 3:05 (bitrate hotspots)",
            "Pass: Q=65 (maxrate 8M)",
            " hevc_videotoolbox [==>   ] 42% | 4.8x | 11.2M",
            " hevc [Moving Atoms / Finalizing...] (12s)",
            " -> Integrity verified.",
        )
        assert changes == [True, True, True, True, True, True, True]

        # Intermediate check: a pass clears detail so basic state keys stay clean
        t2 = batch.ProgressTracker()
        t2.feed("Bitrate Analysis: Source avg=800kbps, max=1200kbps, VBR=False")
        assert t2.state()["detail"] == "Bitrate-Analyse · Ø 800 kbit/s"
        t2.feed("Sample Windows: 0:05, 0:20 (bitrate hotspots)")
        assert t2.state()["detail"] == "Qualitäts-Hotspots bestimmt (2 Stellen)"
        t2.feed("Pass: Q=75")
        assert t2.state() == {"phase": "encode", "pass": 1, "q": 75, "percent": 0}
        t2.feed(" hevc [Moving Atoms / Finalizing...] (2s)")
        assert t2.state()["detail"] == "Finalisiere MP4 (Faststart) …"
        assert tracker.state()["detail"] == "Integrität geprüft"

    def test_copy_mode_milestone_sets_detail(self):
        tracker, changed = self._feed(">>> COPY MODE: Skipping re-encode logic.")
        assert changed == [True]
        assert tracker.state()["detail"] == "Verlustfreier Stream Copy …"
        assert tracker.state()["detail_code"] == "copy_mode"
        assert tracker.state()["detail_args"] == {}

    def test_presearch_checking_quality_stays_in_prepare_phase(self):
        tracker = batch.ProgressTracker()
        assert tracker.feed("Pre-Search: probing quality on a 24s sample clip...") is True
        assert tracker.state() == {
            "phase": "prepare",
            "pass": 0,
            "q": None,
            "percent": 0,
            "detail": "Qualitäts-Vortest auf 24s-Stichprobe",
            "detail_code": "presearch_start",
            "detail_args": {"sec": "24"},
        }
        assert tracker.feed(" -> Checking quality... [==>  ] 32%") is False
        assert tracker.state()["phase"] == "prepare"
        assert tracker.state()["pass"] == 0
        assert tracker.state()["percent"] == 0
        assert tracker.feed("   probe Q=55: SSIM 0.9850, 1200k vs target 2000k") is True
        assert tracker.state()["phase"] == "prepare"
        assert tracker.state()["pass"] == 0
        assert tracker.state()["detail_code"] == "presearch_probe"
        assert tracker.state()["detail_args"] == {"q": "55", "ssim": "0.985"}

    def test_milestones_emit_structured_detail_code_and_args(self):
        cases = [
            ("\x1b[0;33mBitrate Analysis:\x1b[0m Source avg=106400kbps, max=120000kbps, VBR=True",
             "bitrate_analysis", {"avg": "106.4 Mbit/s", "vbr": "1"}),
            ("\x1b[0;33mAudio Analysis:\x1b[0m measured -18.4 LUFS → standard",
             "audio_loudness", {"lufs": "-18.4"}),
            ("\x1b[0;33mSample Windows:\x1b[0m 0:12, 1:40, 3:05 (bitrate hotspots)",
             "hotspots", {"count": "3"}),
            ("Constrained-VBR: maxrate=8000k",
             "bitrate_ladder", {}),
            (" hevc [Moving Atoms / Finalizing...] (12s)",
             "finalizing", {}),
            (" -> Integrity verified.",
             "integrity_verified", {}),
        ]
        for line, expected_code, expected_args in cases:
            t = batch.ProgressTracker()
            assert t.feed(line) is True
            assert t.state()["detail_code"] == expected_code
            assert t.state()["detail_args"] == expected_args


EVENT_WORKER = r"""
import sys
for line in ["Pass: Q=75", " hevc [==] 50%", " hevc [====] 100%",
             " -> Checking quality... [=] 60%", ">>> SUCCESS! 12.0 MB saved"]:
    print(line, flush=True)
"""


class TestEvents:
    """`--events`: one JSON object per line on stdout, for the app."""

    @pytest.fixture(autouse=True)
    def capture(self, monkeypatch):
        import io
        out = io.StringIO()
        monkeypatch.setattr(batch, "event_stream", out)
        batch.abort_requested.clear()
        batch.file_results.clear()
        yield out
        batch.event_stream = None

    def _events(self, out):
        import json
        return [json.loads(line) for line in out.getvalue().splitlines()]

    def test_a_file_reports_start_progress_and_result(self, capture, monkeypatch):
        monkeypatch.setattr(batch, "build_optimizer_command",
                            lambda *a, **kw: [sys.executable, "-c", EVENT_WORKER])
        batch.run_optimizer(("/v/Urlaub, Tag 1 mit langem Namen.mov", None, "standard",
                             None, None, False, "hevc", None, None, (), 2))
        events = self._events(capture)
        kinds = [e["event"] for e in events]
        assert kinds[0] == "file_start"
        assert kinds[-1] == "file_done"
        assert events[0]["file"] == "/v/Urlaub, Tag 1 mit langem Namen.mov"
        assert events[0]["worker"] == 2
        progress = [e for e in events if e["event"] == "progress"]
        assert {"phase": "check", "pass": 1, "q": 75, "percent": 60}.items() <= progress[-1].items()
        assert events[-1]["status"] == "success"

    def test_without_the_flag_nothing_is_emitted(self, capture, monkeypatch):
        monkeypatch.setattr(batch, "event_stream", None)
        batch.emit("start", total=1)  # must not raise
        assert capture.getvalue() == ""

    def test_the_flag_is_part_of_the_cli(self):
        args = batch.build_parser().parse_args(["--files=/a.mp4", "--events"])
        assert args.events is True

    def test_copy_mode_banner_is_not_treated_as_skipped(self, capture, monkeypatch):
        copy_worker = (
            "import json, sys\n"
            "from pathlib import Path\n"
            "out = sys.argv[sys.argv.index('--json-out') + 1]\n"
            "print('\\x1b[1;32m>>> COPY MODE: Skipping re-encode logic.\\x1b[0m', flush=True)\n"
            "print('\\x1b[1;32m>>> SUCCESS (COPY)! Saved to clip_trim.mp4 in 0:01.\\x1b[0m', flush=True)\n"
            "Path(out).write_text(json.dumps({'results': [{'status': 'success', "
            "'output_path': '/v/clip_trim.mp4', 'saved_bytes': 5000000, 'saved_pct': 50.0, "
            "'reason': 'Video Copy (Passthrough)', 'ssim': 1.0}]}))\n"
        )
        monkeypatch.setattr(
            batch, "build_optimizer_command",
            lambda file_path, port, audio_mode, min_ssim=None, json_out=None, **kw: [
                sys.executable, "-c", copy_worker, "--json-out", str(json_out),
            ],
        )
        _, ok, result = batch.run_optimizer(
            ("/v/clip.mov", None, "standard", None, None, False, "hevc", "0", "5", (), "copy", 1)
        )
        assert ok is True
        assert result["status"] == "success"
        assert result["output_path"] == "/v/clip_trim.mp4"
        assert result["saved_bytes"] == 5000000

    def test_real_skip_strips_ansi_and_reads_worker_json(self, capture, monkeypatch):
        skip_worker = (
            "import json, sys\n"
            "from pathlib import Path\n"
            "out = sys.argv[sys.argv.index('--json-out') + 1]\n"
            "print('\\x1b[0;33mSkipping:\\x1b[0m clip.mp4 (_opt.mp4 already exists)', flush=True)\n"
            "Path(out).write_text(json.dumps({'results': [{'status': 'skipped', "
            "'reason': 'Output file already exists'}]}))\n"
        )
        monkeypatch.setattr(
            batch, "build_optimizer_command",
            lambda file_path, port, audio_mode, min_ssim=None, json_out=None, **kw: [
                sys.executable, "-c", skip_worker, "--json-out", str(json_out),
            ],
        )
        _, ok, result = batch.run_optimizer(
            ("/v/clip.mov", None, "standard", None, None, False, "hevc", None, None, (), 1)
        )
        assert ok is True
        assert result["status"] == "skipped"
        assert "\x1b[" not in (result["reason"] or "")
        assert result["reason"] == "Output file already exists"

    def test_pass_result_and_verdict_events_and_saved_bytes(self, capture, monkeypatch):
        multi_pass_worker = (
            "import json, sys\n"
            "from pathlib import Path\n"
            "out = sys.argv[sys.argv.index('--json-out') + 1]\n"
            "lines = [\n"
            "  'Bitrate Analysis: Source avg=50000kbps, max=80000kbps, VBR=True',\n"
            "  'Pass: Q=55',\n"
            "  ' hevc [==] 50% | 4.2x | 5000kb/s',\n"
            "  ' -> Result: Q=55 | Saved: 68.40% | SSIM: 0.9681',\n"
            "  '   -> Quality too low for this level.',\n"
            "  'Pass: Q=65',\n"
            "  ' -> Result: Q=65 | Saved: 53.20% | SSIM: 0.9842',\n"
            "  '   -> Early exit: 53.2% savings is excellent! (cached)',\n"
            "  '>>> SUCCESS! 10.0 MB (53.2%) saved in 0:04.',\n"
            "]\n"
            "for ln in lines:\n"
            "    print(ln, flush=True)\n"
            "Path(out).write_text(json.dumps({'results': [{'status': 'success', "
            "'quality': 65, 'ssim': 0.9842, 'saved_pct': 53.2, 'saved_bytes': 10485760}]}))\n"
        )
        monkeypatch.setattr(
            batch, "build_optimizer_command",
            lambda file_path, port, audio_mode, min_ssim=None, json_out=None, **kw: [
                sys.executable, "-c", multi_pass_worker, "--json-out", str(json_out),
            ],
        )
        batch.run_optimizer(
            ("/v/clip.mov", None, "standard", None, None, False, "hevc", None, None, (), 1)
        )
        events = self._events(capture)
        pass_events = [e for e in events if e["event"] == "pass_result"]
        assert [(e["pass"], e["q"], e["verdict"]) for e in pass_events] == [
            (1, 55, "evaluated"),
            (1, 55, "too_low"),
            (2, 65, "evaluated"),
            (2, 65, "early_exit"),
        ]
        assert pass_events[-1]["ssim"] == 0.9842
        assert pass_events[-1]["saved_pct"] == 53.2
        done = [e for e in events if e["event"] == "file_done"][-1]
        assert done["saved_bytes"] == 10485760

    def test_poor_savings_emits_pass_result(self, capture, monkeypatch):
        poor_worker = (
            "import json, sys\n"
            "from pathlib import Path\n"
            "out = sys.argv[sys.argv.index('--json-out') + 1]\n"
            "print('Pass: Q=75', flush=True)\n"
            "print(' -> Saved only 3.45% – skipping SSIM (below 10% threshold). Not optimal.', flush=True)\n"
            "Path(out).write_text(json.dumps({'results': [{'status': 'failed', 'reason': 'No savings'}]}))\n"
        )
        monkeypatch.setattr(
            batch, "build_optimizer_command",
            lambda file_path, port, audio_mode, min_ssim=None, json_out=None, **kw: [
                sys.executable, "-c", poor_worker, "--json-out", str(json_out),
            ],
        )
        batch.run_optimizer(
            ("/v/small.mov", None, "standard", None, None, False, "hevc", None, None, (), 1)
        )
        events = self._events(capture)
        pass_events = [e for e in events if e["event"] == "pass_result"]
        assert len(pass_events) == 1
        assert pass_events[0]["verdict"] == "poor_savings"
        assert pass_events[0]["saved_pct"] == 3.5
        assert pass_events[0]["q"] == 75

    def test_13_tuple_with_output_dir_emits_integer_worker_id(self, capture, monkeypatch):
        seen_output_dirs = []

        def fake_cmd(file_path, port, audio_mode, min_ssim=None, json_out=None,
                     output_dir=None, **kw):
            seen_output_dirs.append(output_dir)
            return [sys.executable, "-c", EVENT_WORKER]

        monkeypatch.setattr(batch, "build_optimizer_command", fake_cmd)
        for idx, out_dir in enumerate((None, "/tmp/out")):
            capture.seek(0)
            capture.truncate(0)
            batch.run_optimizer(
                (f"/v/clip_{idx}.mov", None, "standard", None, None, False, "hevc",
                 None, None, (), "compress", 1, out_dir)
            )
            events = self._events(capture)
            file_start = [e for e in events if e["event"] == "file_start"]
            progress = [e for e in events if e["event"] == "progress"]
            file_done = [e for e in events if e["event"] == "file_done"]
            assert len(file_start) == 1
            assert len(progress) > 0
            assert len(file_done) == 1
            for e in file_start + progress + file_done:
                assert type(e["worker"]) is int and e["worker"] == 1
        assert seen_output_dirs == [None, "/tmp/out"]
