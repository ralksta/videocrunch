#!/usr/bin/env python3
"""
Batch Controller V2.1 - Clean Summary Table Display with Logging
Shows a live-updating status table for all parallel encodes.
Writes detailed results to a persistent log file.
"""
import argparse
import json
import os
import re
import signal
import subprocess
import sys
import tempfile
import threading
import time
from concurrent.futures import ThreadPoolExecutor, as_completed
from datetime import datetime
from pathlib import Path

from crunch_utils import default_log_dir, valid_live_bitrate, valid_live_speed  # noqa: E402
from encoders import get_best_h264_encoder as get_best_encoder  # noqa: E402
from encoders import get_optimal_workers  # noqa: E402
from videocrunch import quality_floor  # noqa: E402

# Logs directory
LOG_DIR = default_log_dir()
try:
    LOG_DIR.mkdir(parents=True, exist_ok=True)
except OSError:
    pass

# --- COLORS ---
G = '\033[0;32m'
BG = '\033[1;32m'
R = '\033[0;31m'
Y = '\033[0;33m'
NC = '\033[0m'
CYAN = '\033[0;36m'
DIM = '\033[2m'
CLEAR_LINE = '\033[K'

# Shared state for display
worker_status = {}  # {worker_id: {"file": str, "status": str, "progress": int, "q": int}}
stats = {"completed": 0, "succeeded": 0, "failed": 0, "total": 0}
file_results = []  # Detailed results for logging: [{filename, status, quality, ssim, saved_pct, duration}]
display_lock = threading.Lock()
stop_display = threading.Event()

# Running videocrunch.py processes, so a cancel can reach them. Only worker
# threads and the signal handler take workers_lock, never the main loop, so
# the handler cannot deadlock on a lock its own thread already holds.
active_workers = set()
workers_lock = threading.Lock()
abort_requested = threading.Event()

# --events: one JSON object per line goes here instead of the redrawn table.
event_stream = None
event_lock = threading.Lock()

# Only a progress bar's figure: "] 42%". Result lines carry percentages too.
PERCENT_RE = re.compile(r'\]\s*(\d+)%')
PASS_RE = re.compile(r'Pass:\s+Q=(\d+)')
ANSI_RE = re.compile(r'\x1b\[[0-9;]*[A-Za-z]')
BITRATE_ANALYSIS_RE = re.compile(
    r'Bitrate Analysis:\s*Source avg=([\d.]+)kbps(?:,\s*max=([\d.]+)kbps)?(?:,\s*VBR=(True|False))?'
)
AUDIO_ANALYSIS_RE = re.compile(r'Audio Analysis:\s*measured\s*(-?[\d.]+)\s*LUFS')
SAMPLE_WINDOWS_RE = re.compile(r'Sample Windows:\s*(.+?)\s*\(bitrate hotspots\)')
PRESEARCH_START_RE = re.compile(r'Pre-Search:\s*probing quality on a\s*([\d.]+)s sample clip')
PRESEARCH_PROBE_RE = re.compile(r'probe Q=(\d+):\s*SSIM\s*([\d.]+)')
RESULT_LINE_RE = re.compile(
    r'->\s*Result:\s*Q=(\d+)\s*\|\s*Saved:\s*(-?[\d.]+)%\s*\|\s*(SSIM|VMAF|PSNR):\s*([\d.]+)'
)
POOR_SAVINGS_RE = re.compile(r'->\s*Saved only\s*(-?[\d.]+)%')


def emit(event: str, **fields) -> None:
    """Write one machine-readable event, if --events asked for them."""
    stream = event_stream
    if stream is None:
        return
    with event_lock:
        stream.write(json.dumps({"event": event, **fields}, ensure_ascii=False) + "\n")
        stream.flush()


def _detail_info_from_line(clean_line: str) -> tuple[str, str, dict[str, str]] | None:
    """Turn milestone log lines into (German text, localization code, args)."""
    m = BITRATE_ANALYSIS_RE.search(clean_line)
    if m:
        avg = float(m.group(1))
        avg_str = f"{avg / 1000:.1f} Mbit/s" if avg >= 1000 else f"{int(round(avg))} kbit/s"
        is_vbr = m.group(3) == "True"
        vbr = " (VBR)" if is_vbr else ""
        return (f"Bitrate-Analyse · Ø {avg_str}{vbr}", "bitrate_analysis",
                {"avg": avg_str, "vbr": "1" if is_vbr else "0"})

    m = AUDIO_ANALYSIS_RE.search(clean_line)
    if m:
        lufs = m.group(1)
        return (f"Audio-Lautheit gemessen ({lufs} LUFS)", "audio_loudness", {"lufs": lufs})

    m = SAMPLE_WINDOWS_RE.search(clean_line)
    if m:
        count = len([p for p in m.group(1).split(",") if p.strip()])
        return (f"Qualitäts-Hotspots bestimmt ({count} Stellen)", "hotspots", {"count": str(count)})

    if "Constrained-VBR:" in clean_line:
        return ("Bitraten-Leiter berechnet", "bitrate_ladder", {})

    m = PRESEARCH_START_RE.search(clean_line)
    if m:
        sec = str(int(round(float(m.group(1)))))
        return (f"Qualitäts-Vortest auf {sec}s-Stichprobe", "presearch_start", {"sec": sec})

    m = PRESEARCH_PROBE_RE.search(clean_line)
    if m:
        q = m.group(1)
        ssim = f"{float(m.group(2)):.3f}"
        return (f"Vortest Q={q} · SSIM {ssim}", "presearch_probe", {"q": q, "ssim": ssim})

    if ">>> COPY MODE:" in clean_line:
        return ("Verlustfreier Stream Copy …", "copy_mode", {})
    if "[Moving Atoms / Finalizing...]" in clean_line:
        return ("Finalisiere MP4 (Faststart) …", "finalizing", {})
    if "-> Integrity verified." in clean_line:
        return ("Integrität geprüft", "integrity_verified", {})
    return None


def _detail_from_line(clean_line: str) -> str | None:
    """Turn milestone log lines into short German live status subtitles."""
    info = _detail_info_from_line(clean_line)
    return info[0] if info is not None else None


def parse_pass_event(clean_line: str, current_pass: int, current_q: int | None,
                     last_pass_event: dict | None) -> dict | None:
    """Extract a structured pass_result payload from a worker output line, if any."""
    m = RESULT_LINE_RE.search(clean_line)
    if m:
        return {
            "pass": max(current_pass, 1),
            "q": int(m.group(1)),
            "saved_pct": round(float(m.group(2)), 1),
            "metric": m.group(3),
            "ssim": round(float(m.group(4)), 4),
            "verdict": "evaluated",
        }

    m = POOR_SAVINGS_RE.search(clean_line)
    if m:
        return {
            "pass": max(current_pass, 1),
            "q": current_q,
            "saved_pct": round(float(m.group(1)), 1),
            "metric": None,
            "ssim": None,
            "verdict": "poor_savings",
        }

    if last_pass_event is not None:
        if "-> Quality too low" in clean_line:
            return {**last_pass_event, "verdict": "too_low"}
        if "-> Early exit:" in clean_line:
            return {**last_pass_event, "verdict": "early_exit"}
        if "quality short" in clean_line:
            return {**last_pass_event, "verdict": "quality_short"}

    return None


class ProgressTracker:
    """Where one videocrunch.py run is: phase, pass, quality and percent.

    A pass starts with its "Pass: Q=…" line; the SSIM check that follows each
    pass reports its own percentage, so the two are told apart rather than
    read as one bar jumping back and forth.
    """

    def __init__(self):
        self.phase, self.passes, self.q, self.percent = "prepare", 0, None, 0
        self.speed: str | None = None
        self.bitrate: str | None = None
        self.detail: str | None = None
        self.detail_code: str | None = None
        self.detail_args: dict[str, str] | None = None

    def state(self) -> dict:
        s = {"phase": self.phase, "pass": self.passes, "q": self.q,
             "percent": self.percent}
        if self.speed is not None:
            s["speed"] = self.speed
        if self.bitrate is not None:
            s["bitrate"] = self.bitrate
        if self.detail is not None:
            s["detail"] = self.detail
        if self.detail_code is not None:
            s["detail_code"] = self.detail_code
        if self.detail_args is not None:
            s["detail_args"] = self.detail_args
        return s

    def _clear_detail(self) -> None:
        self.detail = None
        self.detail_code = None
        self.detail_args = None

    def feed(self, line: str) -> bool:
        """Take one output line; True when the state changed."""
        before = self.state()
        line = ANSI_RE.sub('', line)
        match = PASS_RE.search(line)
        if match:
            self.phase, self.passes = "encode", self.passes + 1
            self.q, self.percent = int(match.group(1)), 0
            self.speed, self.bitrate = None, None
            self._clear_detail()
        else:
            match = PERCENT_RE.search(line)
            if match:
                if "Checking quality" in line:
                    # Pre-search SSIM checks run while passes == 0; stay in prepare
                    # rather than spoofing "Pass 1 · Quality Check".
                    if self.passes == 0:
                        self.phase = "prepare"
                        return False
                    self.phase = "check"
                    self.speed, self.bitrate = None, None
                    self.percent = min(100, int(match.group(1)))
                    self._clear_detail()
                else:
                    parts = [p.strip() for p in line[match.end():].split("|") if p.strip()]
                    self.speed = valid_live_speed(parts[0]) if len(parts) >= 1 else None
                    self.bitrate = valid_live_bitrate(parts[1]) if len(parts) >= 2 else None
                    self.percent = min(100, int(match.group(1)))
                    self._clear_detail()
            else:
                info = _detail_info_from_line(line)
                if info is not None:
                    self.detail, self.detail_code, self.detail_args = info
        return self.state() != before


def truncate(text, max_len=35):
    """Truncate text with ellipsis."""
    if len(text) <= max_len:
        return text
    return text[:max_len-3] + "..."


def draw_table(start_time, max_workers):
    """Draw the status table (called repeatedly)."""
    elapsed = time.time() - start_time
    mins, secs = divmod(int(elapsed), 60)

    lines = []
    lines.append(f"{BG}┌{'─'*62}┐{NC}")
    lines.append(f"{BG}│{NC} 🎮 {CYAN}BATCH ENCODER{NC} - {stats['total']} files, {max_workers} workers" + " " * 20 + f"{BG}│{NC}")
    lines.append(f"{BG}├{'─'*62}┤{NC}")

    with display_lock:
        for wid in sorted(worker_status.keys()):
            ws = worker_status[wid]
            filename = truncate(ws.get("file", ""), 30)
            status = ws.get("status", "idle")
            progress = ws.get("progress", 0)
            q = ws.get("q", 0)

            if status == "done":
                status_str = f"{BG}✓ Done{NC}"
            elif status == "failed":
                status_str = f"{R}✗ Failed{NC}"
            elif status == "skipped":
                status_str = f"{Y}⊘ Skip{NC}"
            elif status == "cancelled":
                status_str = f"{Y}■ Cancelled{NC}"
            elif status == "encoding":
                bar_len = 10
                filled = int(progress / 100 * bar_len)
                bar = "█" * filled + "░" * (bar_len - filled)
                status_str = f"Q={q} [{bar}] {progress:2d}%"
            else:
                status_str = f"{DIM}waiting...{NC}"

            line = f"{BG}│{NC} [{wid}] {filename:<32} {status_str:<25}{BG}│{NC}"
            lines.append(line)

    lines.append(f"{BG}├{'─'*62}┤{NC}")
    lines.append(f"{BG}│{NC} {G}✓ {stats['succeeded']}{NC}  {R}✗ {stats['failed']}{NC}  ⏱ {mins:02d}:{secs:02d}" + " " * 35 + f"{BG}│{NC}")
    lines.append(f"{BG}└{'─'*62}┘{NC}")

    return lines


def display_loop(start_time, max_workers):
    """Background thread to refresh display."""
    num_lines = 0
    while not stop_display.is_set():
        # Move cursor up and redraw
        if num_lines > 0:
            sys.stdout.write(f"\033[{num_lines}A")

        lines = draw_table(start_time, max_workers)
        for line in lines:
            sys.stdout.write(f"\r{CLEAR_LINE}{line}\n")
        sys.stdout.flush()
        num_lines = len(lines)

        time.sleep(0.5)


def terminal_verdict(line: str) -> tuple:
    """Classify one optimizer output line as the run's final verdict.

    Returns ("success"|"failed", reason) or (None, None) for everything else.

    The optimizer prints exactly ONE `>>> SUCCESS` / `>>> FAILED:` per file.
    Everything else is per-pass chatter: "Quality too low for this level."
    rejects a single rung of the quality ladder, and "Aborting pass..." abandons
    one encode attempt — a run that recovers on another rung is still a success.
    Treating those as terminal reported finished encodes as failures.
    """
    if '>>> SUCCESS' in line:
        return ("success", None)
    if '>>> FAILED' in line:
        match = re.search(r'>>> FAILED:\s*(.*)', line)
        reason = match.group(1).strip() if match else ""
        return ("failed", reason or "Encoding failed")
    return (None, None)


def read_worker_result(path) -> dict | None:
    """The worker's own verdict, or None if it did not leave one.

    Falling back to stdout parsing keeps older call paths working — and a
    worker killed mid-run leaves no file, which is exactly when the scraped
    output is all there is.
    """
    try:
        payload = json.loads(Path(path).read_text(encoding="utf-8"))
        results = payload.get("results") or []
        return results[0] if results else None
    except (OSError, ValueError, TypeError, KeyError, IndexError):
        return None


WINDOW_HOLD_SECONDS = 10


def window_hold_seconds(is_tty: bool) -> int:
    """How long to keep the window open after the summary.

    The pause exists for the Terminal window AppleScript opens, which would
    otherwise close before anyone read the result. Started from the wizard or
    a script there is no window, and the wait is pure delay.
    """
    return WINDOW_HOLD_SECONDS if is_tty else 0


def write_batch_results(path, results: list) -> bool:
    """Write every file's result as one JSON object. Never raises.

    The caller that started this batch — usually the wizard in scan.py — only
    ever learned an exit code, so it could not hold its own estimate against
    what was actually saved, nor offer to retry what fell under the quality
    floor. The measurements existed all along; they just had no way out.
    """
    payload = {"videocrunch": 1, "results": results}
    try:
        Path(path).write_text(json.dumps(payload, indent=2), encoding="utf-8")
        return True
    except (OSError, TypeError, ValueError) as e:
        print(f"{Y}Could not write batch result file {path}: {e}{NC}")
        return False


def merge_worker_result(result: dict, data: dict | None) -> bool:
    """Let the worker's own verdict replace what was scraped off its output.

    Returns False when there is no verdict to merge, leaving the scraped
    values in place. Scraping reads rounded, human-facing numbers; the worker
    reports the real ones.
    """
    if not data:
        return False
    for key in ("status", "quality", "ssim", "saved_pct", "saved_bytes", "reason",
                "dropped", "dolby_vision", "output_path"):
        if key in data:
            result[key] = data[key]
    return True


def build_optimizer_command(file_path, port, audio_mode, min_ssim=None, json_out=None,
                            scale_height=None, replace=False, codec=None, ss=None, to=None,
                            edit_flags=(), video_mode=None, output_dir=None):
    """The per-file `videocrunch.py` invocation — see tests/test_cli_contract.py.

    Every batch-level option a caller sets has to appear here; anything the
    controller accepts but does not forward silently leaves the per-file
    encode on its defaults.
    """
    cmd = [
        sys.executable,
        str(Path(__file__).parent / "videocrunch.py"),
        str(file_path),
        "--audio-mode", audio_mode,
    ]
    if port:
        cmd.extend(["--port", str(port)])
    if min_ssim:
        cmd.extend(["--min-ssim", str(min_ssim)])
    if json_out:
        cmd.extend(["--json-out", str(json_out)])
    if scale_height:
        cmd.extend(["--scale-height", str(scale_height)])
    if replace:
        cmd.append("--replace")
    if codec:
        cmd.extend(["--codec", codec])
    if ss:
        cmd.extend(["--ss", str(ss)])
    if to:
        cmd.extend(["--to", str(to)])
    if output_dir:
        cmd.extend(["--output-dir", str(output_dir)])
    if video_mode and video_mode != 'compress':
        cmd.extend(["--video-mode", str(video_mode)])
        if video_mode == 'copy':
            cmd.append("--copy-audio")
    cmd.extend(edit_flags)
    return cmd


# Switches that pass through to every file unchanged.
EDIT_FLAGS = ("half_fps", "crop_bars", "no_audio")


def edit_flags(args) -> tuple:
    """--half-fps / --crop-bars / --no-audio as set on the batch."""
    return tuple("--" + name.replace("_", "-") for name in EDIT_FLAGS if getattr(args, name, False))


def start_worker(cmd):
    """Start one videocrunch.py, or return None once the batch is cancelled."""
    with workers_lock:
        if abort_requested.is_set():
            return None
        env = {**os.environ, "PYTHONUNBUFFERED": "1"}
        process = subprocess.Popen(
            cmd,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            text=True,
            bufsize=1,
            env=env,
        )
        active_workers.add(process)
        return process


def finish_worker(process):
    with workers_lock:
        active_workers.discard(process)


def abort_workers(signum=None, frame=None):
    """SIGTERM handler: interrupt every running worker and start no new ones.

    Workers get SIGTERM, which videocrunch.py turns into its own abort path:
    stop ffmpeg, delete the half-written pass. Dying here alone would leave
    them encoding unsupervised.
    """
    abort_requested.set()
    with workers_lock:
        for process in active_workers:
            if process.poll() is None:
                process.terminate()


def _unpack_work_item(args_tuple):
    """Normalize 11-, 12-, or 13-element batch work tuples into a uniform 13-tuple."""
    if len(args_tuple) >= 13:
        return args_tuple[:13]
    if len(args_tuple) == 12:
        return (*args_tuple, None)
    return (*args_tuple[:10], 'compress', args_tuple[10], None)


def run_optimizer(args_tuple):
    """Worker function - captures output and updates shared state. Returns detailed results for logging."""
    unpacked = _unpack_work_item(args_tuple)
    file_path, worker_id = unpacked[0], unpacked[11]
    emit("file_start", worker=worker_id, file=file_path, name=Path(file_path).name)
    outcome = _run_optimizer(args_tuple)
    result = outcome[2]
    emit("file_done", worker=worker_id, file=file_path, status=result["status"],
         quality=result.get("quality"), ssim=result.get("ssim"),
         saved_pct=result.get("saved_pct"), saved_bytes=result.get("saved_bytes"),
         reason=result.get("reason"))
    return outcome


def _run_optimizer(args_tuple):
    (file_path, port, audio_mode, min_ssim, scale_height, replace, codec, ss, to, flags,
     video_mode, worker_id, output_dir) = _unpack_work_item(args_tuple)

    filename = Path(file_path).name
    file_start = time.time()

    # Result structure for logging
    result = {
        "filename": filename,
        "path": file_path,
        "status": "failed",
        "quality": None,
        "ssim": None,
        "saved_pct": None,
        "saved_bytes": None,
        "duration": 0,
        "reason": None
    }

    with display_lock:
        worker_status[worker_id] = {"file": filename, "status": "encoding", "progress": 0, "q": 75}

    # The worker writes its verdict here; stdout stays the live progress feed.
    result_file = Path(tempfile.gettempdir()) / f"videocrunch_w{worker_id}_{os.getpid()}.json"
    cmd = build_optimizer_command(file_path, port, audio_mode, min_ssim,
                                  json_out=result_file, scale_height=scale_height,
                                  replace=replace, codec=codec, ss=ss, to=to,
                                  edit_flags=flags, video_mode=video_mode,
                                  output_dir=output_dir)

    try:
        process = start_worker(cmd)
        if process is None:
            result["status"] = "cancelled"
            result["reason"] = "Cancelled"
            with display_lock:
                worker_status[worker_id]["status"] = "failed"
                file_results.append(result)
            return (file_path, False, result)

        success = False
        failed = False  # Track explicit failures
        skipped = False
        skip_reason = None
        last_quality = None
        last_ssim = None
        last_saved_pct = None
        last_saved_bytes = None
        failure_reason = None

        tracker = ProgressTracker()
        last_pass_event = None
        for line in process.stdout:
            clean_line = ANSI_RE.sub('', line).strip()
            verdict, verdict_reason = terminal_verdict(clean_line)

            if PASS_RE.search(clean_line):
                last_pass_event = None

            if tracker.feed(line):
                state = tracker.state()
                with display_lock:
                    worker_status[worker_id]["progress"] = state["percent"]
                    if state["q"] is not None:
                        worker_status[worker_id]["q"] = state["q"]
                emit("progress", worker=worker_id, file=file_path, **state)

            pass_event = parse_pass_event(clean_line, tracker.passes, tracker.q, last_pass_event)
            if pass_event is not None:
                last_pass_event = pass_event
                emit("pass_result", worker=worker_id, file=file_path, **pass_event)

            # The quality of the last result: "-> Result: Q=65"
            if 'Q=' in clean_line:
                match = re.search(r'Q=(\d+)', clean_line)
                if match:
                    last_quality = int(match.group(1))

            # Parse SSIM: "SSIM: 0.9823"
            if 'SSIM:' in clean_line:
                match = re.search(r'SSIM:\s*([\d.]+)', clean_line)
                if match:
                    last_ssim = float(match.group(1))

            # Parse savings: "Saved: 45.23%"
            if 'Saved:' in clean_line and '%' in clean_line:
                match = re.search(r'Saved:\s*([\d.]+)%', clean_line)
                if match:
                    last_saved_pct = float(match.group(1))

            # Parse bytes saved from SUCCESS line: ">>> SUCCESS! 1.23 GB saved"
            if verdict == 'success':
                success = True
                # Try to parse saved bytes: "1.23 GB saved" or "456.7 MB saved"
                match = re.search(r'([\d.]+)\s*(GB|MB|KB)\s*saved', clean_line)
                if match:
                    val = float(match.group(1))
                    unit = match.group(2)
                    if unit == 'GB':
                        last_saved_bytes = int(val * 1024 * 1024 * 1024)
                    elif unit == 'MB':
                        last_saved_bytes = int(val * 1024 * 1024)
                    else:
                        last_saved_bytes = int(val * 1024)

            # Detect explicit failures (terminal verdict only — see terminal_verdict)
            if verdict == 'failed':
                failed = True
                failure_reason = verdict_reason

            # Real skip messages start with "Skipping:" — copy-mode banners like
            # ">>> COPY MODE: Skipping re-encode logic." must NOT short-circuit.
            if clean_line.startswith('Skipping:'):
                skipped = True
                skip_reason = clean_line.removeprefix('Skipping:').strip()

        process.wait()
        finish_worker(process)
        result["duration"] = time.time() - file_start

        # The worker's own verdict outranks anything scraped from its output.
        scraped = {"status": "skipped" if skipped else ("success" if (success and not failed) else "failed"),
                   "quality": last_quality, "ssim": last_ssim,
                   "saved_pct": last_saved_pct, "saved_bytes": last_saved_bytes,
                   "reason": skip_reason if skipped else failure_reason}
        from_worker = read_worker_result(result_file)
        try:
            result_file.unlink()
        except OSError:
            pass
        merge_worker_result(scraped, from_worker)
        # A file stopped by a cancel did not fail; it was never allowed to finish.
        if scraped["status"] not in ("success", "skipped") and abort_requested.is_set():
            scraped["status"] = "cancelled"
            scraped["reason"] = "Cancelled"
        result.update({k: v for k, v in scraped.items() if k != "status"})
        final_status = scraped["status"]

        with display_lock:
            if final_status == "success":
                worker_status[worker_id]["status"] = "done"
                worker_status[worker_id]["progress"] = 100
                result["status"] = "success"
                file_results.append(result)
                return (file_path, True, result)
            elif final_status == "skipped":
                worker_status[worker_id]["status"] = "skipped"
                worker_status[worker_id]["progress"] = 100
                result["status"] = "skipped"
                result["reason"] = scraped.get("reason") or "Skipped"
                file_results.append(result)
                return (file_path, True, result)
            else:
                worker_status[worker_id]["status"] = final_status
                result["status"] = final_status
                result["reason"] = scraped.get("reason") or "Encoding failed"
                file_results.append(result)
                return (file_path, False, result)

    except Exception as e:
        result["duration"] = time.time() - file_start
        result["reason"] = str(e)
        with display_lock:
            worker_status[worker_id]["status"] = "failed"
            file_results.append(result)
        return (file_path, False, result)


def format_time(seconds):
    m, s = divmod(int(seconds), 60)
    h, m = divmod(m, 60)
    if h > 0:
        return f"{h}:{m:02d}:{s:02d}"
    return f"{m}:{s:02d}"


def format_bytes(bytes_val):
    """Format bytes into human readable string."""
    if bytes_val is None:
        return "N/A"
    if bytes_val >= 1024**3:
        return f"{bytes_val / 1024**3:.2f} GB"
    elif bytes_val >= 1024**2:
        return f"{bytes_val / 1024**2:.1f} MB"
    else:
        return f"{bytes_val / 1024:.0f} KB"


def write_log(start_time, elapsed, encoder_name):
    """Write detailed encoding results to a log file."""
    timestamp = datetime.now().strftime("%Y-%m-%d_%H-%M-%S")
    log_file = LOG_DIR / f"batch_{timestamp}.log"

    with open(log_file, 'w', encoding='utf-8') as f:
        f.write("="*70 + "\n")
        f.write("VIDEOCRUNCH BATCH ENCODER LOG\n")
        f.write(f"Date: {datetime.now().strftime('%Y-%m-%d %H:%M:%S')}\n")
        f.write(f"Encoder: {encoder_name}\n")
        f.write(f"Total Time: {format_time(elapsed)}\n")
        f.write("="*70 + "\n\n")

        f.write("SUMMARY\n")
        f.write("--------\n")
        f.write(f"Total Files: {stats['total']}\n")
        f.write(f"Succeeded:   {stats['succeeded']}\n")
        f.write(f"Failed:      {stats['failed']}\n")

        # Calculate total savings
        total_saved = sum(r.get('saved_bytes', 0) or 0 for r in file_results if r['status'] == 'success')
        if total_saved > 0:
            f.write(f"Total Saved: {format_bytes(total_saved)}\n")
        f.write("\n")

        f.write("DETAILED RESULTS\n")
        f.write("-"*70 + "\n")

        for r in file_results:
            f.write(f"\nFile: {r['filename']}\n")
            f.write(f"  Status:   {r['status'].upper()}\n")

            if r['status'] == 'success':
                if r['quality']:
                    f.write(f"  Quality:  Q={r['quality']}\n")
                if r['ssim']:
                    f.write(f"  SSIM:     {r['ssim']:.4f}\n")
                if r['saved_pct']:
                    f.write(f"  Savings:  {r['saved_pct']:.1f}%\n")
                if r['saved_bytes']:
                    f.write(f"  Saved:    {format_bytes(r['saved_bytes'])}\n")
            elif r['status'] == 'skipped' and r.get('reason'):
                f.write(f"  Reason:   {r['reason']}\n")
            elif r['status'] == 'failed' and r.get('reason'):
                f.write(f"  Error:    {r['reason']}\n")

            f.write(f"  Duration: {format_time(r['duration'])}\n")

        f.write("\n" + "="*70 + "\n")
        f.write(f"Log saved to: {log_file}\n")

    return log_file


def build_parser():
    """The CLI surface — see tests/test_cli_contract.py for the invocation contract."""
    parser = argparse.ArgumentParser(description='Batch Controller V2.0')
    sources = parser.add_mutually_exclusive_group(required=True)
    sources.add_argument('--files', help='Comma-separated file paths')
    sources.add_argument('--files-from', metavar='PATH',
                         help='Read file paths from PATH, one per line '
                              '(for names that contain commas)')
    parser.add_argument('--port', type=int,
                        help='Notify a companion server on this port when a file is done, '
                             'via GET /api/mark_optimized?path=<path>')
    parser.add_argument('--audio-mode', choices=['enhanced', 'standard'], default='enhanced')
    parser.add_argument('--json-out', metavar='PATH',
                        help='Write every file result to PATH (JSON) when the batch ends')
    parser.add_argument('--scale-height', type=int, metavar='H',
                        help='Downscale every file to H pixels height (forwarded per file)')
    parser.add_argument('--codec', choices=['hevc', 'av1'], default='hevc',
                        help='Target codec, forwarded per file (default: hevc)')
    parser.add_argument('--ss', metavar='TIME',
                        help='Start time, forwarded per file (the app trims a single video)')
    parser.add_argument('--to', metavar='TIME',
                        help='End time, forwarded per file')
    parser.add_argument('--replace', action='store_true',
                        help='Replace each source with its encode (original to the trash)')
    parser.add_argument('--half-fps', action='store_true',
                        help='Halve 48/50/60 fps footage (forwarded per file)')
    parser.add_argument('--crop-bars', action='store_true',
                        help='Cut away black bars (forwarded per file)')
    parser.add_argument('--no-audio', action='store_true',
                        help='Leave the audio out (forwarded per file)')
    parser.add_argument('--events', action='store_true',
                        help='Print one JSON object per line (start, progress, file '
                             'results, summary) instead of the live table')
    parser.add_argument('--video-mode', choices=['compress', 'copy'], default='compress',
                        help='Video processing mode: compress (default) or copy (passthrough)')
    parser.add_argument('--min-ssim', type=quality_floor, metavar='S',
                        help='Override the hard quality floor for every file in this batch '
                             '(0 < S <= 1). Forwarded to videocrunch.py per file.')
    parser.add_argument('--output-dir', metavar='DIR',
                        help='Write output files into DIR instead of next to each source')
    return parser


def file_list(args) -> list:
    """The files to encode, from --files-from or the comma-separated --files."""
    if args.files_from:
        text = Path(args.files_from).read_text(encoding='utf-8')
        return [line for line in text.splitlines() if line.strip()]
    return [f.strip() for f in args.files.split(',') if f.strip()]


def main():
    global event_stream
    args = build_parser().parse_args()
    signal.signal(signal.SIGTERM, abort_workers)
    if args.events:
        event_stream = sys.stdout

    files = file_list(args)

    if not files:
        print(f"{R}No files provided.{NC}")
        return

    encoder, _ = get_best_encoder()
    max_workers = min(get_optimal_workers(), len(files))

    stats["total"] = len(files)

    # Initialize worker slots
    for i in range(1, max_workers + 1):
        worker_status[i] = {"file": "", "status": "idle", "progress": 0, "q": 0}

    start_time = time.time()
    emit("start", total=len(files), workers=max_workers, files=files)

    if not args.events:
        print(f"\n{Y}Each file: Q=75→65→55→45 loop + SSIM quality check{NC}\n")
        display_thread = threading.Thread(target=display_loop, args=(start_time, max_workers),
                                          daemon=True)
        display_thread.start()

    # Prepare work items
    work_items = [(f, args.port, args.audio_mode, args.min_ssim, args.scale_height,
                   args.replace, args.codec, args.ss, args.to, edit_flags(args),
                   args.video_mode, (i % max_workers) + 1, args.output_dir)
                  for i, f in enumerate(files)]

    # Process files
    with ThreadPoolExecutor(max_workers=max_workers) as executor:
        futures = {executor.submit(run_optimizer, item): item[0] for item in work_items}

        for future in as_completed(futures):
            try:
                _, success, _ = future.result()  # 3 values now: (path, success, result)
                with display_lock:
                    stats["completed"] += 1
                    if success:
                        stats["succeeded"] += 1
                    else:
                        stats["failed"] += 1
            except Exception:
                with display_lock:
                    stats["completed"] += 1
                    stats["failed"] += 1

    # Stop display and show final
    stop_display.set()
    elapsed = time.time() - start_time
    log_file = write_log(start_time, elapsed, encoder)
    if args.json_out:
        write_batch_results(args.json_out, file_results)

    if args.events:
        emit("summary", succeeded=stats["succeeded"], failed=stats["failed"],
             elapsed_sec=round(elapsed, 1), log=str(log_file))
        return

    time.sleep(0.6)
    print(f"\n\n{BG}╔{'═'*62}╗{NC}")
    print(f"{BG}║{NC}                    📊 {CYAN}BATCH COMPLETE{NC} 📊                       {BG}║{NC}")
    print(f"{BG}╠{'═'*62}╣{NC}")
    print(f"{BG}║{NC}  ✓ Succeeded:  {G}{stats['succeeded']}{NC}                                       {BG}║{NC}")
    print(f"{BG}║{NC}  ✗ Failed:     {R}{stats['failed']}{NC}                                         {BG}║{NC}")
    print(f"{BG}║{NC}  ⏱ Time:       {Y}{format_time(elapsed)}{NC}                            {BG}║{NC}")
    print(f"{BG}╚{'═'*62}╝{NC}")

    print(f"\n{G}📝 Log saved:{NC} {log_file}")

    hold = window_hold_seconds(sys.stdout.isatty())
    if hold:
        print(f"\n{Y}Window will close in {hold} seconds (Ctrl+C to close now)...{NC}")
        try:
            for i in range(hold, 0, -1):
                print(f"\r{DIM}Closing in {i}...{NC}", end="", flush=True)
                time.sleep(1)
            print()
        except KeyboardInterrupt:
            print(f"\n{G}Closing...{NC}")


if __name__ == "__main__":
    main()
