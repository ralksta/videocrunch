# videocrunch

A command-line video optimizer for macOS/Linux: it re-encodes H.264/HEVC video
libraries to HEVC or AV1, using a binary search over encoder quality levels
with SSIM verification to find the smallest file that still looks right —
instead of guessing a single CRF value and hoping. A folder scanner ranks
which files are worth re-encoding before you spend any GPU time on them, and
a parallel batch runner encodes a whole selection at once.

## Requirements

- Python 3.11+
- ffmpeg and ffprobe 8.1+ on `PATH` (`brew install ffmpeg`)
- A hardware encoder is strongly recommended: Apple VideoToolbox (Apple
  Silicon), NVIDIA NVENC, or Intel QuickSync. `libx265` (software) works as a
  fallback but is much slower.

videocrunch has **zero runtime dependencies** — it's plain Python standard
library plus the `ffmpeg`/`ffprobe` binaries. `pip install` is only needed
for the test/lint toolchain.

## Install

```bash
git clone https://github.com/ralksta/videocrunch.git
cd videocrunch
python3 -m venv .venv
# Optional, only needed to run the test suite / linter:
.venv/bin/pip install -r requirements-dev.txt
```

`crunch.sh` picks up `.venv/bin/python3` automatically if present, and falls
back to whatever `python3` is on `PATH` otherwise — the venv is convenience,
not a requirement.

## Usage

There are three ways in, all built on the same engine:

### 1. `crunch.sh` — the wizard

```bash
bash crunch.sh ~/Videos
```

Point it at a folder and it scans, ranks, and lets you pick what to encode
interactively (this is `scan.py` underneath — see below). Point it at a
single file and it encodes that file directly (`videocrunch.py` underneath).
Any extra flags are passed straight through:

```bash
bash crunch.sh ~/Videos --audio-mode standard
bash crunch.sh ~/Videos/clip.mp4 --codec av1 --preset best
```

### 2. `videocrunch.py` — encode one file (or several)

```bash
.venv/bin/python3 videocrunch.py clip.mp4 [clip2.mp4 ...]
```

Key flags: `--codec {hevc,av1}` (default hevc), `--encoder
{auto,av1_nvenc,av1_software,libx265,nvenc,qsv,vaapi,videotoolbox}` (default auto-detect), `--preset
{fast,balanced,best}`, `--audio-mode {enhanced,moderate,standard}`, `--q N`
(force a starting quality and search linearly from there instead of via
binary search), `--scale-height H` (downscale before encoding), `--ss`/`--to`
(trim), `--force` (encode even if the savings heuristic says it's not worth
it), `--min-ssim S` (move the hard quality floor for this run — fine-grained
real footage can look perfect and still score below the default 0.940),
`--no-presearch` (skip the sample-clip pre-search, always run the full
search on the whole file), `--json-out PATH` (write the result as JSON — status,
quality, SSIM, savings, in and out paths — whatever the outcome), `--replace`
(put the result in the source's place; the original goes to the trash).

### 3. `scan.py` — rank a folder without encoding anything

```bash
.venv/bin/python3 scan.py ~/Videos --no-encode --limit 20
.venv/bin/python3 scan.py ~/Videos --codec av1 --limit 50 --json > report.json
```

Walks the folder recursively, probes every video with `ffprobe` (a few
seconds even for large libraries — no encoding happens), and prints a table
ranked by expected savings in MB. `--no-encode` stops after printing the
table; otherwise it walks you through the run and hands the selection to
`batch.py` for parallel encoding. Files that already have a
`<name>_opt.mp4` sibling are skipped as done.

Picking files takes `1,3,7-10`, `a` for all, `a -3` for all but one, or a
name — `Urlaub` selects everything under that folder. Rows are identified by
their path relative to the scanned folder, because `IMG_1234.mov` in three
import folders is three different videos.

After the selection it asks only what the selection makes relevant:
downscaling is offered when something taller than 1080p is in it, replacing
the originals is always offered, and the start is confirmed with the expected
savings and — once your history holds enough comparable runs — how long it
should take. Piping a selection in skips the questions entirely and starts
the run, as it always did.

When the batch is done, the estimate is held against what was actually saved,
and anything that failed on quality can be retried right away at a floor that
clears it.
Historical encodes (from `~/.videocrunch/logs/encode_history.jsonl`) are used
to sharpen the estimate where available — the table marks those rows.

`--json` prints the same `{"results": [...], "summary": {...}}` structure as
machine-readable JSON on stdout instead — nothing else: no banner, no
progress counter, no table, no colour codes, and it never prompts (all the
human-facing chatter that normally goes to the terminal is routed to stderr
instead, so `--json` output is always safe to redirect to a file exactly as
above).

`batch.py` itself (`--files a.mp4,b.mp4 --audio-mode enhanced`) runs the
marked files in parallel with a live status table and a persistent log; you
normally reach it through `scan.py`, not directly. It also takes
`--min-ssim S`, `--scale-height H` and `--replace` and forwards them to every
per-file encode, reads each worker's verdict from its `--json-out` file
rather than from its console output, and can write the whole batch's results
with its own `--json-out`.

## How the quality search works

The engine (`videocrunch.py`) does not pick one CRF/quality value and encode
once. For each file it runs a **binary search over the encoder's quality
range** (e.g. NVENC's CQ 24–44, VideoToolbox's q:v scale), where each
candidate pass:

1. Targets a **constrained VBR bitrate**, not unconstrained quality-VBR. The
   search computes a per-quality-level bitrate ladder from the source's
   average bitrate (steepest at the low-quality end, ~45% of source; gentlest
   at the high-quality end, just inside the savings goal) so that stepping
   through the search actually moves the output file size — plain `-q:v`
   alone doesn't reliably control size on every encoder.
2. Runs the encode (or, for files over ~2 minutes, first probes a short clip
   cut from the file's bitrate *hotspots* — the hardest material to compress
   — so the full-file pass only runs once the search has narrowed in).
3. Measures **SSIM** against the source to check the pass didn't go too far.
   Sample windows are cut by frame index, not by timestamp: a source and its
   encode carry different timebases (an iPhone 120 fps clip 1/2400, the encode
   1/15360) and their grids drift apart over the file, so the same timestamp
   lands on different pictures. Comparing frame N against frame N+2 of fast
   motion dropped a measured 0.943 to 0.716 and failed encodes that were
   visually perfect.
4. Compares the result's savings % and SSIM against the thresholds below,
   and narrows the search range up (more compression) or down (better
   quality) accordingly — with an early exit once a pass is already
   excellent, and an "educated jump" that skips several binary-search steps
   at once when a pass massively overshoots its bitrate target instead of
   creeping toward it one step at a time.

Where the thresholds are, and what they do (`videocrunch.py`, "CONFIGURATION"
/ "SSIM / SAVINGS THRESHOLDS" sections):

| Constant | Value | Meaning |
|---|---|---|
| `MIN_SAVINGS` | `20.0` | Minimum file-size reduction (%) a pass must hit to be accepted. Also derives the top of the constrained-VBR bitrate ladder — a pass that can't clear this even at its target size is a guaranteed-failure rung and isn't tried. |
| `MIN_QUALITY` | `0.960` | Target SSIM for a normal accept: a pass needs `saved% >= MIN_SAVINGS` *and* `SSIM >= MIN_QUALITY` to be picked as the primary result. |
| `SSIM_MIN` | `0.940` | Hard floor. Any pass scoring below this is rejected outright and the search moves toward a higher-quality setting, regardless of how much space it saved. |
| `SSIM_ACCEPTABLE` | `0.945` | Quality bar for the *fallback* result — used when nothing clears `MIN_QUALITY` but something between `SSIM_MIN` and `SSIM_ACCEPTABLE` still saved real space, so a 53%-savings pass at SSIM 0.944 isn't thrown away. |
| `EXCELLENT_SAVINGS_PCT` | `50.0` | Savings % considered so good the search stops early — a pass this size that also clears `SSIM_ACCEPTABLE` (or `MIN_QUALITY`) ends the search immediately instead of trying to squeeze out more. |

Tune these at the top of `videocrunch.py` if your material or standards
differ — e.g. lower `MIN_QUALITY` for casual footage where a bit more
softness is an acceptable trade for extra savings, or raise `SSIM_MIN` if
you're archiving something you never want visibly degraded.

## When a run comes up short

A run whose best encode stays under the quality floor keeps that encode as
`<name>_rejected.mp4` and tells you what it measured and which flag would
accept it — rather than deleting minutes of work and leaving you to guess.
Fine-grained real footage (sand, water, film grain) routinely scores well
below the floor while looking untouched, so this is a question only your eyes
can settle.

Interrupting a run with Ctrl-C asks whether to keep the passes that already
finished; the next run reuses them instead of encoding them again.

## What comes across into the output

Every audio track, every text subtitle track, and the container metadata —
capture date, GPS coordinates, camera model — are carried over explicitly.
ffmpeg's default behaviour keeps one audio track and no metadata, which for a
video library means silent data loss. Two things genuinely cannot come along:
Apple's spatial audio (`apple_apac`, no decoder and no mp4 tag) and
image-based subtitles (PGS/VobSub, not convertible to `mov_text`). Both are
reported on stdout as `Stream dropped: …` rather than disappearing quietly.

## How the savings estimate works

Before any encoding happens, `savings.py` estimates a file's likely savings
% from `ffprobe` metadata alone (resolution, current bitrate, source codec)
— no encoding, no SSIM, just a heuristic used to rank candidates in
`scan.py` and as a pre-flight gate in `videocrunch.py` (files predicted well
under `MIN_SAVINGS` are skipped before spending any encode time on them,
unless `--force` is given). It compares the source's bitrate against a
reference bitrate for a clean encode at that resolution/codec, adjusted by a
codec-efficiency table (e.g. HEVC needs roughly 65% of H.264's bitrate for
the same perceived quality; AV1 roughly 55%).

This heuristic is kept in sync with a matching implementation used elsewhere
by a shared test fixture, `savings_parity.json` — a fixed set of
inputs/outputs checked by `tests/test_savings_parity.py`. Changing the
formula without updating the fixture fails the test; the fixture itself
should not be regenerated casually, since its whole purpose is pinning this
math to a known-good set of numbers.

## macOS Finder Quick Action

```bash
bash install_macos_quick_action.sh
```

Installs a `videocrunch` entry into `~/Library/Services/`, so right-clicking
a folder in Finder → *Schnellaktionen* (Quick Actions) → *videocrunch* opens
a Terminal window running `crunch.sh` on that folder. The path is passed to
AppleScript via `quoted form`, so folder names with spaces or apostrophes
work correctly. If the entry doesn't show up, enable it under System
Settings → General → Login Items & Extensions → Finder Extensions.

The installer restarts Finder (`killall Finder`) to make it pick up the new
service — this is expected, Finder relaunches immediately, and it only adds
its own `videocrunch.workflow` bundle without touching any other Quick
Action you already have installed.

To uninstall the Quick Action again:

```bash
rm -rf ~/Library/Services/videocrunch.workflow && killall Finder
```

That bundle is the installer's only footprint outside this repo — nothing
else is written to the system.

## Tests

```bash
.venv/bin/pip install -r requirements-dev.txt
.venv/bin/pytest
.venv/bin/ruff check .
```

## License

MIT — see [`LICENSE`](LICENSE). Free usage for everyone.

## Further reading

[`docs/technical-reference.md`](docs/technical-reference.md) — encoder
profile internals, the binary search / SSIM verification machinery, staging
& atomic replace, HDR handling, and the full CLI flag reference.
