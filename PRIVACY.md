# Privacy Policy for VideoCrunch

**Effective Date:** 2026  
**Applies to:** VideoCrunch for macOS (`io.github.ralksta.videocrunch`)  
**Deutsch:** [Zur deutschen Datenschutzerklärung](#datenschutzerklärung-deutsch)

---

## English

### 1. Zero Data Collection & Zero Network Access

VideoCrunch is designed from the ground up to run **100% locally offline** on your Mac:

- **No personal data is collected, stored on remote servers, sold, or shared.**
- **No analytics, no telemetry, no crash reporters, no third-party tracking SDKs, and no advertising.**
- **No account or sign-in required.**
- **Technically enforced offline operation:** In the Mac App Store edition, macOS App Sandbox explicitly omits network client and server entitlements (`com.apple.security.network.client` and `com.apple.security.network.server`). VideoCrunch cannot make outbound network connections or transmit your videos, filenames, or metadata anywhere.

### 2. Local File & Folder Access

VideoCrunch accesses video files and destination folders **only when you explicitly select them** (via drag-and-drop, the Open dialog, or the output folder picker) or via macOS standard Movies folder entitlement (`com.apple.security.assets.movies.read-write`):

- **App-Scoped Security Bookmarks:** If you configure a custom output folder or grant persistent write permission to a destination folder, macOS stores an encrypted, app-scoped security bookmark locally so you do not have to re-authorize that folder on future runs. You can clear saved folder permissions anytime in **VideoCrunch → Settings → Output Location → Reset Access**.
- **Safe Handling of Originals:** By default, VideoCrunch saves new files alongside your original videos (`_opt.mp4`, `_trim.mp4`, `_merged.mp4`, `_25MB.mp4`, or `.gif`) and leaves originals untouched. When **Move Originals to Trash** is enabled, originals are moved to your macOS Trash only after output integrity verification succeeds.

### 3. On-Device Preferences & Logs (`NSPrivacyAccessedAPITypes`)

All application state stays strictly inside your local macOS user container:

- **UserDefaults (`CA92.1`):** Stores your preferred language, encoding presets, UI options, and local cumulative space-saved counters. Resettable anytime inside **VideoCrunch → Settings**.
- **File Timestamps & Disk Space (`C617.1`, `E174.1`):** Used locally to check file metadata before/after encoding, clear Finder hidden flags on temporary staging outputs, and verify sufficient free disk space before starting an encode.
- **Local Logs:** Encoding history and diagnostic logs remain in your local app container (`Application Support` / `Logs`) solely for your own troubleshooting and history display. They are never transmitted automatically.

### 4. Children's Privacy

Because VideoCrunch collects zero personal data and operates completely offline, it does not knowingly or unknowingly collect personal information from children or anyone else.

### 5. Contact & Controller

Responsible for this application and privacy inquiries:

- **Developer:** Ralf Ohlenbostel
- **Email:** `videocrunch@ralfus.de`
- **GitHub Repository:** https://github.com/ralksta/videocrunch
- **Issue Tracker:** https://github.com/ralksta/videocrunch/issues

---

## Datenschutzerklärung (Deutsch)

**Stand:** 2026  
**Gilt für:** VideoCrunch für macOS (`io.github.ralksta.videocrunch`)

### 1. Keine Datenerhebung & kein Netzwerkzugriff

VideoCrunch arbeitet zu **100 % lokal und offline** direkt auf deinem Mac:

- **Es werden keine personenbezogenen Daten erhoben, auf fremde Server übertragen, verkauft oder geteilt.**
- **Keine Analyse-Tools, keine Telemetrie, kein Tracking, keine Werbung und keine Drittanbieter-SDKs.**
- **Kein Konto, kein Login.**
- **Technisch abgesichert über die macOS App Sandbox:** Die Mac-App-Store-Version besitzt bewusst **keine** Netzwerk-Berechtigungen (`com.apple.security.network.client` / `com.apple.security.network.server` sind nicht aktiv). Die App kann weder Videos noch Dateinamen oder Metadaten ins Internet senden.

### 2. Lokaler Datei- und Ordnerzugriff

VideoCrunch greift ausschließlich auf Videos und Zielordner zu, die du **aktiv selbst auswählst** (per Drag-and-Drop, Öffnen-Dialog oder Zielordner-Auswahl) sowie im Rahmen der macOS-Sandbox-Berechtigung für den Ordner *Filme* (`com.apple.security.assets.movies.read-write`):

- **App-bezogene Security-Scoped Bookmarks:** Wenn du einen eigenen Ausgabeordner festlegst oder Schreibzugriff für einen Ordner erlaubst, speichert macOS diese Freigabe lokal in einem app-spezifischen Bookmark, damit zukünftige Durchläufe ohne erneute Rückfrage laufen. Gespeicherte Ordner-Freigaben lassen sich jederzeit unter **VideoCrunch → Einstellungen → Ausgabeort → Zugriff zurücksetzen** löschen.
- **Schutz deiner Originale:** Standardmäßig bleiben Originaldateien unangetastet (`_opt.mp4`, `_trim.mp4`, `_merged.mp4` usw. entstehen daneben). Nur wenn **Originale in den Papierkorb** ausdrücklich aktiviert ist und die abschließende Integritätsprüfung der neuen Datei bestanden wurde, wandert das Original in den macOS-Papierkorb.

### 3. Lokale Einstellungen & Protokolle (`NSPrivacyAccessedAPITypes`)

Alle App-Daten verbleiben ausschließlich lokal in deinem Benutzer-Container auf dem Mac:

- **UserDefaults (`CA92.1`):** Speichert lokal deine gewählte App-Sprache, eigene Presets, Optionen sowie den lokalen Zähler für insgesamt gesparten Speicherplatz (jederzeit in den Einstellungen zurücksetzbar).
- **Zeitstempel & freier Speicherplatz (`C617.1`, `E174.1`):** Werden ausschließlich lokal genutzt, um vor dem Start freien Festplattenplatz zu prüfen und fertig geschriebene Dateien sauber im Finder anzuzeigen.
- **Lokale Logs:** Verlaufs- und Diagnoseprotokolle liegen ausschließlich lokal in deinem App-Container und werden niemals automatisch versendet.

### 4. Kontakt & Verantwortlicher

Verantwortlich für diese App und Fragen zum Datenschutz:

- **Anbieter:** Ralf Ohlenbostel
- **E-Mail:** `videocrunch@ralfus.de`
- **Quellcode:** https://github.com/ralksta/videocrunch
- **Issues / Support:** https://github.com/ralksta/videocrunch/issues
