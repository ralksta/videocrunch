#!/bin/bash
# Builds VideoCrunch.app and installs the Finder Quick Action into ~/Library/Services/.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
MACOS_DIR="$SCRIPT_DIR/macos/VideoCrunch"
APP_BUNDLE="$MACOS_DIR/VideoCrunch.app"

echo "🔨 Kompiliere native SwiftUI App..."
mkdir -p "$MACOS_DIR/VideoCrunch.app/Contents/MacOS"
mkdir -p "$MACOS_DIR/VideoCrunch.app/Contents/Resources"

swiftc -parse-as-library \
    "$MACOS_DIR/Sources/Models.swift" \
    "$MACOS_DIR/Sources/WizardViewModel.swift" \
    "$MACOS_DIR/Sources/WizardView.swift" \
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
    <string>com.videocrunch.app</string>
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
    <key>VideoCrunchRepoPath</key>
    <string>$SCRIPT_DIR</string>
</dict>
</plist>
PLIST

# Finder and the Dock cache an app's icon by bundle; without this a rebuilt
# app keeps showing the icon (or the blank placeholder) it was first seen with.
touch "$APP_BUNDLE"
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister \
    -f "$APP_BUNDLE" 2>/dev/null || true

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
          <string>APP="$APP_BUNDLE/Contents/MacOS/VideoCrunch"

for f in "\$@"
do
    "\$APP" "\$f" &amp;
done</string>
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

echo "✅ Fertig! VideoCrunch GUI und Finder Quick Action erfolgreich eingerichtet."
echo "   Rechtsklick auf Datei oder Ordner → Schnellaktionen → videocrunch"
