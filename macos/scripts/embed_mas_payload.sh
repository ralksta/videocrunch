#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
MACOS_DIR="$REPO_ROOT/macos/VideoCrunch"
VENDOR_DIR="$REPO_ROOT/macos/Vendor"

APP_PATH="${1:-}"
if [[ -z "$APP_PATH" && -n "${TARGET_BUILD_DIR:-}" && -n "${WRAPPER_NAME:-}" ]]; then
  APP_PATH="${TARGET_BUILD_DIR}/${WRAPPER_NAME}"
fi
if [[ -z "$APP_PATH" || ! -d "$APP_PATH" ]]; then
  echo "Usage: $0 <path/to/VideoCrunch.app>" >&2
  exit 1
fi

CONTENTS="$APP_PATH/Contents"
RESOURCES="$CONTENTS/Resources"
ENGINE_DIR="$RESOURCES/Engine"
HELPERS_DIR="$CONTENTS/Helpers"
FRAMEWORKS_DIR="$CONTENTS/Frameworks"
LICENSES_DIR="$RESOURCES/LICENSES"

rm -rf "$LICENSES_DIR"
mkdir -p "$ENGINE_DIR" "$LICENSES_DIR"

ENGINE_SCRIPTS=(
  batch.py
  bitrate.py
  concat.py
  crunch_utils.py
  encoders.py
  fit.py
  gif.py
  inspect_media.py
  savings.py
  scan.py
  videocrunch.py
)

for script in "${ENGINE_SCRIPTS[@]}"; do
  cp "$REPO_ROOT/$script" "$ENGINE_DIR/$script"
done
find "$ENGINE_DIR" -name "__pycache__" -type d -prune -exec rm -rf {} +

# Always embed VideoCrunch's own MIT license and build combined NOTICES.txt
cp "$REPO_ROOT/LICENSE" "$LICENSES_DIR/VideoCrunch-MIT.txt"

FFMPEG_VENDOR="$VENDOR_DIR/ffmpeg-lgpl"
PYTHON_VENDOR="$VENDOR_DIR/python-standalone"

if [[ -x "$FFMPEG_VENDOR/bin/ffmpeg" && -x "$FFMPEG_VENDOR/bin/ffprobe" ]]; then
  mkdir -p "$HELPERS_DIR" "$FRAMEWORKS_DIR"
  cp "$FFMPEG_VENDOR/bin/ffmpeg" "$HELPERS_DIR/ffmpeg"
  cp "$FFMPEG_VENDOR/bin/ffprobe" "$HELPERS_DIR/ffprobe"
  chmod +x "$HELPERS_DIR/ffmpeg" "$HELPERS_DIR/ffprobe"

  rm -f "$FRAMEWORKS_DIR"/lib*.dylib
  cp -R "$FFMPEG_VENDOR/lib"/lib*.dylib "$FRAMEWORKS_DIR/"

  if [[ -d "$FFMPEG_VENDOR/LICENSES" ]]; then
    cp -R "$FFMPEG_VENDOR/LICENSES/"* "$LICENSES_DIR/"
    if [[ -f "$LICENSES_DIR/FFMPEG-BUILDCONF.txt" ]]; then
      sed -E \
        -e "s|${FFMPEG_VENDOR}|<BUILD_PREFIX>|g" \
        -e "s|${REPO_ROOT}|<REPO_ROOT>|g" \
        -e "s|/Users/[^/'\":[:space:]]*|/Users/<builder>|g" \
        "$LICENSES_DIR/FFMPEG-BUILDCONF.txt" > "$LICENSES_DIR/FFMPEG-BUILDCONF.txt.tmp"
      mv "$LICENSES_DIR/FFMPEG-BUILDCONF.txt.tmp" "$LICENSES_DIR/FFMPEG-BUILDCONF.txt"
    fi
  fi
fi

PY_BIN_SRC="$PYTHON_VENDOR/bin/python3.13"
if [[ ! -x "$PY_BIN_SRC" ]]; then
  PY_BIN_SRC="$PYTHON_VENDOR/bin/python3"
fi
if [[ -x "$PY_BIN_SRC" ]]; then
  mkdir -p "$HELPERS_DIR" "$RESOURCES/Python/lib"
  rm -rf "$HELPERS_DIR/python" "$RESOURCES/Python"
  mkdir -p "$RESOURCES/Python/lib"
  cp "$PY_BIN_SRC" "$HELPERS_DIR/python3"
  chmod +x "$HELPERS_DIR/python3"

  cp -R "$PYTHON_VENDOR/lib/python3.13" "$RESOURCES/Python/lib/"
  find "$RESOURCES/Python" -name "__pycache__" -type d -prune -exec rm -rf {} +
  find "$RESOURCES/Python" -type f \( -name "*.so" -o -name "*.dylib" -o -name "*.a" \) -delete
  rm -f "$RESOURCES/Python/lib/python3.13/LICENSE.txt"

  if [[ -f "$PYTHON_VENDOR/LICENSE.txt" ]]; then
    cp "$PYTHON_VENDOR/LICENSE.txt" "$LICENSES_DIR/Python-PSF-LICENSE.txt"
  fi
  if [[ -f "$REPO_ROOT/macos/legal/Python-ThirdParty-NOTICES.txt" ]]; then
    cp "$REPO_ROOT/macos/legal/Python-ThirdParty-NOTICES.txt" "$LICENSES_DIR/Python-ThirdParty-NOTICES.txt"
  fi
fi

read_sh_var() {
  local file="$1" key="$2" default="${3:-}" val=""
  if [[ -f "$file" ]]; then
    val="$(awk -v k="$key" 'index($0, k "=") == 1 { v = substr($0, length(k) + 2); gsub(/^"|"$/, "", v); print v; exit }' "$file")"
  fi
  printf '%s' "${val:-$default}"
}

FFMPEG_SCRIPT="$SCRIPT_DIR/build_lgpl_ffmpeg.sh"
PYTHON_SCRIPT="$SCRIPT_DIR/prepare_mas_runtime.sh"

DAV1D_VER="$(read_sh_var "$FFMPEG_SCRIPT" DAV1D_VER "1.5.1")"
SVT_AV1_VER="$(read_sh_var "$FFMPEG_SCRIPT" SVT_AV1_VER "3.0.2")"
FFMPEG_VER="$(read_sh_var "$FFMPEG_SCRIPT" FFMPEG_VER "8.1")"
DAV1D_URL="$(read_sh_var "$FFMPEG_SCRIPT" DAV1D_URL "https://code.videolan.org/videolan/dav1d/-/archive/${DAV1D_VER}/dav1d-${DAV1D_VER}.tar.bz2")"
SVT_URL="$(read_sh_var "$FFMPEG_SCRIPT" SVT_URL "https://gitlab.com/AOMediaCodec/SVT-AV1/-/archive/v${SVT_AV1_VER}/SVT-AV1-v${SVT_AV1_VER}.tar.bz2")"
FFMPEG_URL="$(read_sh_var "$FFMPEG_SCRIPT" FFMPEG_URL "https://ffmpeg.org/releases/ffmpeg-${FFMPEG_VER}.tar.xz")"
PY_VER="$(read_sh_var "$PYTHON_SCRIPT" PY_VER "3.13.18+20261110")"

expand_sh_vars() {
  local s="$1"
  s="${s//\$\{DAV1D_VER\}/$DAV1D_VER}"
  s="${s//\$DAV1D_VER/$DAV1D_VER}"
  s="${s//\$\{SVT_AV1_VER\}/$SVT_AV1_VER}"
  s="${s//\$SVT_AV1_VER/$SVT_AV1_VER}"
  s="${s//\$\{FFMPEG_VER\}/$FFMPEG_VER}"
  s="${s//\$FFMPEG_VER/$FFMPEG_VER}"
  printf '%s' "$s"
}

DAV1D_URL="$(expand_sh_vars "$DAV1D_URL")"
SVT_URL="$(expand_sh_vars "$SVT_URL")"
FFMPEG_URL="$(expand_sh_vars "$FFMPEG_URL")"
PY_RELEASE_TAG="${PY_VER#*+}"

append_notice_file() {
  local section_label="$1" filename="$2"
  local path="$LICENSES_DIR/$filename"
  if [[ -f "$path" ]]; then
    echo ""
    echo "========================================================================"
    echo "$section_label ($filename)"
    echo "========================================================================"
    cat "$path"
  fi
}

{
  echo "VideoCrunch Open-Source Software Notices"
  echo "========================================"
  echo ""
  echo "FFmpeg LGPL v2.1+ Credit & Source Code Offer"
  echo "--------------------------------------------"
  echo "This software uses libraries from the FFmpeg project under the LGPLv2.1."
  echo ""
  echo "VideoCrunch claims no ownership over FFmpeg, SVT-AV1, dav1d, Python, or"
  echo "any third-party libraries bundled inside this application. FFmpeg is built"
  echo "with '--enable-shared --disable-static --disable-gpl --disable-nonfree'"
  echo "and dynamically linked against separate shared libraries (.dylib) stored"
  echo "in VideoCrunch.app/Contents/Frameworks/."
  echo ""
  echo "Unmodified upstream source archives are used for all bundled media and"
  echo "runtime libraries:"
  echo "  - FFmpeg ${FFMPEG_VER} (LGPL v2.1+):"
  echo "      ${FFMPEG_URL}"
  echo "  - SVT-AV1 v${SVT_AV1_VER} (BSD-3-Clause Clear + AOM Patent License 1.0):"
  echo "      ${SVT_URL}"
  echo "  - dav1d ${DAV1D_VER} (BSD-2-Clause):"
  echo "      ${DAV1D_URL}"
  echo "  - Python Runtime ${PY_VER} (PSF-2.0 + permissive C dependencies):"
  echo "      https://github.com/astral-sh/python-build-standalone/releases/tag/${PY_RELEASE_TAG}"
  echo ""
  echo "VideoCrunch source code, exact build script, and mirrored upstream source"
  echo "tarballs:"
  echo "  - Repository:   https://github.com/ralksta/videocrunch"
  echo "  - Build Script: https://github.com/ralksta/videocrunch/blob/main/macos/scripts/build_lgpl_ffmpeg.sh"
  echo "  - Release Assets (upstream source mirror): https://github.com/ralksta/videocrunch/releases"
  echo ""
  echo "In accordance with LGPL v2.1 Section 6, nothing restricts you from"
  echo "modifying the LGPL-licensed FFmpeg libraries for your own use or"
  echo "performing reverse engineering solely to debug such modifications."
  echo ""
  echo "========================================================================"
  echo "1. VideoCrunch — MIT License (VideoCrunch-MIT.txt)"
  echo "========================================================================"
  cat "$REPO_ROOT/LICENSE"
  if [[ -f "$LICENSES_DIR/FFMPEG-BUILDCONF.txt" ]]; then
    echo ""
    echo "========================================================================"
    echo "2. FFmpeg — Build Configuration (LGPL v2.1+, FFMPEG-BUILDCONF.txt)"
    echo "========================================================================"
    cat "$LICENSES_DIR/FFMPEG-BUILDCONF.txt"
  fi
  append_notice_file "3. FFmpeg — GNU Lesser General Public License v2.1" "FFmpeg-LGPL-v2.1.txt"
  append_notice_file "4. SVT-AV1 — BSD-3-Clause Clear & Patent License" "SVT-AV1-BSD-3-Clause-Clear.txt"
  append_notice_file "5. dav1d — BSD-2-Clause License" "dav1d-BSD-2-Clause.txt"
  append_notice_file "6. CPython — Python Software Foundation License v2" "Python-PSF-LICENSE.txt"
  append_notice_file "7. Python Standalone — Third-Party C Library Notices" "Python-ThirdParty-NOTICES.txt"
  for f in "$LICENSES_DIR"/*.txt; do
    [[ -f "$f" ]] || continue
    base="$(basename "$f")"
    case "$base" in
      NOTICES.txt|VideoCrunch-MIT.txt|FFMPEG-BUILDCONF.txt|\
      FFmpeg-LGPL-v2.1.txt|SVT-AV1-BSD-3-Clause-Clear.txt|\
      dav1d-BSD-2-Clause.txt|Python-PSF-LICENSE.txt|\
      Python-ThirdParty-NOTICES.txt)
        continue
        ;;
    esac
    echo ""
    echo "--- $base ---"
    cat "$f"
  done
} > "$LICENSES_DIR/NOTICES.txt"

chmod 0644 "$LICENSES_DIR"/*.txt

# Inside-out code signing when requested or running inside Xcode archive build phase
SIGN_ID="${MAS_SIGN_IDENTITY:-${EXPANDED_CODE_SIGN_IDENTITY:-}}"
if [[ -n "$SIGN_ID" && "$SIGN_ID" != "-" ]]; then
  TIMESTAMP_FLAG="--timestamp=none"
  if [[ "$SIGN_ID" == "Apple Distribution:"* || "$SIGN_ID" == "Developer ID "* || "${MAS_CODESIGN_TIMESTAMP:-0}" == "1" ]]; then
    TIMESTAMP_FLAG="--timestamp"
  fi
  echo "Signing embedded MAS payload with identity: $SIGN_ID ($TIMESTAMP_FLAG)"
  HELPER_ENT="${MACOS_DIR}/VideoCrunchHelper.entitlements"
  APP_ENT="${MACOS_DIR}/VideoCrunch.entitlements"

  if [[ -d "$FRAMEWORKS_DIR" ]]; then
    while IFS= read -r -d '' dylib; do
      chmod u+w "$dylib" || true
      codesign --force --options runtime "$TIMESTAMP_FLAG" --sign "$SIGN_ID" "$dylib"
    done < <(find "$FRAMEWORKS_DIR" -maxdepth 1 -type f -name "*.dylib" -print0)
  fi

  for tool in ffmpeg ffprobe python3; do
    if [[ -f "$HELPERS_DIR/$tool" ]]; then
      chmod u+w "$HELPERS_DIR/$tool" || true
      codesign --force --options runtime "$TIMESTAMP_FLAG" --entitlements "$HELPER_ENT" --sign "$SIGN_ID" "$HELPERS_DIR/$tool"
    fi
  done

  if [[ "${SKIP_OUTER_RESIGN:-0}" != "1" ]]; then
    codesign --force --options runtime "$TIMESTAMP_FLAG" --entitlements "$APP_ENT" --sign "$SIGN_ID" "$APP_PATH"
  fi
fi

echo "Embedded MAS payload into: $APP_PATH"
