#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
VENDOR_DIR="$REPO_ROOT/macos/Vendor"
DEST="$VENDOR_DIR/python-standalone"
WORKDIR="$VENDOR_DIR/.work-python"

PY_VER="3.13.18+20261110"
PY_TAR_URL="https://github.com/astral-sh/python-build-standalone/releases/download/20261110/cpython-3.13.18%2B20261110-aarch64-apple-darwin-install_only_stripped.tar.gz"

rm -rf "$DEST" "$WORKDIR"
mkdir -p "$DEST" "$WORKDIR"

echo "Downloading python-build-standalone (${PY_VER})..."
curl -fL --retry 3 --retry-delay 2 -o "$WORKDIR/python.tar.gz" "$PY_TAR_URL"
tar -xzf "$WORKDIR/python.tar.gz" -C "$WORKDIR"

if [[ -d "$WORKDIR/python" ]]; then
  cp -R "$WORKDIR/python/"* "$DEST/"
else
  echo "ERROR: Unexpected archive structure from python-build-standalone" >&2
  exit 1
fi

# Strip unnecessary stdlib test suites, GUI toolkits, static archives, headers, and bytecode
rm -rf \
  "$DEST/include" \
  "$DEST/share" \
  "$DEST/lib/tcl"* \
  "$DEST/lib/tk"* \
  "$DEST/lib/libtcl"* \
  "$DEST/lib/itcl"* \
  "$DEST/lib/thread"* \
  "$DEST/lib/pkgconfig" \
  "$DEST/lib/python3.13/test" \
  "$DEST/lib/python3.13/idlelib" \
  "$DEST/lib/python3.13/tkinter" \
  "$DEST/lib/python3.13/turtledemo" \
  "$DEST/lib/python3.13/ensurepip" \
  "$DEST/lib/python3.13/turtle.py" \
  "$DEST/lib/python3.13/config-"*

find "$DEST" -name "_tkinter*.so" -delete
find "$DEST" -name "*.a" -delete
find "$DEST/lib" -maxdepth 1 -name "libpython*.dylib" -delete
find "$DEST/lib/python3.13/lib-dynload" -name "*.so" -delete
find "$DEST" -name "__pycache__" -type d -prune -exec rm -rf {} +

# Keep only python3 and the versioned python3.13 executable inside bin/
for f in "$DEST/bin/"*; do
  base="$(basename "$f")"
  case "$base" in
    python3|python3.13) ;;
    *) rm -rf "$f" ;;
  esac
done

# Ensure PSF License notice file is present
if [[ -f "$DEST/lib/python3.13/LICENSE.txt" ]]; then
  cp "$DEST/lib/python3.13/LICENSE.txt" "$DEST/LICENSE.txt"
elif [[ ! -f "$DEST/LICENSE.txt" ]]; then
  cat > "$DEST/LICENSE.txt" <<'EOF'
Python Software Foundation License Version 2
Copyright (c) 2001-2026 Python Software Foundation; All Rights Reserved.
Derived from astral-sh/python-build-standalone cpython-3.13.18 (aarch64-apple-darwin).
EOF
fi

echo "Auditing Mach-O binaries & dylibs in $DEST..."
while IFS= read -r -d '' file; do
  if file -b "$file" | grep -q "Mach-O"; then
    if otool -L "$file" | grep -qE "(/opt/homebrew|/usr/local)"; then
      echo "ERROR: Homebrew/local library dependency in $file:" >&2
      otool -L "$file" >&2
      exit 1
    fi
    minos="$(otool -l "$file" | awk '/cmd LC_BUILD_VERSION/{f=1} f && /minos /{print $2; exit}')"
    if [[ -n "$minos" ]]; then
      major="${minos%%.*}"
      if (( major > 14 )); then
        echo "ERROR: $file has minos $minos > 14.0" >&2
        exit 1
      fi
    fi
  fi
done < <(find "$DEST" -type f \( -name "*.dylib" -o -name "*.so" -o -path "$DEST/bin/*" \) -print0)

# Smoke test bundled Python interpreter
PYTHONHOME="$DEST" PYTHONDONTWRITEBYTECODE=1 "$DEST/bin/python3" --version

rm -rf "$WORKDIR"
echo "✅ Standalone Python runtime ready at $DEST"
