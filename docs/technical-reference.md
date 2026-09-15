# videocrunch — Technical Deep-Dive

> `videocrunch.py` · V2.1 · Multi-Platform Hardware Encoder

This is the engine internals reference. For install/usage, see the top-level
[README](../README.md) — this document goes one level deeper into the search
algorithm, encoder profiles, and quality-verification machinery.

---

## Table of Contents

1. [Architecture](#architecture)
2. [Hardware Encoder Profiles](#hardware-encoder-profiles)
3. [Quality Search Strategy](#quality-search-strategy)
4. [SSIM Quality Verification](#ssim-quality-verification)
5. [AV1 Encoding (Experimental)](#av1-encoding-experimental)
6. [Staging & Atomic Replace Strategy](#staging--atomic-replace-strategy)
7. [Sample-Clip Pre-Search](#sample-clip-pre-search)
8. [HDR / 10-bit Safety](#hdr--10-bit-safety)
9. [Two-Pass Linear Loudnorm](#two-pass-linear-loudnorm)
10. [Stream & Metadata Preservation](#stream--metadata-preservation)
11. [Output Integrity Verification](#output-integrity-verification)
12. [Replacing the Source](#replacing-the-source)
13. [Interrupted Runs](#interrupted-runs)
14. [Machine-Readable Result](#machine-readable-result)
15. [Configuration Constants](#configuration-constants)
16. [CLI Reference](#cli-reference)

---

## Architecture

```
┌─────────────────────────────────────────────────────────────┐
│                    optimize_single_file()                    │
│                                                              │
│  1. Probe source (ffprobe → duration, resolution, codec,    │
│     pix_fmt, color_transfer/primaries for HDR detection)    │
│  2. Pre-flight gate: savings.py estimate < PREFLIGHT_SKIP_PCT│
│     → skip entirely, unless --force                         │
│  3. Files >= PRESEARCH_MIN_DURATION: probe a short clip cut  │
│     from the bitrate hotspots first (see Pre-Search below)  │
│  4. Binary search over the encoder's quality range           │
│                                                              │
│        ┌────────────────────────────────────────────┐       │
│        │         run_encode_pass(quality, ...)       │       │
│        │                                             │       │
│        │  a. ffmpeg encode → unique staging file      │       │
│        │  b. Check: size_after < EARLY_ABORT_RATIO   │       │
│        │  c. Check: savings >= MIN_SAVINGS_FOR_SSIM   │       │
│        │  d. get_multi_ssim() → score                 │       │
│        │  e. Return (success, size, ssim, error)      │       │
│        └────────────────────────────────────────────┘       │
│                                                              │
│  5. If pass succeeds → promote_staging() verifies integrity │
│     and atomically renames staging → original                │
│  6. Append a record to ~/.videocrunch/logs/encode_history.jsonl│
└─────────────────────────────────────────────────────────────┘
```

---

## Hardware Encoder Profiles

Each encoder is a profile dict in `ENCODER_PROFILES` (`videocrunch.py`) that
gives the search a unified interface regardless of platform.

| Profile Key | Encoder | Platform | Quality Flag | Quality Range (start, max, step) |
|:---|:---|:---|:---|:---|
| `nvenc` | `hevc_nvenc` | Windows/Linux (NVIDIA) | `-cq` | 24 → 44, step 4 |
| `videotoolbox` | `hevc_videotoolbox` | macOS (Apple Silicon + Intel) | `-q:v` | 75 → 45, step -10 |
| `qsv` | `hevc_qsv` | Windows/Linux (Intel QuickSync) | `-global_quality` | 20 → 32, step 2 |
| `vaapi` | `hevc_vaapi` | Linux (Intel/AMD) | `-qp` | 24 → 34, step 2 |
| `libx265` | `libx265` | Any (CPU fallback) | `-crf` | 24 → 32, step 2 |
| `av1_software` | `libsvtav1` | Any (CPU, SVT-AV1) | `-crf` | 26 → 40, step 2 |
| `av1_nvenc` | `av1_nvenc` | NVIDIA RTX 40xx (Ada Lovelace) | `-cq` | 28 → 48, step 4 |

**`quality_direction`** abstracts the difference between profiles: `+1` means
"increase the number = worse quality" (CQ/QP/CRF-style), `-1` means
"decrease the number = worse quality" (VideoToolbox's `-q:v`). The search
stays direction-agnostic by branching on this flag rather than hard-coding
per-encoder logic.

`--encoder auto` picks the best available profile for the current machine
(`encoders.py` queries `ffmpeg -encoders`); `--preset {fast,balanced,best}`
maps to encoder-specific ffmpeg presets via `ENCODING_PRESET_MAP` (e.g.
NVENC's `p2`/`p5`/`p7`, libx265's `veryfast`/`medium`/`slow`).

### NVIDIA NVENC specifics

```python
'-preset': 'p5',          # overridden by --preset via ENCODING_PRESET_MAP
'-tune': 'hq',
'-rc': 'vbr',
'-multipass': 'fullres',  # two-pass at full resolution
'-tier': 'high',          # lifts the bitrate ceiling ~6x vs Main — needed for 4K
'-spatial-aq': '1',
'-temporal-aq': '1',
'-aq-strength': '15',     # max AQ strength — protects fine detail in dark areas
'-weighted_pred': '1',
'-rc-lookahead': '32',
```

### Apple VideoToolbox specifics

```python
'-allow_sw': '0'        # force hardware-only — abort if hardware unavailable
'-realtime': '0'        # allow the encoder more time -> better compression
'-profile:v': 'main'    # HEVC Main Profile — widest compatibility
'-alpha_quality': '0.75'
```

---

## Quality Search Strategy

The search is a **binary search over the profile's quality range**, not a
fixed CRF guess. Each candidate pass targets a **constrained VBR bitrate**
computed from the source's average bitrate — steepest at the low-quality end
(~45% of source), gentlest near the savings goal — so stepping the search
actually moves output size; `-q:v`/`-cq` alone don't reliably control size on
every encoder.

**Early exit / bias conditions:**
- `EXCELLENT_SAVINGS_PCT = 50.0` — a pass this good that also clears the
  quality bar ends the search immediately.
- `EARLY_ABORT_RATIO = 0.95` — abort mid-encode if the output is already at
  95% of source size (no point finishing that pass).
- An "educated jump" skips several binary-search steps at once when a pass
  massively overshoots its bitrate target, instead of creeping one step at a
  time.
- `--q N` forces a starting quality and searches linearly from there instead
  of via binary search.

**SSIM threshold decision tree** (see [Configuration Constants](#configuration-constants) for values):

| SSIM Score | Savings | Outcome |
|:---|:---|:---|
| ≥ `MIN_QUALITY` | ≥ `MIN_SAVINGS` | Strict success — promote immediately |
| ≥ `MIN_QUALITY` or `SSIM_ACCEPTABLE` | ≥ `EXCELLENT_SAVINGS_PCT` | Excellent — early exit |
| ≥ `SSIM_ACCEPTABLE` | ≥ `MIN_SAVINGS` | Stored as fallback, search continues |
| ≥ `SSIM_MIN` | any | Not useful — discard, try next step |
| < `SSIM_MIN` | any | Hard abort — rescue the best fallback if one exists |

A run that ends with nothing above the floor keeps its closest miss as
`<name>_rejected.mp4` instead of deleting it, and reports the measurement plus
the exact flag that would accept it (`rejection_hint()`). The numbers alone
cannot say whether an encode is usable — fine-grained real footage scores far
below the floor while looking untouched — and re-running to find out costs as
much as the original run did. `scan.py` skips `_rejected.mp4` files the same
way it skips `_opt.mp4`.

Without fallback tracking, a search that never clears the strict `MIN_QUALITY`
bar fails outright and the original is kept untouched, 0 bytes saved. With
it, the best pass that cleared `SSIM_ACCEPTABLE` is promoted instead.

---

## SSIM Quality Verification

### Multi-Point Sampling

`get_multi_ssim()` samples `SAMPLE_DURATION`-second windows at three points
along the video in a **single FFmpeg `filter_complex` pass** — trimming and
concatenating both the source and candidate clips before comparing once,
rather than running three separate FFmpeg processes (each of which would
re-seek and re-decode from the start, tripling the time cost).

Windows are cut by **frame index**, not by timestamp, and both branches are
re-stamped onto one timebase (`settb=AVTB,setpts=N/fps/TB`) before the
comparison. A time-based trim picks the first frame whose timestamp reaches
the mark — and the two files' timestamp grids drift apart (an iPhone 120 fps
source carries a 1/2400 timebase, the encode a 1/15360 one), so the same mark
lands on different pictures and the filter ends up comparing frame N with
frame N+2. On fast motion that alone dropped a measured 0.943 to 0.716 and
failed encodes that were visually fine. When the source fps cannot be
determined, sampling falls back to timestamp trims.

### MS-SSIM vs SSIM Auto-Detection

On startup, videocrunch queries `ffmpeg -filters` and prefers `mssim`
(Multi-Scale SSIM) when the installed FFmpeg build supports it, falling back
to plain `ssim` otherwise:

```python
_QUALITY_FILTER = 'mssim' if 'mssim' in result.stdout else 'ssim'
```

MS-SSIM evaluates quality at multiple resolution scales simultaneously,
which is more perceptually accurate for fast motion, high-frequency detail
(UI/text overlays), and mismatched sample resolutions.

### SSIM Skip on Poor Savings

A preliminary savings check runs before `get_multi_ssim()` is even called:
if a pass saved less than 10% (`MIN_SAVINGS_FOR_SSIM`, well below the 20%
acceptance floor), the staging file is deleted and the pass is marked
`poor_savings` without spending 10-20 seconds computing SSIM on a result
that was never going to be accepted anyway.

---

## AV1 Encoding (Experimental)

| Profile | Hardware | Notes |
|:---|:---|:---|
| `av1_nvenc` | NVIDIA RTX 40xx (Ada Lovelace) or newer | Full NVENC feature set: multipass, spatial/temporal AQ, high tier |
| `av1_software` | Any (SVT-AV1, CPU) | Software fallback — much slower than hardware HEVC |

There is currently no VideoToolbox AV1 hardware profile (Apple has not
shipped hardware AV1 encode as of this writing). `--codec av1` selects
`av1_nvenc` when NVENC AV1 is available, otherwise falls back to
`av1_software`.

```bash
.venv/bin/python3 videocrunch.py video.mp4 --codec av1
```

---

## Staging & Atomic Replace Strategy

videocrunch never writes directly to the source file:

1. **Encode to a unique staging path** per quality candidate:
   `<stem>._staging_q<N><suffix>` next to the output.
2. **Verify**: `verify_output_integrity()` checks duration (±1.5s tolerance)
   and does a full error-strict decode (`ffmpeg -xerror -f null`).
3. **Atomic replace**: `promote_staging()` only calls `staging.rename(output_path)`
   after integrity passes.
4. **On failure**: the staging file is deleted; the source is untouched.
5. Leftover staging files from interrupted runs are cleaned up on the next
   pass via `_cleanup_staging()`.

This guarantees a power failure, disk error, or bad encode can never corrupt
or delete the original file.

---

## Sample-Clip Pre-Search

For files at or above `PRESEARCH_MIN_DURATION` (120s), the full binary
search doesn't run against the whole file first. Instead, a short probe clip
(`PRESEARCH_SEGMENT_SEC`, 8s per segment) is stream-copied from the file's
bitrate **hotspots** — the hardest material to compress — and the quality
search runs on that probe first, within `PROBE_TARGET_TOLERANCE` (1.25x) of
target. The full-file search is then narrowed around the probe's result,
typically needing 1-2 real full-file passes instead of 3-4. Disable with
`--no-presearch`.

---

## HDR / 10-bit Safety

Source `pix_fmt`, `color_transfer`, and `color_primaries` are probed
up front. When `is_hdr_or_10bit()` detects an HDR or 10-bit source and
`video_mode == 'compress'`, `apply_hdr_adjustments()` switches the chosen
profile to a main10 encode with the source's color tags (BT.2020/PQ/HLG)
passed through — encoders that don't support main10 skip the file with a
clear reason rather than silently mistagging a downgraded encode as BT.709.

---

## Two-Pass Linear Loudnorm

`measure_loudness()` runs one audio-only null pass per file (same pre-chain
as the real encode) to measure source loudness, then every encode pass uses
`loudnorm=...:measured_*:linear=true` — transparent normalization without
the pumping artifacts of single-pass dynamic loudnorm. Skipped for trims
(`--ss`/`--to`) and silent/unmeasurable audio, which fall back to dynamic
mode.

---

## Stream & Metadata Preservation

Left to its own devices, ffmpeg keeps one video and one audio stream and
discards everything else, and it copies no container metadata at all. For a
tool pointed at someone's video library that is silent data loss: second
language tracks, commentary, subtitles, and — on phone recordings — the
capture date, GPS coordinates and camera model.

`probe_stream_inventory()` reads the source's stream list once per file, and
`build_stream_args()` (`crunch_utils.py`) turns it into an explicit mapping:

| Stream | Treatment |
|:---|:---|
| Video | `-map 0:v:0` |
| Audio | every track mapped; the first gets the loudnorm chain (`-filter:a:0`), the rest are re-encoded flat. `--copy-audio` copies instead |
| Subtitles | text-based (`subrip`, `ass`, `webvtt`, …) converted to `mov_text` |
| Data | never mapped — the mp4 muxer rejects most of them (iPhone timecode/metadata tracks) |

A track that cannot come along is **named on stdout** (`Stream dropped: …`)
rather than vanishing. Two cases exist in practice: Apple's spatial audio
(`apple_apac`) has neither an mp4 tag nor a decoder in ffmpeg, and image-based
subtitles (PGS, VobSub) cannot be converted to `mov_text`. Mapping either one
blindly aborts the whole encode, so both are skipped deliberately.
`available_decoders()` answers the decodability question from
`ffmpeg -decoders` at runtime instead of a hardcoded list.

Container metadata is carried by `-map_metadata 0` plus
`-movflags +use_metadata_tags`; without the latter the muxer writes only the
handful of tags it knows and QuickTime keys are lost. The source's own
container brands are blanked (`-metadata major_brand=` …) so they are not
written next to the muxer's own. One cosmetic side effect remains: the
capture date ends up in both the `mvhd` atom and a `udta` key, so
`ffprobe -show_entries format_tags=creation_time` reports the same value
twice, joined by a semicolon. Players read `mvhd`, Photos reads
`com.apple.quicktime.creationdate`; both are correct.

---

## Output Integrity Verification

Before any staging file is promoted (`promote_staging()`), it must pass
`verify_output_integrity()`: an ffprobe duration match within 1.5 seconds,
a full error-strict video decode, and an audio track count at least as high
as the encode planned to carry over. This catches truncated moov atoms and
encoder/driver corruption that 3-window SSIM sampling alone can miss — and
stops a regression in stream mapping from quietly shipping files with tracks
missing. The expectation comes from the mapping itself, so a deliberately
skipped track (see above) does not count as a loss.

---

## Replacing the Source

By default a run leaves `<name>_opt.mp4` next to the source, so a library gets
*bigger* until someone tidies up by hand. `--replace` closes that loop: after
the output passes `verify_output_integrity()`, the original is moved to the
trash and the result takes its name.

- **The extension follows the container.** `IMG_1438.mov` becomes
  `IMG_1438.mp4`, because that is what the file now is. References to the old
  name break — that is the trade the flag makes.
- **Refused rather than guessed.** If `IMG_1438.mp4` already exists next to
  `IMG_1438.mov`, they are two different videos; the run keeps the original
  and says so.
- **Never for trims or copy mode** (`should_replace()`): `--ss`/`--to` produce
  an excerpt, and copy mode exists to produce a second file. Replacing the
  source with either destroys what was not in the output.
- **The trash, not `unlink()`.** The file is moved into `~/.Trash`, or into
  the volume's own `.Trashes/<uid>` when it lives elsewhere — a rename either
  way, so a 4K source costs nothing to trash. Asking the Finder to delete it
  would have been shorter, but the Finder reports success even where it
  bypasses the trash; moving the file ourselves is the only way to know where
  it went. The cost is that macOS "Put Back" is not available for these files.
- A failure to reach the trash leaves the original in place. "Kept" is always
  a safe outcome; "deleted without a copy" never is.

---

## Interrupted Runs

Each quality pass encodes to `<stem>._staging_q<N>.mp4`. Interrupting used to
delete all of them, so a run stopped between two 4K passes paid for them again
next time. Now Ctrl-C asks whether to keep the finished ones — but only when
someone is at the terminal (`keep_stagings_after_abort()`); an unattended
script that dies leaves the folder as it found it.

On the next run, `reusable_staging()` checks each leftover against the full
integrity check (duration, decode, track count). One that passes is a finished
pass: the encode is skipped and only the quality measurement runs. A file
killed mid-write has no moov atom — with `+delay_moov` it cannot be mistaken
for a complete encode — and is re-encoded normally.

---

## Machine-Readable Result

`--json-out PATH` writes one JSON object per run:

```json
{"videocrunch": 1, "results": [{"filename": "clip.mp4", "input_path": "/abs/clip.mp4",
  "output_path": "/abs/clip_opt.mp4", "status": "success", "quality": 60,
  "ssim": 0.996051, "saved_pct": 25.6, "saved_bytes": 514507, "duration": 2.7,
  "reason": null, "height": 480, "source_kbps": 2678.09}]}
```

It is written whatever the outcome — `success`, `failed`, `skipped` — and the
paths are absolute, since consumers run from their own working directory. The
list wraps even a single file so a run over several has the same shape.

`batch.py` hands every worker its own result file and takes the verdict from
it, falling back to scraping stdout when the file is missing (an aborted
worker leaves none). It writes the whole batch in the same shape through its
own `--json-out`, which is how `scan.py` learns what a run delivered: without
it the wizard saw an exit code and nothing else, so it could neither check
its own estimate nor offer to retry what fell under the quality floor. That fallback is why the shape is pinned in
`tests/test_cli_contract.py`: output lines are human-facing and get reworded,
which is exactly what made scraping them fragile in the first place.

---

## Configuration Constants

All tuning constants live at the top of `videocrunch.py`:

| Constant | Default | Purpose |
|:---|:---|:---|
| `MIN_SAVINGS` | `20.0` | Minimum % savings a pass must hit to be accepted |
| `MIN_QUALITY` | `0.960` | Minimum SSIM for a strict accept |
| `SSIM_ACCEPTABLE` | `0.945` | SSIM floor for a fallback accept |
| `SSIM_MIN` | `0.940` | Hard lower bound — reject below this regardless of savings (`--min-ssim` overrides per run) |
| `SAMPLE_DURATION` | `3` | Seconds per sample window for SSIM |
| `EXCELLENT_SAVINGS_PCT` | `50.0` | Early-exit threshold in the binary search |
| `EARLY_ABORT_RATIO` | `0.95` | Abort mid-encode once output reaches this fraction of source size |
| `MIN_SAVINGS_FOR_SSIM` | `10.0` | Skip SSIM entirely when savings are below this |
| `PRESEARCH_MIN_DURATION` | `120.0` | Minimum source duration to run the sample-clip pre-search |
| `PRESEARCH_SEGMENT_SEC` | `8.0` | Length of each stream-copied probe segment |
| `PROBE_TARGET_TOLERANCE` | `1.25` | Allowed overshoot of the probe pass vs. target bitrate |
| `PREFLIGHT_SKIP_PCT` | `MIN_SAVINGS * 0.5` | Predicted savings below this skip the file entirely (unless `--force`) |
| `DEFAULT_MIN_SIZE_MB` | `0` | No minimum file size — process all files |

---

## CLI Reference

```
usage: videocrunch.py [-h]
                      [--encoder {auto,av1_nvenc,av1_software,libx265,nvenc,qsv,vaapi,videotoolbox}]
                       [--codec {hevc,av1}] [--min-size MIN_SIZE]
                       [--copy-audio]
                       [--audio-mode {enhanced,moderate,standard}] [--ss SS]
                       [--to TO] [--video-mode {compress,copy}] [--q Q]
                       [--scale-height H] [--port PORT]
                       [--preset {fast,balanced,best}] [--force]
                       [--min-ssim S] [--replace] [--json-out PATH]
                       [--no-presearch]
                       [files ...]
```

| Flag | Purpose |
|:---|:---|
| `--encoder` | Encoder to use (default: auto-detect) |
| `--codec {hevc,av1}` | Target codec (default: hevc) |
| `--min-size MIN_SIZE` | Skip files smaller than N MB |
| `--copy-audio` | Copy audio without re-encoding |
| `--audio-mode {enhanced,moderate,standard}` | Loudness target: moderate (default, -19 LUFS), enhanced (-16 LUFS), standard (no normalization) |
| `--ss` / `--to` | Trim start/end time before encoding |
| `--video-mode {compress,copy}` | compress (default) or passthrough |
| `--q N` | Manual starting quality — searches linearly from there instead of binary search |
| `--scale-height H` | Downscale to H pixels height (ignored if >= source height) |
| `--port PORT` | Notify a companion server on this port when a file is done, via `GET /api/mark_optimized?path=<path>` |
| `--preset {fast,balanced,best}` | Encoder-specific speed/quality preset |
| `--force` | Encode even when `savings.py` predicts it isn't worth it |
| `--min-ssim S` | Move the hard quality floor for this run (0 < S ≤ 1, default `SSIM_MIN`); `batch.py` accepts it too and forwards it per file |
| `--replace` | Put the result in the source's place; the original goes to the trash |
| `--json-out PATH` | Write the run's machine-readable result to PATH (see below) |
| `--no-presearch` | Always run the full search on the whole file |

Examples:

```bash
# Standard HEVC compression, auto-detected encoder
.venv/bin/python3 videocrunch.py video.mp4

# AV1, starting search at quality 55
.venv/bin/python3 videocrunch.py video.mp4 --codec av1 --q 55

# Best-quality preset, standard (unmodified) audio
.venv/bin/python3 videocrunch.py video.mp4 --preset best --audio-mode standard
```
