---
name: videocrunch
description: 'Optimize and shrink H.264/HEVC video libraries to HEVC or AV1 with hardware acceleration and SSIM quality verification, rank folder savings, fit videos under a target MB size, or export high-quality GIFs using local FFmpeg/gifski.'
---

# videocrunch

## Quick start

Run `python3 <skill-dir>/<script>.py` (or `.venv/bin/python3` if present); zero Python dependencies beyond stdlib plus `ffmpeg`/`ffprobe` 8.1+ on `PATH` (and optional `gifski` for `gif.py`).

### Request → script

| User says | Do |
|---|---|
| "which videos in this folder are worth shrinking?" | `scan.py FOLDER --no-encode --json` |
| "shrink / re-encode this video without losing quality" | `videocrunch.py FILE --json-out result.json` |
| "show me a preview of the hardest part first" | `videocrunch.py FILE --preview DIR` (inspect `DIR/source.mp4`, `DIR/preview.mp4`, `DIR/preview.json`) |
| "shrink all recommended videos in this folder" | `scan.py FOLDER --json --no-encode`, then `batch.py --files-from list.txt --events --json-out batch.json` |
| "shrink and downscale 4K to 1080p / halve 60fps / crop black bars" | `videocrunch.py FILE --scale-height 1080 --half-fps --crop-bars --json-out result.json` |
| "trim losslessly without re-encoding" | `videocrunch.py FILE --ss 00:00:10 --to 00:00:30 --video-mode copy --copy-audio --json-out result.json` |
| "make this fit under 25 MB for mail / chat" | `fit.py FILE --max-mb 25 --json-out result.json` |
| "make a GIF from 3s to 7s" | `gif.py FILE --ss 3 --to 7 --width 480 --fps 15 --quality 90 --json-out result.json` (`--estimate` checks expected size first) |

## Workflow (in this order)

1. **Probe & rank first (`scan.py --no-encode --json`)** — inspect codec, resolution, bitrate, `recommended`, `recommended_1080`, `estimated_saved_mb`, and `advice` before spending GPU/CPU time. Never guess from filenames.
2. **Check savings & disk headroom** — `videocrunch.py` skips files predicted below `PREFLIGHT_SKIP_PCT` (`10%`) unless `--force` is passed, and requires **2× source size** in free disk space per concurrent file (current staging pass + best fallback pass coexist on disk).
3. **Preview or encode** — for long or sensitive footage, run `videocrunch.py FILE --preview DIR` on the bitrate hotspot first; otherwise run `videocrunch.py` (single file) or `batch.py --files-from ... --events --json-out ...` (multi-file). Never run raw `ffmpeg` directly for tasks covered by these scripts.
4. **Verify via JSON output** — always pass `--json-out PATH` and check the parsed JSON (`status`, `ssim`, `saved_pct`, `saved_bytes`, `output_path`, `dropped`, `dolby_vision`, `reason`) rather than scraping stdout.

## Gotchas & Guarantees

- **10-bit SDR vs. HDR:** `is_hdr_or_10bit()` switches `videocrunch.py` and `fit.py` to a 10-bit `main10` encode, while `is_hdr()` ensures BT.2020/PQ/HLG color tags are passed through **only** for real HDR/BT.2020 sources. 10-bit SDR sources (e.g. GoPro `yuv420p10le` in BT.709) keep BT.709 color tags.
- **Dolby Vision:** Profile 8.4 (iPhone) keeps its HLG base layer and Profile 8.1 keeps HDR10 (`dolby_vision` in the JSON reports `kept_as`). Profile 5 has no compatible base layer (`kept_as: null`) and is skipped to avoid false colours.
- **Stream & metadata preservation:** `build_stream_args()` maps `-map 0:V:0` (skipping embedded cover art `attached_pic`), carries every decodable audio stream and text subtitle (`mov_text`), and preserves container metadata (`-map_metadata 0 -movflags +use_metadata_tags`). Dropped tracks (`apple_apac`, PGS/VobSub, `mebx` data) are explicitly reported in `dropped` and on stdout.
- **Loudnorm room-tone protection:** Two-pass linear `loudnorm` (`moderate`: -19 LUFS, `enhanced`: -16 LUFS) skips normalization automatically when integrated loudness is at or below `-40 LUFS` (`ROOM_TONE_FLOOR_LUFS`) so ambient noise is not boosted by 20+ dB, and checks whether FFmpeg will actually run in linear or dynamic mode (`loudnorm_will_be_linear()`).
- **Quality floor & rejected rescue:** Default thresholds are `MIN_SAVINGS = 20.0`, `MIN_QUALITY = 0.980`, `SSIM_ACCEPTABLE = 0.975`, `SSIM_MIN = 0.970`. When no pass clears the floor, the closest candidate is kept as `<name>_rejected.mp4` and the output names the exact `--min-ssim` flag that would accept it.
- **Originals stay safe:** Outputs write to `<name>_opt.mp4` (`<name>_25MB.mp4` for `fit.py`, `<name>.gif` for `gif.py`). `--replace` moves the original to the volume's Trash (`~/.Trash` or `.Trashes/<uid>`) only after `verify_output_integrity()` (duration, track count, `-xerror` full decode) passes, and is blocked for trims and `--video-mode copy`.
