#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
VENDOR_DIR="$REPO_ROOT/macos/Vendor"
PREFIX="$VENDOR_DIR/ffmpeg-lgpl"
WORKDIR="$VENDOR_DIR/.work-ffmpeg"

DAV1D_VER="1.5.1"
SVT_AV1_VER="3.0.2"
FFMPEG_VER="8.1"

DAV1D_URL="https://code.videolan.org/videolan/dav1d/-/archive/${DAV1D_VER}/dav1d-${DAV1D_VER}.tar.bz2"
SVT_URL="https://gitlab.com/AOMediaCodec/SVT-AV1/-/archive/v${SVT_AV1_VER}/SVT-AV1-v${SVT_AV1_VER}.tar.bz2"
FFMPEG_URL="https://ffmpeg.org/releases/ffmpeg-${FFMPEG_VER}.tar.xz"

export MACOSX_DEPLOYMENT_TARGET="14.0"
export SDKROOT="$(xcrun --show-sdk-path)"
export PATH="/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin"
export PKG_CONFIG_PATH="$PREFIX/lib/pkgconfig"
export PKG_CONFIG_LIBDIR="$PREFIX/lib/pkgconfig"

NCPU="$(sysctl -n hw.ncpu)"

rm -rf "$PREFIX" "$WORKDIR"
mkdir -p "$PREFIX/LICENSES" "$WORKDIR/src"

download() {
  local url="$1"
  local out="$2"
  echo "Downloading $url"
  curl -fL --retry 3 --retry-delay 2 -o "$out" "$url"
}

rewrite_dylibs_and_bins() {
  # Collapse versioned dylib symlinks into canonical SONAME files (e.g. libavcodec.62.dylib)
  # with matching LC_ID_DYLIB and LC_LOAD_DYLIB so macOS Hardened Runtime dyld leaf-name checks pass.
  python3 - "$PREFIX" <<'PY'
import os, re, shutil, subprocess, sys
from pathlib import Path

prefix = Path(sys.argv[1])
lib_dir = prefix / "lib"

# Determine canonical SONAME (<stem>.<major>.dylib) for each real dylib
mapping = {}
canonical_files = {}
for p in sorted(lib_dir.glob("lib*.dylib")):
    if p.is_symlink() or not p.is_file():
        continue
    m = re.match(r"^(lib[^.]+)\.(\d+)(?:\.[^.]+)*\.dylib$", p.name)
    canon = f"{m.group(1)}.{m.group(2)}.dylib" if m else p.name
    canonical_files[p] = canon
    mapping[p.name] = canon

for p in sorted(lib_dir.glob("lib*.dylib")):
    if p.is_symlink():
        real = p.resolve()
        if real in canonical_files:
            mapping[p.name] = canonical_files[real]

# Materialize real files under canonical SONAME and remove unreferenced aliases/symlinks
for real_path, canon in canonical_files.items():
    canon_path = lib_dir / canon
    if real_path != canon_path:
        if canon_path.exists() or canon_path.is_symlink():
            canon_path.unlink()
        shutil.move(str(real_path), str(canon_path))

for p in list(lib_dir.glob("lib*.dylib")):
    if p.is_symlink() or p.name not in set(canonical_files.values()):
        p.unlink()

targets = [p for p in sorted(lib_dir.glob("lib*.dylib")) if p.is_file()]
for b in ("ffmpeg", "ffprobe"):
    bp = prefix / "bin" / b
    if bp.is_file():
        targets.append(bp)

for t in targets:
    t.chmod(t.stat().st_mode | 0o755)
    if t.parent == lib_dir:
        subprocess.run(["install_name_tool", "-id", f"@rpath/{t.name}", str(t)], check=True)
    out = subprocess.check_output(["otool", "-L", str(t)], text=True)
    for line in out.splitlines()[1:]:
        dep = line.strip().split(" ", 1)[0]
        base = os.path.basename(dep)
        if dep.startswith("@rpath/") or dep.startswith("@loader_path/") or dep.startswith(str(lib_dir)) or dep.startswith("/opt/homebrew/") or dep.startswith("/usr/local/"):
            target_name = mapping.get(base, base)
            desired = f"@rpath/{target_name}"
            if dep != desired:
                subprocess.run(["install_name_tool", "-change", dep, desired, str(t)], check=True)
    lout = subprocess.check_output(["otool", "-l", str(t)], text=True)
    rpaths = re.findall(r"cmd LC_RPATH\n(?:.*\n){1,4}?\s+path ([^\s]+)", lout)
    if t.parent == lib_dir:
        for rp in rpaths:
            if rp != "@loader_path":
                subprocess.run(["install_name_tool", "-delete_rpath", rp, str(t)], check=True)
        if "@loader_path" not in rpaths:
            subprocess.run(["install_name_tool", "-add_rpath", "@loader_path", str(t)], check=True)
    else:
        for rp in rpaths:
            subprocess.run(["install_name_tool", "-delete_rpath", rp, str(t)], check=True)
        subprocess.run(["install_name_tool", "-add_rpath", "@executable_path/../Frameworks", str(t)], check=True)
        subprocess.run(["install_name_tool", "-add_rpath", "@executable_path/../lib", str(t)], check=True)
PY
}

# 1. dav1d (BSD-2-Clause)
download "$DAV1D_URL" "$WORKDIR/dav1d.tar.bz2"
tar -xjf "$WORKDIR/dav1d.tar.bz2" -C "$WORKDIR/src"
DAV1D_SRC="$WORKDIR/src/dav1d-${DAV1D_VER}"
meson setup "$WORKDIR/build-dav1d" "$DAV1D_SRC" \
  --prefix="$PREFIX" \
  --libdir=lib \
  --buildtype=release \
  -Ddefault_library=shared \
  -Denable_tools=false \
  -Denable_tests=false \
  -Denable_examples=false \
  -Dc_args="-arch arm64 -mmacosx-version-min=14.0" \
  -Dc_link_args="-arch arm64 -mmacosx-version-min=14.0"
ninja -C "$WORKDIR/build-dav1d" -j "$NCPU"
ninja -C "$WORKDIR/build-dav1d" install
cp "$DAV1D_SRC/COPYING" "$PREFIX/LICENSES/dav1d-BSD-2-Clause.txt"

# 2. SVT-AV1 (BSD-3-Clause Clear)
download "$SVT_URL" "$WORKDIR/svt-av1.tar.bz2"
tar -xjf "$WORKDIR/svt-av1.tar.bz2" -C "$WORKDIR/src"
SVT_SRC="$WORKDIR/src/SVT-AV1-v${SVT_AV1_VER}"
cmake -S "$SVT_SRC" -B "$WORKDIR/build-svt" -G Ninja \
  -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_INSTALL_PREFIX="$PREFIX" \
  -DCMAKE_INSTALL_LIBDIR=lib \
  -DCMAKE_OSX_ARCHITECTURES=arm64 \
  -DCMAKE_OSX_DEPLOYMENT_TARGET=14.0 \
  -DBUILD_SHARED_LIBS=ON \
  -DBUILD_APPS=OFF \
  -DBUILD_TESTING=OFF \
  -DBUILD_ENC=ON \
  -DBUILD_DEC=OFF \
  -DENABLE_AVX512=OFF \
  -DCMAKE_INSTALL_NAME_DIR="@rpath"
cmake --build "$WORKDIR/build-svt" -j "$NCPU"
cmake --install "$WORKDIR/build-svt"
cp "$SVT_SRC/LICENSE.md" "$PREFIX/LICENSES/SVT-AV1-BSD-3-Clause-Clear.txt"
if [[ -f "$SVT_SRC/PATENTS.md" ]]; then
  cat "$SVT_SRC/PATENTS.md" >> "$PREFIX/LICENSES/SVT-AV1-BSD-3-Clause-Clear.txt"
fi

# Ensure @rpath IDs exist before FFmpeg links against dav1d / SVT-AV1
rewrite_dylibs_and_bins

# 3. FFmpeg (Strictly LGPL v2.1+)
download "$FFMPEG_URL" "$WORKDIR/ffmpeg.tar.xz"
tar -xJf "$WORKDIR/ffmpeg.tar.xz" -C "$WORKDIR/src"
FFMPEG_SRC="$WORKDIR/src/ffmpeg-${FFMPEG_VER}"
mkdir -p "$WORKDIR/build-ffmpeg"
(
  cd "$WORKDIR/build-ffmpeg"
  "$FFMPEG_SRC/configure" \
    --prefix="$PREFIX" \
    --enable-shared \
    --disable-static \
    --disable-gpl \
    --disable-nonfree \
    --disable-doc \
    --disable-htmlpages \
    --disable-manpages \
    --disable-podpages \
    --disable-txtpages \
    --disable-debug \
    --disable-autodetect \
    --enable-videotoolbox \
    --enable-audiotoolbox \
    --enable-opencl \
    --enable-zlib \
    --enable-bzlib \
    --enable-iconv \
    --enable-libdav1d \
    --enable-libsvtav1 \
    --arch=arm64 \
    --cc=clang \
    --extra-cflags="-arch arm64 -mmacosx-version-min=14.0 -I${PREFIX}/include" \
    --extra-ldflags="-arch arm64 -mmacosx-version-min=14.0 -L${PREFIX}/lib -Wl,-rpath,@executable_path/../Frameworks -Wl,-rpath,@loader_path" \
    --extra-libs="-liconv"
  make -j "$NCPU"
  make install
)
cp "$FFMPEG_SRC/COPYING.LGPLv2.1" "$PREFIX/LICENSES/FFmpeg-LGPL-v2.1.txt"

rewrite_dylibs_and_bins

# Verification
BUILDCONF="$("$PREFIX/bin/ffmpeg" -buildconf 2>&1)"
printf '%s\n' "$BUILDCONF" | sed -E \
  -e "s|${PREFIX}|<BUILD_PREFIX>|g" \
  -e "s|${REPO_ROOT}|<REPO_ROOT>|g" \
  -e "s|/Users/[^/'\":[:space:]]*|/Users/<builder>|g" \
  > "$PREFIX/LICENSES/FFMPEG-BUILDCONF.txt"

if echo "$BUILDCONF" | grep -qE -- "--enable-gpl|--enable-nonfree|--enable-version3"; then
  echo "ERROR: Forbidden GPL/nonfree/version3 flag detected in ffmpeg -buildconf!" >&2
  exit 1
fi

ENCODERS="$("$PREFIX/bin/ffmpeg" -hide_banner -encoders)"
for enc in hevc_videotoolbox h264_videotoolbox aac_at libsvtav1; do
  if ! echo "$ENCODERS" | grep -qE "\b${enc}\b"; then
    echo "ERROR: Missing required encoder: $enc" >&2
    exit 1
  fi
done

DECODERS="$("$PREFIX/bin/ffmpeg" -hide_banner -decoders)"
for dec in libdav1d hevc h264; do
  if ! echo "$DECODERS" | grep -qE "\b${dec}\b"; then
    echo "ERROR: Missing required decoder: $dec" >&2
    exit 1
  fi
done

FILTERS="$("$PREFIX/bin/ffmpeg" -hide_banner -filters)"
for flt in ssim loudnorm palettegen paletteuse tonemap_opencl crop scale fps; do
  if ! echo "$FILTERS" | grep -qE "\b${flt}\b"; then
    echo "ERROR: Missing required filter: $flt" >&2
    exit 1
  fi
done
if echo "$FILTERS" | grep -qE "\bcropdetect\b"; then
  echo "ERROR: GPL filter cropdetect should not be present!" >&2
  exit 1
fi

echo "Verifying Mach-O dependencies and macOS minos <= 14.0..."
for macho in "$PREFIX/bin/ffmpeg" "$PREFIX/bin/ffprobe" "$PREFIX/lib"/lib*.dylib; do
  [[ -f "$macho" && ! -L "$macho" ]] || continue
  if otool -L "$macho" | tail -n +2 | grep -qE "(/opt/homebrew|/usr/local|${PREFIX})"; then
    echo "ERROR: Forbidden absolute dependency in $macho:" >&2
    otool -L "$macho" >&2
    exit 1
  fi
  minos="$(otool -l "$macho" | awk '/cmd LC_BUILD_VERSION/{f=1} f && /minos /{print $2; exit}')"
  if [[ -n "$minos" ]]; then
    major="${minos%%.*}"
    if (( major > 14 )); then
      echo "ERROR: $macho has minos $minos > 14.0" >&2
      exit 1
    fi
  fi
done

rm -rf "$WORKDIR"
echo "✅ Strictly LGPL FFmpeg + SVT-AV1 + dav1d built cleanly at $PREFIX"
