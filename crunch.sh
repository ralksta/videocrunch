#!/bin/bash
# videocrunch — folder scan and encode wizard.
#
#   bash crunch.sh ~/Videos              scan the folder, mark what to encode
#   bash crunch.sh ~/Videos/clip.mp4     encode a single file
#   bash crunch.sh ~/Videos --audio-mode standard
set -u

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
TARGET="${1:-}"
shift || true

G='\033[0;32m'; BG='\033[1;32m'; Y='\033[0;33m'; R='\033[0;31m'; NC='\033[0m'

if [[ -z "$TARGET" ]]; then
    echo -e "${Y}Usage: bash crunch.sh <Ordner|Datei> [Optionen]${NC}"
    exit 1
fi

PYTHON="$SCRIPT_DIR/.venv/bin/python3"
[[ -x "$PYTHON" ]] || PYTHON="python3"

if ! command -v ffprobe >/dev/null 2>&1; then
    echo -e "${R}ffprobe nicht gefunden. Bitte ffmpeg installieren (brew install ffmpeg).${NC}"
    exit 1
fi

echo -e "${BG}═══════════════════════════════════════════${NC}"
echo -e "${BG}  🎬 videocrunch${NC}"
echo -e "${BG}═══════════════════════════════════════════${NC}"

if [[ -d "$TARGET" ]]; then
    exec "$PYTHON" "$SCRIPT_DIR/scan.py" "$TARGET" "$@"
elif [[ -f "$TARGET" ]]; then
    exec "$PYTHON" "$SCRIPT_DIR/videocrunch.py" "$TARGET" "$@"
else
    echo -e "${R}Nicht gefunden: $TARGET${NC}"
    exit 1
fi
