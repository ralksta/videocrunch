#!/usr/bin/env python3
"""
Folder Scanner — ranks a directory's videos by expected re-encode savings.

Answers "which of these 150 files is worth optimizing?" without encoding
anything: ffprobe metadata only, a few seconds for a large folder. The ranking
itself is `rank()` below — the same math a companion dashboard uses to build
its candidate list, kept in sync via savings_parity.json and ported to plain
dicts so videocrunch stays free of extra dependencies. History is read from ~/.videocrunch/logs/encode_history.jsonl.

Mark the entries you want (e.g. `1,3,7-10`) and they are handed to batch.py,
which runs the encodes in parallel.
"""
import argparse
import json
import os
import shutil
import statistics
import subprocess
import sys
import tempfile
import threading
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path
from typing import Any, Optional

from crunch_utils import (
    DEFAULT_HISTORY_PATH,
    disk_headroom_needed,
    estimate_runtime_sec,
    history_throughput,
    read_encode_history,
)
from savings import (
    _is_same_codec,
    _reference_kbps,
    bitrate_class,
    estimate_savings_pct,
    resolution_class,
)
from videocrunch import suggested_floor

# Extensions worth probing. Deliberately inlined: a standalone tool should not
# need a config module for a constant list.
VIDEO_EXTENSIONS = frozenset({
    '.mp4', '.mkv', '.avi', '.mov', '.wmv', '.flv', '.webm', '.m4v',
    '.mpg', '.mpeg', '.ts',
})
MIN_LISTED_SAVED_PCT = 10.0

# --- COLORS ---
G = '\033[0;32m'
BG = '\033[1;32m'
R = '\033[0;31m'
Y = '\033[0;33m'
CYAN = '\033[0;36m'
DIM = '\033[2m'
NC = '\033[0m'

PROBE_WORKERS = 8
PROBE_TIMEOUT = 30


# ---------------------------------------------------------------------------
# Pure helpers
# ---------------------------------------------------------------------------

def _as_float(value: Any) -> float:
    """ffprobe writes "N/A" for anything it cannot determine."""
    try:
        return float(value)
    except (TypeError, ValueError):
        return 0.0


def _as_int(value: Any) -> int:
    try:
        return int(value)
    except (TypeError, ValueError):
        return 0


def has_optimized_sibling(path: Path) -> bool:
    """True when the optimizer already wrote a `<stem>_opt.mp4` next to it."""
    return (path.parent / f"{path.stem}_opt.mp4").exists()


def find_videos(root: Path) -> list[Path]:
    """All video files under `root`, minus the optimizer's own output.

    `_opt.mp4` results, `_rejected.mp4` candidates kept from a failed run, and
    `._staging_q*` leftovers are skipped: offering to re-encode them would
    just compress an encode of an encode.
    """
    found = []
    for path in root.rglob("*"):
        if not path.is_file():
            continue
        if path.suffix.lower() not in VIDEO_EXTENSIONS:
            continue
        if path.stem.endswith(("_opt", "_rejected")) or "._staging_q" in path.name:
            continue
        found.append(path)
    return sorted(found)


def probe_to_media(file_path: str, probe: dict) -> Optional[dict]:
    """Build a media record from raw ffprobe JSON, or None if it is not a video.

    When the container omits `format.bit_rate` (common in Matroska) it is
    derived from size and duration. Without that the entry would rank as
    0 Mbit/s and never appear.
    """
    streams = probe.get("streams") or []
    video_stream = next((s for s in streams if s.get("codec_type") == "video"), None)
    if video_stream is None:
        return None

    fmt = probe.get("format", {})
    size_bytes = _as_float(fmt.get("size", 0))
    duration = _as_float(fmt.get("duration", 0))
    bitrate_bps = _as_float(fmt.get("bit_rate", 0))
    if bitrate_bps <= 0 and duration > 0:
        bitrate_bps = size_bytes * 8 / duration

    fps_str = str(video_stream.get("avg_frame_rate", "0/0"))
    if "/" in fps_str:
        numerator, _, denominator = fps_str.partition("/")
        den = _as_float(denominator)
        fps = _as_float(numerator) / den if den > 0 else 0.0
    else:
        fps = _as_float(fps_str)

    return {
        "file_path": file_path,
        "size_mb": round(size_bytes / (1024 * 1024), 2),
        "bitrate_mbps": round(bitrate_bps / 1_000_000, 2),
        "codec": video_stream.get("codec_name", "unknown"),
        "duration_sec": round(duration, 2),
        "width": _as_int(video_stream.get("width", 0)),
        "height": _as_int(video_stream.get("height", 0)),
        "frame_rate": round(fps, 3),
    }


def parse_selection(text: str, count: int) -> list[int]:
    """Parse the selection line into sorted, unique 1-based indices.

    Accepts `1,3,7-10`, `a`/`alle`/`all` for everything, empty for nothing.
    Raises ValueError on anything unparseable or out of range — quietly
    dropping a bad entry would start an encode run that silently differs from
    what the user typed.
    """
    text = text.strip().lower()
    if not text:
        return []
    if text in ("a", "all", "alle"):
        return list(range(1, count + 1))

    selected: set = set()
    for token in text.split(","):
        token = token.strip()
        if not token:
            continue
        if "-" in token:
            lo_str, _, hi_str = token.partition("-")
            lo, hi = _parse_index(lo_str, count), _parse_index(hi_str, count)
            if lo > hi:
                lo, hi = hi, lo  # "10-7" reads the same as "7-10"
            selected.update(range(lo, hi + 1))
        else:
            selected.add(_parse_index(token, count))
    return sorted(selected)


DOWNSCALE_TARGET = 1080


def ask_yes_no(question: str, default: bool, ask=None) -> bool:
    """One yes/no question. No answer means no — whatever the default is.

    A closed stdin or a Ctrl-C at the prompt must not start an encode run the
    user never confirmed, so an unanswerable question is a "no" even where
    Enter would have meant yes.
    """
    suffix = "[J/n]" if default else "[j/N]"
    print(f"  {Y}{question}{NC} {suffix}: ", end="", flush=True)
    try:
        answer = (ask or input)().strip().lower()
    except (EOFError, KeyboardInterrupt):
        print()
        return False
    if not answer:
        return default
    return answer in ("j", "y", "ja", "yes")


def downscale_candidates(entries: list, target: int = DOWNSCALE_TARGET) -> int:
    """How many of these are taller than the downscale target.

    Downscaling is the single biggest lever on phone 4K, and it was reachable
    only via --scale-height. Asking makes sense only when the selection holds
    material it would apply to.
    """
    return sum(1 for e in entries if (e.get("height") or 0) > target)


def select_candidates(text: str, names: list) -> list:
    """Resolve a selection line against the listed candidates.

    On top of `1,3,7-10` and `a`:
      * `a -3,5`   — everything except those (also `1-4 -2`)
      * `Urlaub`   — everything whose listed name contains that text

    Counting rows to express "all but two" is exactly the kind of chore that
    produces the wrong number. A name that matches nothing raises rather than
    selecting nothing quietly: that is a typo, not a change of mind.
    """
    count = len(names)
    include_tokens, exclude_tokens = [], []
    for token in text.strip().split():
        (exclude_tokens if token.startswith("-") else include_tokens).append(
            token.lstrip("-") if token.startswith("-") else token)

    include_text = " ".join(include_tokens).strip()
    if not include_text:
        return []

    lowered = include_text.lower()
    if lowered in ("a", "all", "alle"):
        selected = list(range(1, count + 1))
    elif any(ch.isalpha() for ch in lowered):
        selected = [i for i, name in enumerate(names, start=1)
                    if lowered in str(name).lower()]
        if not selected:
            raise ValueError(f"Kein Treffer für '{include_text}'")
    else:
        selected = parse_selection(include_text, count)

    if exclude_tokens:
        excluded = set(parse_selection(",".join(exclude_tokens), count))
        selected = [i for i in selected if i not in excluded]
    return selected


def _parse_index(token: str, count: int) -> int:
    token = token.strip()
    if not token.isdigit():
        raise ValueError(f"Ungültige Eingabe: '{token}'")
    index = int(token)
    if index < 1 or index > count:
        raise ValueError(f"Nummer {index} gibt es nicht (1–{count})")
    return index


# ---------------------------------------------------------------------------
# Ranking — savings heuristic from savings.py, plus encode-history overrides
# ---------------------------------------------------------------------------

# History `codec` holds encoder-profile names (hevc_nvenc, libx265, av1_nvenc…);
# match the requested target codec by substring.
_TARGET_SUBSTRINGS = {"hevc": ("hevc", "265"), "av1": ("av1",)}


class EncodeHistory:
    """mtime-cached reader over encode_history.jsonl (best-effort, never raises).

    Records are pre-parsed and bucketed by (resolution class, bitrate class) at
    load time, so `median_saved_pct` is a bucket lookup + substring filter over
    only the matching bucket, not a full linear scan of every record. Reload
    (triggered by an mtime check) and bucket access are both guarded by a lock
    since the instance may be shared across threads.
    """

    def __init__(self, path: Path = DEFAULT_HISTORY_PATH) -> None:
        self.path = path
        self._mtime: float = -1.0
        # bucket (resolution_class, bitrate_class) -> [(lowered codec str, saved_pct), ...]
        self._index: dict[tuple[str, str], list[tuple[str, float]]] = {}
        self._lock = threading.Lock()

    def _reload_if_stale(self) -> None:
        with self._lock:
            try:
                mtime = self.path.stat().st_mtime
            except OSError:
                self._index = {}
                self._mtime = -1.0
                return
            if mtime == self._mtime:
                return
            index: dict[tuple[str, str], list[tuple[str, float]]] = {}
            try:
                with open(self.path, encoding="utf-8") as f:
                    for line in f:
                        try:
                            rec = json.loads(line)
                        except json.JSONDecodeError:
                            continue
                        if not isinstance(rec, dict) or rec.get("saved_pct") is None:
                            continue
                        try:
                            bucket = (resolution_class(int(rec.get("height", 0))),
                                     bitrate_class(float(rec.get("source_kbps", 0))))
                            saved_pct = float(rec["saved_pct"])
                        except (TypeError, ValueError):
                            continue
                        codec_str = str(rec.get("codec", "")).lower()
                        index.setdefault(bucket, []).append((codec_str, saved_pct))
            except OSError:
                index = {}
            self._index = index
            self._mtime = mtime

    def median_saved_pct(self, target_codec: str, height: int, source_kbps: float,
                         min_samples: int = 3) -> Optional[tuple]:
        """Median real saved_pct for the (target, resolution class, bitrate class) bucket."""
        self._reload_if_stale()
        substrings = _TARGET_SUBSTRINGS.get(target_codec, (target_codec,))
        bucket = (resolution_class(height), bitrate_class(source_kbps))
        with self._lock:
            entries = list(self._index.get(bucket, ()))
        samples = [saved_pct for codec_str, saved_pct in entries
                  if any(s in codec_str for s in substrings)]
        if len(samples) < min_samples:
            return None
        return (float(statistics.median(samples)), len(samples))


def _reason(m: dict, saved_pct: float, source: str, samples: int,
           is_same_codec: bool, above_reference: bool) -> str:
    codec = (m["codec"] or "unknown").upper()
    res = f"{m['height']}p" if (m["height"] or 0) > 0 else "?"
    rate = f"{m['bitrate_mbps']:.1f} Mbit/s"
    if source == "history":
        return f"{codec}, {res}, {rate} — {samples} echte Encodes in dieser Klasse"
    if is_same_codec:
        return f"{codec}, {res}, {rate} — gleicher Codec, geringes Potenzial"
    if above_reference:
        return f"{codec}, {res}, {rate} — deutlich über Referenz"
    return f"{codec}, {res}, {rate} — Codec-Wechsel lohnt"


def rank(media: list[dict], target_codec: str, exclude_paths: set,
        history: EncodeHistory, limit: int = 100) -> dict:
    """Rank re-encode candidates by absolute expected savings (MB, desc)."""
    candidates: list[dict] = []
    for m in media:
        if m["file_path"] in exclude_paths:
            continue
        heur = estimate_savings_pct(
            (m["bitrate_mbps"] or 0.0) * 1000.0,
            m["height"] or 0,
            m["frame_rate"] or 0.0,
            m["codec"] or "",
            target_codec,
        )
        if heur is None:
            continue
        saved_pct, known_pair = heur
        source = "heuristic"
        confidence = "medium" if known_pair else "low"
        samples = 0
        is_same_codec = _is_same_codec(m["codec"] or "", target_codec)
        # History carries no source codec, so a same-codec entry (already HEVC,
        # re-checking against HEVC) would otherwise inherit the median of
        # unrelated h264-source encodes in the same bucket. Skip the override.
        if not is_same_codec:
            hist = history.median_saved_pct(
                target_codec, m["height"] or 0, (m["bitrate_mbps"] or 0.0) * 1000.0)
            if hist is not None:
                saved_pct, samples = hist
                source, confidence = "history", "high"
        if saved_pct < MIN_LISTED_SAVED_PCT:
            continue
        source_kbps = (m["bitrate_mbps"] or 0.0) * 1000.0
        ref_kbps = _reference_kbps(m["height"] or 0, target_codec, m["frame_rate"] or 0.0)
        above_reference = source_kbps > ref_kbps
        candidates.append({
            "file_path": m["file_path"],
            "size_mb": m["size_mb"],
            "codec": m["codec"] or "unknown",
            "width": m["width"] or 0,
            "height": m["height"] or 0,
            "bitrate_mbps": m["bitrate_mbps"] or 0.0,
            "estimated_saved_mb": round(m["size_mb"] * saved_pct / 100.0, 1),
            "estimated_saved_pct": round(saved_pct, 1),
            "confidence": confidence,
            "source": source,
            "reason": _reason(m, saved_pct, source, samples, is_same_codec, above_reference),
        })

    candidates.sort(key=lambda c: c["estimated_saved_mb"], reverse=True)
    return {
        "summary": {
            "total_files": len(candidates),
            "total_estimated_saved_mb": round(
                sum(c["estimated_saved_mb"] for c in candidates), 1),
            "history_based": sum(1 for c in candidates if c["source"] == "history"),
        },
        "results": candidates[:limit],
    }


# ---------------------------------------------------------------------------
# Probing
# ---------------------------------------------------------------------------

def probe_file(path: Path) -> Optional[dict]:
    """ffprobe one file. Metadata only — no decoding, so this is fast."""
    cmd = [
        'ffprobe', '-v', 'error', '-print_format', 'json',
        '-show_format', '-show_streams', str(path),
    ]
    try:
        result = subprocess.run(cmd, capture_output=True, timeout=PROBE_TIMEOUT)
        if result.returncode != 0:
            return None
        return probe_to_media(str(path), json.loads(result.stdout))
    except (subprocess.SubprocessError, json.JSONDecodeError, OSError, ValueError):
        return None


def probe_all(paths: list[Path], quiet: bool = False) -> list[dict]:
    """Probe every file in parallel, with a progress counter.

    `quiet` routes the progress counter to stderr instead of stdout — used by
    `--json`, where stdout must contain nothing but the final JSON document.
    """
    entries: list[dict] = []
    done = 0
    total = len(paths)
    out = sys.stderr if quiet else sys.stdout
    with ThreadPoolExecutor(max_workers=PROBE_WORKERS) as executor:
        for entry in executor.map(probe_file, paths):
            done += 1
            out.write(f"\r{Y}Lese Metadaten...{NC} {done}/{total}")
            out.flush()
            if entry is not None:
                entries.append(entry)
    out.write("\r" + " " * 40 + "\r")
    return entries


# ---------------------------------------------------------------------------
# Output
# ---------------------------------------------------------------------------

def format_duration(seconds: float) -> str:
    """A runtime estimate as someone would say it out loud."""
    if seconds < 60:
        return "unter 1 min"
    minutes = int(round(seconds / 60))
    if minutes < 60:
        return f"{minutes} min"
    hours, rest = divmod(minutes, 60)
    return f"{hours} h {rest} min" if rest else f"{hours} h"


def _files(n: int) -> str:
    return "Datei" if n == 1 else "Dateien"


def format_size(mb: float) -> str:
    if mb >= 1024:
        return f"{mb/1024:.1f} GB"
    if 0 < mb < 1:
        # "0 MB" reads as "nothing to gain" and makes the row look like a bug.
        return "<1 MB"
    return f"{mb:.0f} MB"


# Columns spent on number, savings, percent and the info text.
TABLE_FIXED_COLUMNS = 40


# Anything narrower than this is not a terminal we can lay out for — a pty
# with no window size set reports 0 columns, and taking that literally elides
# every path down to a stub.
MIN_PLAUSIBLE_COLUMNS = 52
FALLBACK_COLUMNS = 86


def table_name_width(term_cols: int) -> int:
    """Width of the file column for a terminal this wide.

    A fixed width wrapped the table in an 80-column terminal, which is the
    default almost everywhere.
    """
    if term_cols < MIN_PLAUSIBLE_COLUMNS:
        term_cols = FALLBACK_COLUMNS
    return max(12, min(46, term_cols - TABLE_FIXED_COLUMNS))


def display_name(path: Path, root: Path, width: int) -> str:
    """How a candidate is identified in the table.

    The bare filename is ambiguous the moment a tree repeats names — the
    normal case for phone imports. Overlong paths lose their FRONT: the tail
    holds the filename, which is the part that identifies the file.
    """
    try:
        shown = str(Path(path).relative_to(root))
    except ValueError:
        shown = Path(path).name
    if len(shown) > width:
        shown = "…" + shown[-(width - 1):]
    return shown


def summary_lines(shown: list, summary: dict, hidden_below: int, excluded: int) -> list:
    """The lines under the table — describing what the table actually offers.

    The totals used to count every candidate found, including those `--limit`
    cut away, so the sum promised savings the user could not select and
    `a = alle` quietly meant "all of the visible ones".
    """
    lines = []
    shown_mb = round(sum(c["estimated_saved_mb"] for c in shown), 1)
    n = len(shown)
    lines.append(f"{n} {_files(n)} gelistet, zusammen ~{format_size(shown_mb)} "
                 f"Ersparnis erwartet.")
    not_listed = summary.get("total_files", n) - n
    if not_listed > 0:
        lines.append(f"{not_listed} weitere Kandidaten nicht gezeigt (--limit) — "
                     f"Auswahl bezieht sich nur auf die Liste.")
    if hidden_below > 0:
        lines.append(f"{hidden_below} {_files(hidden_below)} unter "
                     f"{MIN_LISTED_SAVED_PCT:.0f}% erwarteter Ersparnis ausgeblendet.")
    if excluded > 0:
        lines.append(f"{excluded} {_files(excluded)} "
                     f"{'hat' if excluded == 1 else 'haben'} bereits ein _opt.mp4.")
    if summary.get("history_based"):
        lines.append(f"{summary['history_based']} Schätzungen beruhen auf echten "
                     f"früheren Encodes (grün), der Rest ist Heuristik.")
    return lines


def print_table(candidates: list[dict], root: Path, name_width: int = 46) -> None:
    print(f"\n{BG}{'#':>3}  {'Ersparnis':>10}  {'%':>4}  "
          f"{'Datei':<{name_width}}  Info{NC}")
    print(DIM + "─" * (name_width + TABLE_FIXED_COLUMNS) + NC)
    for i, c in enumerate(candidates, start=1):
        name = display_name(Path(c['file_path']), root, name_width)
        conf = {"high": G, "medium": Y, "low": DIM}.get(c['confidence'], NC)
        print(f"{CYAN}{i:>3}{NC}  {G}{format_size(c['estimated_saved_mb']):>10}{NC}  "
              f"{c['estimated_saved_pct']:>3.0f}%  {name:<{name_width}}  "
              f"{conf}{c['reason']}{NC}")


def retry_floor(results: list) -> float | None:
    """A quality floor that every measured failure in this batch would clear.

    Follows the LOWEST score, so one retry covers them all, and rounds down —
    a floor the result does not actually beat sends the user into a second
    run that fails exactly like the first. None when nothing failed on
    quality: an ffmpeg error is not fixed by moving the bar.
    """
    scores = [r["ssim"] for r in results
              if r.get("status") == "failed" and r.get("ssim")]
    if not scores:
        return None
    return suggested_floor(min(scores))


def disk_shortfall(entries: list, free_bytes: int) -> int:
    """Bytes missing to run this selection, or 0 when there is room.

    Checked for the whole selection before the batch starts: the per-file
    check inside the encoder catches the same problem, but only once files
    have begun failing one after another.
    """
    needed = sum(disk_headroom_needed(int((e.get("size_mb") or 0) * 1024 * 1024))
                 for e in entries)
    return max(0, needed - int(free_bytes))


def batch_runtime_sec(entries: list, records: list) -> float | None:
    """Seconds the selected files should take, each in its own class.

    A single file whose resolution class has no history makes the whole
    estimate unavailable: a number that covers only part of the batch is not
    the number the user is about to plan around.
    """
    total = 0.0
    for entry in entries:
        throughput = history_throughput(records, height=entry.get("height") or 0)
        seconds = estimate_runtime_sec(entry.get("size_mb") or 0.0, throughput)
        if seconds is None:
            return None
        total += seconds
    return total if entries else None


def retry_paths(results: list) -> list:
    """Sources worth re-running with a lower floor.

    Only the files that failed on QUALITY: moving the bar does not fix an
    ffmpeg error. `batch.py` names the source "path" and `videocrunch.py`
    names it "input_path" — reading only one of them retries nothing at all.
    """
    return [p for p in (r.get("path") or r.get("input_path") for r in results
                        if r.get("status") == "failed" and r.get("ssim")) if p]


def outcome_lines(estimated_mb: float, results: list) -> list:
    """What the run actually delivered, against what was promised."""
    lines = []
    saved_bytes = sum(r.get("saved_bytes") or 0 for r in results
                      if r.get("status") == "success")
    actual_mb = saved_bytes / (1024 * 1024)
    lines.append(f"Erwartet ~{format_size(estimated_mb)}, "
                 f"tatsächlich {format_size(actual_mb)} gespart.")
    failed = [r for r in results if r.get("status") == "failed"]
    if failed:
        lines.append(f"{len(failed)} {_files(len(failed))} nicht encodiert.")
    return lines


def read_batch_results(path) -> list:
    """The batch's per-file results, or an empty list if it left none."""
    try:
        return json.loads(Path(path).read_text(encoding="utf-8")).get("results") or []
    except (OSError, ValueError, TypeError, AttributeError):
        return []


def run_batch(paths: list, audio_mode: str, port=None, scale_height=None,
              replace: bool = False, results_file=None, min_ssim=None) -> int:
    """Hand the marked files to batch.py for parallel encoding."""
    cmd = [sys.executable, str(Path(__file__).parent / "batch.py"),
           '--files', ",".join(paths), '--audio-mode', audio_mode]
    if results_file:
        cmd.extend(['--json-out', str(results_file)])
    if min_ssim:
        cmd.extend(['--min-ssim', str(min_ssim)])
    if port:
        cmd.extend(['--port', str(port)])
    if scale_height:
        cmd.extend(['--scale-height', str(scale_height)])
    if replace:
        cmd.append('--replace')
    return subprocess.run(cmd).returncode


# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

def main() -> int:
    parser = argparse.ArgumentParser(
        description='Rank a folder\'s videos by expected re-encode savings')
    parser.add_argument('folder', help='Folder to scan (searched recursively)')
    parser.add_argument('--codec', choices=['hevc', 'av1'], default='hevc',
                        help='Target codec for the estimate (default: hevc)')
    parser.add_argument('--limit', type=int, default=30,
                        help='Show at most N candidates (default: 30)')
    parser.add_argument('--audio-mode', choices=['enhanced', 'standard'],
                        default='enhanced', help='Audio mode for the encode run')
    parser.add_argument('--port', type=int,
                        help='Port passed through to batch.py, which notifies a companion server there when a file is done')
    parser.add_argument('--no-encode', action='store_true',
                        help='Only print the ranking, never ask to encode')
    parser.add_argument('--json', action='store_true',
                        help='Print the ranking as JSON to stdout (no banner, no table, '
                             'no colour, no prompt — implies --no-encode)')
    args = parser.parse_args()

    # In --json mode stdout must be a valid JSON document and nothing else:
    # every human-facing line below goes to stderr instead so a redirect
    # (`scan.py folder --json > report.json`) produces parseable output.
    log = (lambda msg: print(msg, file=sys.stderr)) if args.json else print

    root = Path(args.folder).expanduser()
    if not root.is_dir():
        log(f"{R}Kein Ordner: {root}{NC}")
        return 1

    log(f"{G}Ordner:{NC} {root}")

    paths = find_videos(root)
    if not paths:
        if args.json:
            print(json.dumps(rank([], args.codec, set(), EncodeHistory(), limit=args.limit)))
        else:
            log(f"{Y}Keine Videodateien gefunden.{NC}")
        return 0
    log(f"{G}Gefunden:{NC} {len(paths)} Videodateien\n")

    entries = probe_all(paths, quiet=args.json)
    if not entries:
        if args.json:
            print(json.dumps(rank([], args.codec, set(), EncodeHistory(), limit=args.limit)))
        else:
            log(f"{R}Keine lesbaren Videodateien.{NC}")
        return 1

    # Files that already have an _opt.mp4 next to them are done.
    exclude = {str(p) for p in paths if has_optimized_sibling(p)}

    result = rank(entries, args.codec, exclude, EncodeHistory(), limit=args.limit)
    # `results` is already truncated to `limit`; `summary` counts them all.
    candidates = result['results']
    summary = result['summary']

    if args.json:
        print(json.dumps(result))
        return 0

    if not candidates:
        print(f"{Y}Kein Kandidat über der 10%-Schwelle — hier ist nichts zu holen.{NC}")
        return 0

    try:
        term_cols = os.get_terminal_size().columns
    except OSError:
        term_cols = 86
    print_table(candidates, root, table_name_width(term_cols))

    hidden = len(entries) - len(exclude) - summary['total_files']
    print()
    for line in summary_lines(candidates, summary, hidden_below=hidden,
                              excluded=len(exclude)):
        print(DIM + line + NC)

    if args.no_encode:
        return 0

    shown = candidates
    names = [display_name(Path(c['file_path']), root, 999) for c in shown]
    print(f"\n{Y}Welche encodieren?{NC} z.B. {CYAN}1,3,7-10{NC} · "
          f"{CYAN}a{NC} = alle · {CYAN}a -3{NC} = alle außer 3 · "
          f"{CYAN}Urlaub{NC} = nach Name · {CYAN}Enter{NC} = keine")
    try:
        raw = input("  Auswahl: ")
    except (EOFError, KeyboardInterrupt):
        print()
        return 0

    try:
        picked = select_candidates(raw, names)
    except ValueError as e:
        print(f"{R}{e}{NC}")
        return 1

    if not picked:
        print(f"{Y}Nichts ausgewählt.{NC}")
        return 0

    selected = [shown[i - 1]['file_path'] for i in picked]
    total_mb = sum(shown[i - 1]['estimated_saved_mb'] for i in picked)
    print(f"\n{G}{len(selected)} {_files(len(selected))}{NC}, erwartete Ersparnis "
          f"~{format_size(total_mb)}:")
    for i in picked:
        # Same identification as the table: two files of the same name from
        # different folders must not read as one entry listed twice.
        print(f"  {DIM}·{NC} {names[i - 1]}")

    # Questions only make sense with someone there to answer them: piping a
    # selection in has always started the run, and must keep doing so.
    interactive = sys.stdin.isatty()
    chosen = [shown[i - 1] for i in picked]
    scale_height = None
    replace = False

    try:
        free = shutil.disk_usage(root).free
    except OSError:
        free = None
    if free is not None:
        missing = disk_shortfall(chosen, free)
        if missing:
            print(f"\n{R}Zu wenig Platz:{NC} es fehlen etwa "
                  f"{format_size(missing / (1024 * 1024))} auf diesem Volume.")
            print(DIM + "   Encodes brauchen Platz für Zwischenstände, nicht nur "
                  "für das Ergebnis." + NC)
            if not interactive or not ask_yes_no("Trotzdem starten?", default=False):
                return 0

    if interactive:
        print()
        tall = downscale_candidates(chosen)
        if tall:
            n_label = "Datei ist" if tall == 1 else "Dateien sind"
            if ask_yes_no(f"{tall} {n_label} höher als {DOWNSCALE_TARGET}p. "
                          f"Auf {DOWNSCALE_TARGET}p verkleinern? Das spart meist am meisten.",
                          default=False):
                scale_height = DOWNSCALE_TARGET
        replace = ask_yes_no("Originale nach geprüftem Encode in den Papierkorb legen?",
                             default=False)

        runtime = batch_runtime_sec(chosen, read_encode_history())
        eta = f", geschätzt ~{format_duration(runtime)}" if runtime else ""
        if not ask_yes_no(f"Start? {len(selected)} {_files(len(selected))}, "
                          f"~{format_size(total_mb)} erwartet{eta}", default=True):
            print(f"{Y}Abgebrochen.{NC}")
            return 0

    with tempfile.TemporaryDirectory(prefix="videocrunch_scan_") as tmp:
        results_file = Path(tmp) / "batch.json"
        code = run_batch(selected, args.audio_mode, args.port, scale_height, replace,
                         results_file)
        results = read_batch_results(results_file)

    if not results:
        return code

    print()
    for line in outcome_lines(total_mb, results):
        print(f"{G}{line}{NC}")

    floor = retry_floor(results)
    if floor and interactive:
        failed = [r for r in results if r.get("status") == "failed" and r.get("ssim")]
        print(DIM + "   Die Qualitätsmessung bestraft feinkörniges Material härter, "
              "als das Auge es sieht." + NC)
        if ask_yes_no(f"{len(failed)} {_files(len(failed))} mit --min-ssim {floor:.2f} "
                      f"erneut versuchen?", default=False):
            retry = retry_paths(results)
            if retry:
                return run_batch(retry, args.audio_mode, args.port, scale_height,
                                 replace, min_ssim=floor)
            print(f"{Y}Keine Pfade in den Ergebnissen — bitte manuell wiederholen.{NC}")
    return code


if __name__ == "__main__":
    sys.exit(main())
