# videocrunch

A command-line video optimizer for macOS/Linux: it re-encodes H.264/HEVC video
libraries to HEVC or AV1, using a binary search over encoder quality levels
with SSIM verification to find the smallest file that still looks right —
instead of guessing a single CRF value and hoping. A folder scanner ranks
which files are worth re-encoding before you spend any GPU time on them, and
a parallel batch runner encodes a whole selection at once. On macOS a native
wizard app, reached from a Finder Quick Action, puts the same engine behind a
window.

## Requirements

- Python 3.11+
- ffmpeg and ffprobe 8.1+ on `PATH` (`brew install ffmpeg`)
- A hardware encoder is strongly recommended: Apple VideoToolbox (Apple
  Silicon), NVIDIA NVENC, or Intel QuickSync. `libx265` (software) works as a
  fallback but is much slower.

Optional: [gifski](https://gif.ski) (`brew install gifski`) for the GIF
export; without it ffmpeg's palette filters make the GIF.

For the macOS app only: macOS 14+ and the Swift toolchain from the Xcode
Command Line Tools (`xcode-select --install`). The installer builds the app
from source.

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

There are three ways in on the command line, all built on the same engine
(plus the [macOS app](#macos-app-and-finder-quick-action)):

### 1. `crunch.sh` — the wizard

```bash
bash crunch.sh ~/Videos
```

Point it at a folder and it scans, ranks, and lets you pick what to encode
interactively (this is `scan.py` underneath — see below). Point it at a
single file and it encodes that file directly (`videocrunch.py` underneath).
Any extra flags are passed straight through.

It recommends what the app ticks: recommended files carry a ★ and Enter takes
them, every other row says why it is not suggested. A file that only pays off
at 1080p is offered after the selection, together with the downscale. Piping
an empty line in still selects nothing.

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
binary search), `--scale-height H` (downscale so the shorter side is H —
1080 means 1080p in either orientation, a vertical 4K clip becomes 1080x1920), `--ss`/`--to`
(trim), `--force` (encode even if the savings heuristic says it's not worth
it), `--min-ssim S` (move the hard quality floor for this run — the default
is 0.970; check by eye before lowering it),
`--no-presearch` (skip the sample-clip pre-search, always run the full
search on the whole file), `--json-out PATH` (write the result as JSON — status,
quality, SSIM, savings, in and out paths — whatever the outcome), `--replace`
(put the result in the source's place; the original goes to the trash).

Three switches change the video itself, not only its encoding:
`--half-fps` halves 48–60 fps footage to 24–30 fps (slow motion above that
is left alone; the bitrate ladder drops with it, and the result comes out
about a quarter smaller), `--crop-bars` cuts away black bars that
`cropdetect` finds at five points through the video (only when all agree,
and never more than half the picture), and `--no-audio` leaves the sound
out. The quality check compares against the source with the same edits, so
SSIM measures the encode, not the edit. `batch.py` forwards all three.

### 3. `scan.py` — rank folders and files without encoding anything

```bash
.venv/bin/python3 scan.py ~/Videos --no-encode --limit 20
.venv/bin/python3 scan.py ~/Videos --codec av1 --limit 50 --json > report.json
```

Walks the folder recursively, probes every video with `ffprobe` (a few
seconds even for large libraries — no encoding happens), and prints a table
ranked by expected savings in MB. `--no-encode` stops after printing the
table; otherwise it walks you through the run and hands the selection to
`batch.py` for parallel encoding. Files that already have a
`<name>_opt.mp4` sibling are skipped as done. Given a single video instead of
a folder, it ranks just that one; several paths (folders and files mixed) are
ranked together, each file once.

Picking files takes `1,3,7-10`, `a` for all, `a -3` for all but one, or a
name — `Urlaub` selects everything under that folder. Rows are identified by
their path relative to the scanned folder, because `IMG_1234.mov` in three
import folders is three different videos.

After the selection it asks only what the selection makes relevant:
downscaling is offered when something above 1080p is in it (by the shorter
side: a vertical 1080x1920 clip is 1080p), replacing
the originals is always offered, and the start is confirmed with the expected
savings and — once your history holds enough comparable runs — how long it
should take. Piping a selection in skips the questions entirely and starts
the run, as it always did.

When the batch is done, the estimate is held against what was actually saved,
and anything that failed on quality can be retried right away at a floor that
clears it.
Historical encodes (from `~/.videocrunch/logs/encode_history.jsonl`) are used
to sharpen the estimate where available — the table marks those rows. Only
encodes that reached today's quality target (`MIN_QUALITY`) count, so savings
from passes the search would now reject don't inflate the estimate.

`--json` prints the same `{"results": [...], "summary": {...}}` structure as
machine-readable JSON on stdout instead — nothing else: no banner, no
progress counter, no table, no colour codes, and it never prompts (all the
human-facing chatter that normally goes to the terminal is routed to stderr
instead, so `--json` output is always safe to redirect to a file exactly as
above).

`batch.py` itself (`--files a.mp4,b.mp4 --audio-mode enhanced`) runs the
marked files in parallel with a live status table and a persistent log; you
normally reach it through `scan.py` or the app, not directly. For names that
contain commas, `--files-from list.txt` reads one path per line instead. It
also takes `--codec`, `--min-ssim S`, `--scale-height H` and `--replace` and
forwards them to every per-file encode, reads each worker's verdict from its
`--json-out` file rather than from its console output, and can write the
whole batch's results with its own `--json-out`. `--events` replaces the
table with one JSON object per line (`start`, `file_start`, `progress` with
phase, pass, quality and percent, `file_done`, `summary`); the app reads
those instead of the table. Sending it SIGTERM cancels
the batch: running encodes stop and clean up, queued ones never start, and
those files are reported as `cancelled`.

### 4. `gif.py` — a GIF from a video

```bash
python3 gif.py clip.mov --ss 3 --to 7 --width 480 --fps 15 --quality 90
python3 gif.py clip.mov --estimate     # expected size as JSON, from a 2 s sample
```

Writes `clip.gif` next to the video (`clip 2.gif` if that exists; nothing is
replaced). ffmpeg cuts the range, drops to the frame rate, scales (never up)
and tone-maps HDR (iPhone HLG, HDR10) to BT.709; gifski makes the GIF, or
ffmpeg's `palettegen`/`paletteuse` when gifski is not installed
(`--encoder` picks one). `--speed 0.5` plays it in slow motion, `--speed 2`
as a time-lapse (same frame rate, half or double the frames). `--json-out`
and `--events` work as in `batch.py`.

### 5. `fit.py` — under a size, for mail or chat

```bash
python3 fit.py clip.mov --max-mb 25
python3 fit.py --files-from list.txt --max-mb 10 --no-audio
```

The other question: not "how small can it get and look the same", but "it
has to fit in 25 MB — what is the best it can look". The bitrate follows from
the size and the length; the resolution follows from the bitrate (the
largest of the source, 2160, 1440, 1080, 720, 540, 360 that the bitrate can
fill without turning to mush), and 48–60 fps footage is halved when even
360p would be too much. A first try usually lands; when it comes out over,
the bitrate drops by what was missing and it tries again (three times at
most). Writes `clip_25MB.mp4` next to the video; the original stays. A video
already under the size is skipped, one too long for it says so with the
longest length that would fit. Takes `--codec`, `--half-fps`, `--crop-bars`,
`--no-audio`, `--ss`/`--to`, and `--json-out`/`--events` as in `batch.py`.

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
| `MIN_QUALITY` | `0.980` | Target SSIM: a pass needs `saved% >= MIN_SAVINGS` *and* `SSIM >= MIN_QUALITY` to be picked as the result. No amount of savings lowers it. Calibrated side by side on real footage: from 0.98 on the difference to the source is hard to see, 0.974 already softens foliage, 0.954 smears it. |
| `SSIM_MIN` | `0.970` | Hard floor. Any pass scoring below this is rejected outright and the search moves toward a higher-quality setting, regardless of how much space it saved. |
| `SSIM_ACCEPTABLE` | `0.975` | Preferred *fallback* — used when nothing reaches `MIN_QUALITY`; a pass at or above it wins over one between `SSIM_MIN` and `SSIM_ACCEPTABLE`. |
| `EXCELLENT_SAVINGS_PCT` | `50.0` | Savings % considered so good the search stops early — a pass this size that also reaches `MIN_QUALITY` ends the search instead of trying to squeeze out more. |

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

Before anything is encoded, the run checks that the volume has room for it —
twice the source size per file, because the staging file of the current pass
and the best one kept from an earlier pass exist at the same time. Running
out of space mid-encode is caught by the integrity check either way, but it
costs an hour of encoding to find out.

## What comes across into the output

Every audio track, every text subtitle track, and the container metadata —
capture date, GPS coordinates, camera model — are carried over explicitly.
ffmpeg's default behaviour keeps one audio track and no metadata, which for a
video library means silent data loss. Two things genuinely cannot come along:
Apple's spatial audio (`apple_apac`, no decoder and no mp4 tag) and
image-based subtitles (PGS/VobSub, not convertible to `mov_text`). Both are
reported on stdout as `Stream dropped: …` rather than disappearing quietly, as
are the camera metadata tracks iPhones record (`mebx`), which mp4 cannot hold.

**Dolby Vision** does not come across: the encoders here write no Dolby Vision
metadata, so an iPhone clip (profile 8.4) comes out as plain HLG HDR — still
HDR, without the per-frame tone-mapping data. The run says so (stdout, the
JSON result's `dolby_vision`, the app's result list). Profile 5 sources, whose
base layer only looks right after Dolby Vision processing, are skipped
instead of being re-encoded into false colours.

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

For material above 1080p, `scan.py --json` also reports what the file would
save with the 1080p downscale on (`estimated_saved_pct_1080`,
`estimated_saved_mb_1080`; null otherwise). It follows the encoder's own
budget: the source bitrate scaled by the short-side ratio, never above the
ladder's best rung. The app's options page switches to these numbers when the
downscale is turned on. Each candidate also carries `estimated_runtime_sec` (from
past encodes of its resolution class, null without them), and the summary
`parallel_workers`.

This heuristic is kept in sync with a matching implementation used elsewhere
by a shared test fixture, `savings_parity.json` — a fixed set of
inputs/outputs checked by `tests/test_savings_parity.py`. Changing the
formula without updating the fixture fails the test; the fixture itself
should not be regenerated casually, since its whole purpose is pinning this
math to a known-good set of numbers.

## macOS app and Finder Quick Action

```bash
bash install_macos_quick_action.sh
```

Builds `VideoCrunch.app` from the Swift package in `macos/VideoCrunch/`
(`swift build -c release`; every file under `Sources/` is part of it),
installs it into `/Applications` (`~/Applications` if that isn't writable)
and adds a `videocrunch` entry to `~/Library/Services/`. Drag the app from
the Programme folder into the Dock to keep it there. Ways in:

- drop videos or folders on the Dock icon, or use *Öffnen mit* in Finder
  (the app is registered as an alternative, never as the default for videos);
- right-click files or folders → *Schnellaktionen* → *videocrunch*; everything
  selected arrives in one window. If the entry doesn't show up, enable it
  under System Settings → General → Login Items & Extensions → Finder
  Extensions;
- *Ablage → Öffnen …* (⌘O), or drop onto the window.

There is one window. What is opened while it holds a selection is added to
it; what arrives during an encode is set aside and offered when the run is
done. While it encodes, the Dock icon carries a progress bar and the
window says how much time is left; before the start, the options page says
how long the selection should take (from past encodes of the same resolution,
shown only when every selected file has that history). A run that finishes
while the app is in the background ends with a macOS notification with *Im
Finder zeigen*.

Only what is likely worth it is ticked: a file estimated under the 20 %
savings goal would be thrown away after encoding, and a few megabytes are not
worth the time. Unticked files say why; a file that only pays off downscaled
to 1080p is offered on the options page (*Mitnehmen* ticks it and turns the
downscale on). *Empfohlene* restores that selection. `scan.py --json` carries
it as `recommended`, `recommended_1080` and `advice`.

*Vorschau ansehen* on the options page encodes the hardest few seconds of a
video (its top bitrate hotspot, within the trim) with the current settings —
same ladder, same quality target as the full run — and opens it in the
comparison window, so the result can be judged before an hour of encoding.
On the command line: `videocrunch.py FILE --preview DIR` writes `source.mp4`,
`preview.mp4` and `preview.json` there and nothing next to the source.

With a single video selected, the options page can also make a GIF instead
(*Video verkleinern | GIF erstellen*): width, frame rate and quality, the
trim as its range, and the expected size next to the button, like Gifski.
The finished GIF plays on the last page, next to *Öffnen* and *Teilen*.
*Tempo* makes it a slow motion (½×) or a time-lapse (2×).

*Ziel* on the options page switches from the quality search to a size:
10, 25, 50 or 100 MB per video, for a mail or a chat. The run goes through
`fit.py` then, and the results lie next to the originals as `_10MB.mp4`.
*Ohne Ton* drops the sound; *Auf 30 Bilder/s* (offered only for 48–60 fps
videos) halves the frame rate, which saves about a quarter more — or, with
a size target, leaves more bits for each frame; *Schwarze Balken
abschneiden* crops letterbox bars where there are any.

With a single video selected, the options page offers *Kürzen*: a preview,
a filmstrip and two handles to cut the start and end before encoding (the
original always stays; the savings estimate follows the cut). `batch.py`
forwards `--ss`/`--to` per file for this. Playing loops the trimmed part. For
a few seconds out of a long video: click the filmstrip to jump there, set
the start and end at the playhead with I and O, and switch on the *Lupe*,
which spreads 30 seconds around the selection over the whole strip.

The selection list shows each video's thumbnail; the eye button or the space
bar opens it in Quick Look. After a run, *Vergleichen* opens a window with the
same frame of source and result behind a divider you drag — at the start,
middle or end of the clip, fitted or at 100 % — so the result is judged by
eye, not only by its SSIM. (It needs the original, so it is not offered when
originals went to the trash.) *Neue Videos …* goes back to the start; ⌘Q
quits. Back (⌘[), the current step and *Hinzufügen* sit in the title bar;
the bar at the bottom always shows what the selection will come to — size,
saving and, where history allows, how long it takes — next to the button that
starts it. Run the installer while the app is closed — it refuses otherwise,
rather than cutting off an encode.

The app walks through the same steps as the command-line wizard: **Scan**
(`scan.py --json`), **Auswahl** (pick files, with the expected savings per
file), **Optionen** (target, codec, audio (original sound by default, loudness
levelling or none on request), downscaling to 1080p, 30 fps, black bars,
originals to the trash), **Encode** (`batch.py`, with live progress per file and a Cancel
button that stops and cleans up) and **Fertig** (what each file saved, with a
retry for files just under the quality floor). Started without a file, it
asks for one.

The installer writes this checkout's path into the app's `Info.plist`, so the
app runs the scripts from here. Move the repository, and run the installer
again. A Finder-launched app only sees `/usr/bin:/bin:/usr/sbin:/sbin`; the
app adds `/opt/homebrew/bin` and `/usr/local/bin` itself, so a Homebrew
`ffmpeg` and `python3` are found. It prefers `.venv/bin/python3` if present.

The app icon is drawn in code: `macos/VideoCrunch/Icon/make_icon.swift`,
rebuilt into `AppIcon.icns` by `macos/VideoCrunch/Icon/build_icon.sh`.

The app is built inside the repository (`macos/VideoCrunch/VideoCrunch.app`,
ignored by git) and copied to the Applications folder. Outside the repo the
installer leaves exactly two things; to remove them:

```bash
rm -rf /Applications/VideoCrunch.app ~/Library/Services/videocrunch.workflow
```

## Tests

```bash
.venv/bin/pip install -r requirements-dev.txt
.venv/bin/pytest
.venv/bin/ruff check .
swift test --package-path macos/VideoCrunch   # app logic; needs Xcode for XCTest
```

The app tests cover what the wizard computes and decides without a window:
the savings estimates with 1080p and trimming, where an opened file goes
(scan, add, queue), the preselection, and reading `batch.py --events`.

## License

MIT — see [`LICENSE`](LICENSE). Free usage for everyone.

## Further reading

[`docs/technical-reference.md`](docs/technical-reference.md) — encoder
profile internals, the binary search / SSIM verification machinery, staging
& atomic replace, HDR handling, and the full CLI flag reference.
