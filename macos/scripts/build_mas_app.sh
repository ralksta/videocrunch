#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
XCODE_DIR="$REPO_ROOT/macos/VideoCrunch"
BUILD_ROOT="$REPO_ROOT/macos/build"
STAGE_DIR="$BUILD_ROOT/stage-mas"
OUT_APP="$BUILD_ROOT/VideoCrunch-MAS.app"

if [[ -n "${MAS_SIGN_IDENTITY:-}" ]]; then
  SIGN_ID="$MAS_SIGN_IDENTITY"
else
  SIGN_ID="$(security find-identity -v -p codesigning 2>/dev/null \
    | sed -n 's/.*"\(Apple Development: [^"]*\)".*/\1/p' \
    | head -n 1)"
  if [[ -z "$SIGN_ID" ]]; then
    echo "ERROR: No 'Apple Development' signing identity found in keychain. Set MAS_SIGN_IDENTITY explicitly." >&2
    exit 1
  fi
fi

if [[ ! -x "$REPO_ROOT/macos/Vendor/ffmpeg-lgpl/bin/ffmpeg" ]]; then
  echo "ERROR: Missing LGPL FFmpeg vendor build. Run macos/scripts/build_lgpl_ffmpeg.sh first." >&2
  exit 1
fi
if [[ ! -x "$REPO_ROOT/macos/Vendor/python-standalone/bin/python3" ]]; then
  echo "ERROR: Missing standalone Python runtime. Run macos/scripts/prepare_mas_runtime.sh first." >&2
  exit 1
fi

echo "1/4 Generating Xcode project..."
(cd "$XCODE_DIR" && xcodegen generate)

rm -rf "$STAGE_DIR" "$OUT_APP"
mkdir -p "$STAGE_DIR"

echo "2/4 Building Release arm64 app with xcodebuild..."
xcodebuild \
  -project "$XCODE_DIR/VideoCrunch.xcodeproj" \
  -scheme VideoCrunch \
  -configuration Release \
  -arch arm64 \
  CODE_SIGNING_ALLOWED=NO \
  MAS_SKIP_POSTBUILD_EMBED=1 \
  CONFIGURATION_BUILD_DIR="$STAGE_DIR" \
  build

cp -R "$STAGE_DIR/VideoCrunch.app" "$OUT_APP"

echo "3/4 Embedding Engine, LGPL FFmpeg, Python runtime, Licenses & signing inside-out..."
MAS_SIGN_IDENTITY="$SIGN_ID" SKIP_OUTER_RESIGN=0 \
  bash "$SCRIPT_DIR/embed_mas_payload.sh" "$OUT_APP"

echo "4/4 Strict deep signature verification..."
codesign --verify --deep --strict --verbose=2 "$OUT_APP"

echo "✅ Self-contained sandboxed MAS app ready: $OUT_APP"
