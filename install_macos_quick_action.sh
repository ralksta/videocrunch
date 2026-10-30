#!/bin/bash
# Builds VideoCrunch.app, installs it into /Applications (or ~/Applications)
# and the Finder Quick Action into ~/Library/Services/.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
MACOS_DIR="$SCRIPT_DIR/macos/VideoCrunch"
APP_BUNDLE="$MACOS_DIR/VideoCrunch.app"
LSREGISTER=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister

# Bundle identifier. VIDEOCRUNCH_BUNDLE_ID gives a test build its own, so it
# never shares windows, settings or saved state with the installed app.
BUNDLE_ID="${VIDEOCRUNCH_BUNDLE_ID:-com.videocrunch.app}"

# Where the app goes. VIDEOCRUNCH_INSTALL_DIR overrides it (used for testing).
INSTALL_DIR="${VIDEOCRUNCH_INSTALL_DIR:-/Applications}"
if [ -z "${VIDEOCRUNCH_INSTALL_DIR:-}" ] && [ ! -w "$INSTALL_DIR" ]; then
    INSTALL_DIR="$HOME/Applications"
fi
INSTALLED_APP="$INSTALL_DIR/VideoCrunch.app"

if pgrep -f "$INSTALLED_APP/Contents/MacOS/VideoCrunch" >/dev/null; then
    echo "⚠️  VideoCrunch läuft gerade. Bitte erst beenden (ein laufender Encode würde"
    echo "   sonst abgebrochen) und das Skript dann noch einmal starten."
    exit 1
fi

echo "🔨 Kompiliere native SwiftUI App..."
mkdir -p "$MACOS_DIR/VideoCrunch.app/Contents/MacOS"
mkdir -p "$MACOS_DIR/VideoCrunch.app/Contents/Resources"

swiftc -parse-as-library \
    "$MACOS_DIR/Sources/Models.swift" \
    "$MACOS_DIR/Sources/WizardViewModel.swift" \
    "$MACOS_DIR/Sources/WizardView.swift" \
    "$MACOS_DIR/Sources/DockAndNotifications.swift" \
    "$MACOS_DIR/Sources/ProDesign.swift" \
    "$MACOS_DIR/Sources/main.swift" \
    -o "$MACOS_DIR/VideoCrunch.app/Contents/MacOS/VideoCrunch"

if [ -f "$MACOS_DIR/AppIcon.icns" ]; then
    cp "$MACOS_DIR/AppIcon.icns" "$MACOS_DIR/VideoCrunch.app/Contents/Resources/AppIcon.icns"
fi

cat > "$MACOS_DIR/VideoCrunch.app/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key>
    <string>VideoCrunch</string>
    <key>CFBundleIdentifier</key>
    <string>$BUNDLE_ID</string>
    <!-- German UI: the standard menus read "Ablage", "Bearbeiten", … -->
    <key>CFBundleDevelopmentRegion</key>
    <string>de</string>
    <key>CFBundleLocalizations</key>
    <array>
        <string>de</string>
    </array>
    <key>CFBundleName</key>
    <string>VideoCrunch</string>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>1.0</string>
    <key>CFBundleVersion</key>
    <string>1</string>
    <key>LSMinimumSystemVersion</key>
    <string>13.0</string>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>LSApplicationCategoryType</key>
    <string>public.app-category.video</string>
    <!-- Videos and folders can be dropped on the Dock icon and opened with
         "Öffnen mit". Alternate: never becomes the default app for videos. -->
    <key>CFBundleDocumentTypes</key>
    <array>
        <dict>
            <key>CFBundleTypeName</key>
            <string>Video</string>
            <key>CFBundleTypeRole</key>
            <string>Viewer</string>
            <key>LSHandlerRank</key>
            <string>Alternate</string>
            <key>LSItemContentTypes</key>
            <array>
                <string>public.movie</string>
            </array>
        </dict>
        <dict>
            <key>CFBundleTypeName</key>
            <string>Ordner</string>
            <key>CFBundleTypeRole</key>
            <string>Viewer</string>
            <key>LSHandlerRank</key>
            <string>Alternate</string>
            <key>LSItemContentTypes</key>
            <array>
                <string>public.folder</string>
            </array>
        </dict>
    </array>
    <key>VideoCrunchRepoPath</key>
    <string>$SCRIPT_DIR</string>
</dict>
</plist>
PLIST

echo "📲 Installiere nach $INSTALLED_APP ..."
mkdir -p "$INSTALL_DIR"
rm -rf "${INSTALLED_APP:?}"
ditto "$APP_BUNDLE" "$INSTALLED_APP"

# Only the installed copy should show up under "Öffnen mit" and take drops.
"$LSREGISTER" -u "$APP_BUNDLE" 2>/dev/null || true
# Finder and the Dock cache an app's icon by bundle; without this a rebuilt
# app keeps showing the icon (or the blank placeholder) it was first seen with.
touch "$INSTALLED_APP"
"$LSREGISTER" -f "$INSTALLED_APP" 2>/dev/null || true

echo "📦 Registriere Finder Quick Action..."
SERVICE_DIR="$HOME/Library/Services/videocrunch.workflow/Contents"
mkdir -p "$SERVICE_DIR"

cat > "$SERVICE_DIR/document.wflow" <<WFLOW
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>AMApplicationBuild</key><string>521</string>
  <key>AMApplicationVersion</key><string>2.10</string>
  <key>AMDocumentVersion</key><string>2</string>
  <key>actions</key>
  <array>
    <dict>
      <key>action</key>
      <dict>
        <key>AMAccepts</key>
        <dict>
          <key>Container</key><string>List</string>
          <key>Optional</key><false/>
          <key>Types</key><array><string>com.apple.cocoa.string</string></array>
        </dict>
        <key>ActionBundlePath</key>
        <string>/System/Library/Automator/Run Shell Script.action</string>
        <key>ActionName</key><string>Run Shell Script</string>
        <key>ActionParameters</key>
        <dict>
          <key>COMMAND_STRING</key>
          <string>open -a "$INSTALLED_APP" "\$@"</string>
          <key>inputMethod</key><integer>1</integer>
          <key>shell</key><string>/bin/bash</string>
        </dict>
        <key>BundleIdentifier</key>
        <string>com.apple.RunShellScript</string>
        <key>CFBundleVersion</key>
        <string>2.0.3</string>
      </dict>
    </dict>
  </array>
  <key>workflowMetaData</key>
  <dict>
    <key>serviceApplicationBundleID</key><string>com.apple.finder</string>
    <key>serviceApplicationPath</key><string>/System/Library/CoreServices/Finder.app</string>
    <key>serviceInputTypeIdentifier</key>
    <string>com.apple.Automator.fileSystemObject</string>
    <key>serviceOutputTypeIdentifier</key><string>com.apple.Automator.nothing</string>
    <key>serviceProcessesInput</key><integer>0</integer>
    <key>workflowTypeIdentifier</key><string>com.apple.Automator.servicesMenu</string>
  </dict>
</dict>
</plist>
WFLOW

cat > "$SERVICE_DIR/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>NSServices</key>
  <array>
    <dict>
      <key>NSMenuItem</key><dict><key>default</key><string>videocrunch</string></dict>
      <key>NSMessage</key><string>runWorkflowAsService</string>
      <key>NSSendFileTypes</key>
      <array>
        <string>public.folder</string>
        <string>public.movie</string>
      </array>
    </dict>
  </array>
</dict>
</plist>
PLIST

/System/Library/CoreServices/pbs -flush 2>/dev/null || true

echo "✅ Fertig! VideoCrunch ist installiert: $INSTALLED_APP"
echo "   Ins Dock: die App aus dem Programme-Ordner ins Dock ziehen."
echo "   Starten: Videos oder Ordner aufs Dock-Symbol ziehen, oder"
echo "   Rechtsklick auf Datei/Ordner → Schnellaktionen → videocrunch"
