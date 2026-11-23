#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
XCODE_DIR="$REPO_ROOT/macos/VideoCrunch"
BUILD_ROOT="$REPO_ROOT/macos/build/mas-release"
ARCHIVE_PATH="$BUILD_ROOT/VideoCrunch.xcarchive"
EXPORT_DIR="$BUILD_ROOT/export"
EXPORT_PLIST="$BUILD_ROOT/ExportOptions-MAS.plist"
OUT_PKG="$BUILD_ROOT/VideoCrunch-MAS.pkg"

if [[ ! -x "$REPO_ROOT/macos/Vendor/ffmpeg-lgpl/bin/ffmpeg" ]]; then
  echo "ERROR: Missing LGPL FFmpeg vendor build. Run macos/scripts/build_lgpl_ffmpeg.sh first." >&2
  exit 1
fi
if [[ ! -x "$REPO_ROOT/macos/Vendor/python-standalone/bin/python3" ]]; then
  echo "ERROR: Missing standalone Python runtime. Run macos/scripts/prepare_mas_runtime.sh first." >&2
  exit 1
fi

TEAM_ID="${MAS_TEAM_ID:-$(awk -F': *' '/DEVELOPMENT_TEAM:/ {print $2; exit}' "$XCODE_DIR/project.yml" | tr -d '[:space:]')}"
if [[ -z "$TEAM_ID" ]]; then
  echo "ERROR: Could not determine DEVELOPMENT_TEAM from project.yml. Set MAS_TEAM_ID explicitly." >&2
  exit 1
fi

APP_SIGN_ID="${MAS_APP_IDENTITY:-$(security find-identity -v -p codesigning 2>/dev/null | sed -n 's/.*"\(Apple Distribution: [^"]*\)".*/\1/p' | head -n 1)}"
if [[ -z "$APP_SIGN_ID" ]]; then
  echo "ERROR: Missing 'Apple Distribution' certificate in keychain. Create one in Xcode -> Settings -> Accounts." >&2
  exit 1
fi

INSTALLER_SIGN_ID="${MAS_INSTALLER_IDENTITY:-$(security find-identity -v 2>/dev/null | sed -nE 's/.*"(3rd Party Mac Developer Installer: [^"]*|Mac Installer Distribution: [^"]*)".*/\1/p' | head -n 1)}"
if [[ -z "$INSTALLER_SIGN_ID" ]]; then
  echo "ERROR: Missing 'Mac Installer Distribution' / '3rd Party Mac Developer Installer' certificate in keychain." >&2
  exit 1
fi

echo "Team ID          : $TEAM_ID"
echo "App Identity     : $APP_SIGN_ID"
echo "Installer Identity: $INSTALLER_SIGN_ID"

rm -rf "$BUILD_ROOT"
mkdir -p "$BUILD_ROOT" "$EXPORT_DIR"

echo "1/6 Generating Xcode project..."
(cd "$XCODE_DIR" && xcodegen generate)

echo "2/6 Creating Release xcarchive..."
xcodebuild archive \
  -project "$XCODE_DIR/VideoCrunch.xcodeproj" \
  -scheme VideoCrunch \
  -configuration Release \
  -destination "generic/platform=macOS" \
  ARCHS=arm64 \
  -archivePath "$ARCHIVE_PATH" \
  -allowProvisioningUpdates \
  MAS_SKIP_POSTBUILD_EMBED=1

ARCHIVE_APP="$ARCHIVE_PATH/Products/Applications/VideoCrunch.app"
if [[ ! -d "$ARCHIVE_APP" ]]; then
  echo "ERROR: Expected archived app at $ARCHIVE_APP" >&2
  exit 1
fi

echo "3/6 Embedding Python, Engine, LGPL FFmpeg & signing inside-out with Apple Distribution (--timestamp)..."
MAS_SIGN_IDENTITY="$APP_SIGN_ID" \
  MAS_CODESIGN_TIMESTAMP=1 \
  SKIP_OUTER_RESIGN=0 \
  bash "$SCRIPT_DIR/embed_mas_payload.sh" "$ARCHIVE_APP"

cat > "$EXPORT_PLIST" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>method</key>
    <string>app-store-connect</string>
    <key>destination</key>
    <string>export</string>
    <key>signingStyle</key>
    <string>automatic</string>
    <key>teamID</key>
    <string>${TEAM_ID}</string>
</dict>
</plist>
PLIST

echo "4/6 Exporting signed Mac App Store package via xcodebuild -exportArchive..."
xcodebuild -exportArchive \
  -archivePath "$ARCHIVE_PATH" \
  -exportOptionsPlist "$EXPORT_PLIST" \
  -exportPath "$EXPORT_DIR" \
  -allowProvisioningUpdates

EXPORTED_PKG="$(find "$EXPORT_DIR" -maxdepth 1 -name "*.pkg" | head -n 1)"
if [[ -z "$EXPORTED_PKG" || ! -f "$EXPORTED_PKG" ]]; then
  echo "ERROR: xcodebuild -exportArchive produced no .pkg in $EXPORT_DIR" >&2
  exit 1
fi

echo "5/6 Verifying exported .pkg payload signatures, entitlements, and provisioning profile..."
VERIFY_DIR="$BUILD_ROOT/verify-pkg"
rm -rf "$VERIFY_DIR"
pkgutil --expand-full "$EXPORTED_PKG" "$VERIFY_DIR"

PKG_APP="$(find "$VERIFY_DIR" -name "VideoCrunch.app" -type d | head -n 1)"
if [[ -z "$PKG_APP" || ! -d "$PKG_APP" ]]; then
  echo "ERROR: Could not locate VideoCrunch.app inside $EXPORTED_PKG" >&2
  exit 1
fi

if [[ ! -f "$PKG_APP/Contents/embedded.provisionprofile" ]]; then
  echo "ERROR: Missing Contents/embedded.provisionprofile inside exported app." >&2
  exit 1
fi

# xcodebuild -exportArchive sometimes strips custom helper entitlements or re-signs helpers incorrectly.
# Verify Helpers carry com.apple.security.inherit; if not, re-sign the exported .app inside-out (keeping
# Xcode's embedded.provisionprofile!) and re-build the signed .pkg cleanly via productbuild.
NEEDS_REPACK=0
for helper in ffmpeg ffprobe python3; do
  HP="$PKG_APP/Contents/Helpers/$helper"
  if [[ ! -f "$HP" ]]; then
    echo "ERROR: Missing bundled helper $HP" >&2
    exit 1
  fi
  ENT_OUT="$(codesign -d --entitlements :- "$HP" 2>/dev/null || true)"
  if ! grep -q "com.apple.security.inherit" <<< "$ENT_OUT"; then
    echo "NOTE: Helper $helper lacks com.apple.security.inherit after -exportArchive — repairing signatures inside-out."
    NEEDS_REPACK=1
    break
  fi
  SIG_OUT="$(codesign -dvvv "$HP" 2>&1 || true)"
  if ! grep -q "Authority=Apple Distribution:" <<< "$SIG_OUT" || grep -q "Timestamp=none" <<< "$SIG_OUT"; then
    echo "NOTE: Helper $helper signature needs Apple Distribution + secure timestamp — repairing."
    NEEDS_REPACK=1
    break
  fi
done

if [[ "$NEEDS_REPACK" -eq 1 ]]; then
  echo "Re-signing exported bundle inside-out while preserving embedded.provisionprofile..."
  find "$PKG_APP/Contents/Frameworks" -maxdepth 1 -type f -name "*.dylib" -print0 | while IFS= read -r -d '' dylib; do
    chmod u+w "$dylib" || true
    codesign --force --options runtime --timestamp --sign "$APP_SIGN_ID" "$dylib"
  done
  for helper in ffmpeg ffprobe python3; do
    HP="$PKG_APP/Contents/Helpers/$helper"
    chmod u+w "$HP" || true
    codesign --force --options runtime --timestamp --entitlements "$XCODE_DIR/VideoCrunchHelper.entitlements" --sign "$APP_SIGN_ID" "$HP"
  done
  codesign --force --options runtime --timestamp --entitlements "$XCODE_DIR/VideoCrunch.entitlements" --sign "$APP_SIGN_ID" "$PKG_APP"
  xcrun productbuild \
    --component "$PKG_APP" /Applications \
    --sign "$INSTALLER_SIGN_ID" \
    "$OUT_PKG"
else
  cp "$EXPORTED_PKG" "$OUT_PKG"
fi

# Keep xcarchive aligned with the MAS-provisioned bundle so Xcode Organizer also has the valid copy
cp "$PKG_APP/Contents/embedded.provisionprofile" "$ARCHIVE_APP/Contents/embedded.provisionprofile"
MAS_SIGN_IDENTITY="$APP_SIGN_ID" MAS_CODESIGN_TIMESTAMP=1 SKIP_OUTER_RESIGN=0 \
  bash "$SCRIPT_DIR/embed_mas_payload.sh" "$ARCHIVE_APP" >/dev/null

echo "6/6 Final strict verification of MAS package..."
pkgutil --check-signature "$OUT_PKG"
VERIFY_FINAL="$BUILD_ROOT/verify-final"
rm -rf "$VERIFY_FINAL"
pkgutil --expand-full "$OUT_PKG" "$VERIFY_FINAL"
FINAL_APP="$(find "$VERIFY_FINAL" -name "VideoCrunch.app" -type d | head -n 1)"
codesign --verify --deep --strict --verbose=2 "$FINAL_APP"
for helper in ffmpeg ffprobe python3; do
  codesign -d --entitlements :- "$FINAL_APP/Contents/Helpers/$helper" 2>/dev/null | grep -q "com.apple.security.inherit"
done
test -f "$FINAL_APP/Contents/embedded.provisionprofile"
rm -rf "$VERIFY_DIR" "$VERIFY_FINAL"

echo ""
echo "✅ Ready for App Store Connect!"
echo "   Archive : $ARCHIVE_PATH"
echo "   Package : $OUT_PKG"
echo ""
echo "Next:"
echo "  - Option 1 (GUI): Open Transporter.app (or Xcode Organizer on $ARCHIVE_PATH) and deliver $OUT_PKG"
echo "  - Option 2 (CLI): xcrun altool --validate-app -f \"$OUT_PKG\" -t macos --apiKey <KEY_ID> --apiIssuer <ISSUER_ID>"
