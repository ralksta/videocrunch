# VideoCrunch Support

**Deutsch:** [Zur deutschen Support-Übersicht](#support-deutsch)

---

## English

Need help with **VideoCrunch** for macOS? Check the quick answers below or open a bug report / feature request on GitHub.

- **Developer:** Ralf Ohlenbostel
- **Support Email:** `videocrunch@ralfus.de`
- **Issue Tracker & Support:** https://github.com/ralksta/videocrunch/issues
- **Source Code & Documentation:** https://github.com/ralksta/videocrunch
- **Privacy Policy:** [PRIVACY.md](PRIVACY.md)

### Reporting a Bug

When opening a GitHub issue, please include:
1. Your **macOS version** and **Mac model / Apple Silicon chip** (e.g., M1 / M2 / M3 / M4).
2. Your selected **preset, codec (`HEVC` or `AV1`), and target mode** (`By Quality`, `Size Limit`, `Trim Only`, `Merge`, or `Make GIF`).
3. Output from **Media Info (`⌘I`) → Copy as Text** (for affected source clips) and the **Log** section from the encoding view if an error occurred.

### Frequently Asked Questions

- **What macOS hardware is supported?**  
  VideoCrunch requires **macOS 14.0 (Sonoma) or later** on **Apple Silicon (`arm64`)**.

- **Will VideoCrunch overwrite or delete my original videos?**  
  No. By default, compressed files are saved next to the originals (`_opt.mp4`, `_trim.mp4`, `_merged.mp4`, `_25MB.mp4`, or `.gif`). Even if you enable **Move Originals to Trash**, VideoCrunch runs a full output integrity decode verification first and moves originals safely to the macOS Trash rather than permanently deleting them.

- **Why does VideoCrunch ask for folder write permission?**  
  In the Mac App Store version, macOS App Sandbox protects your files by requiring explicit permission before writing to folders you did not directly pick via a Save panel. Granting access once stores a secure app-scoped bookmark locally. You can reset all saved permissions anytime under **Settings → Output Location → Reset Access**.

- **Why is HEVC much faster than AV1?**  
  HEVC uses Apple's dedicated hardware **Media Engine (VideoToolbox)**, while AV1 software encoding (`SVT-AV1`) runs on the CPU for maximum compression density. Keep **HEVC / H.265** selected for fast everyday shrinking and universal device playback.

- **What does SSIM verification mean?**  
  Instead of guessing one blind quality factor, VideoCrunch runs a binary search across quality levels and verifies structural similarity (**SSIM**) against the toughest high-bitrate scenes in your video — stopping as soon as it finds the smallest file that clears your visual quality bar (`Best Quality` ≥ 0.988, `Balanced` ≥ 0.980, `Compact` ≥ 0.960).

- **Where can I inspect Open-Source licenses & FFmpeg build details?**  
  Open **VideoCrunch → About VideoCrunch → Open-Source Licenses…** inside the app.

---

## Support (Deutsch)

Du brauchst Hilfe zu **VideoCrunch** für macOS oder hast einen Bug gefunden? Hier findest du die wichtigsten Antworten sowie den direkten Draht zum Issue Tracker:

- **Entwickler:** Ralf Ohlenbostel
- **Support per E-Mail:** `videocrunch@ralfus.de`
- **Support & Fehlermeldungen:** https://github.com/ralksta/videocrunch/issues
- **Quellcode & Dokumentation:** https://github.com/ralksta/videocrunch
- **Datenschutzerklärung:** [PRIVACY.md](PRIVACY.md#datenschutzerklärung-deutsch)

### Fehler melden — was hilft weiter?

Bitte schreib bei einem Issue auf GitHub kurz dazu:
1. Deine **macOS-Version** und deinen **Mac / Apple-Silicon-Chip** (z. B. M1 / M2 / M3 / M4).
2. Gewähltes **Preset, Codec (`HEVC` oder `AV1`) und Modus** (`Nach Qualität`, `Maximalgröße (MB)`, `Nur trimmen`, `Zusammenfügen` oder `GIF erstellen`).
3. Bei Problemen mit einer bestimmten Datei gerne die Kopie aus **Medien-Info (`⌘I`) → Als Text kopieren** sowie den Ausschnitt aus dem **Protokoll**.

### Häufige Fragen (FAQ)

- **Welche Systemvoraussetzungen hat VideoCrunch?**  
  Die App läuft auf jedem Mac mit **Apple Silicon (`arm64`)** ab **macOS 14.0 (Sonoma)**.

- **Bleiben meine Originalvideos sicher erhalten?**  
  Ja. Standardmäßig speichert VideoCrunch die optimierte Datei direkt neben dem Original (`_opt.mp4`, `_trim.mp4`, `_merged.mp4`, `_25MB.mp4` oder `.gif`). Selbst mit aktivierter Option **Originale in den Papierkorb** prüft VideoCrunch zuerst die Integrität der neuen Datei komplett durch und schiebt das Original anschließend sicher in den Papierkorb statt es endgültig zu löschen.

- **Warum fragt VideoCrunch beim Speichern nach Ordnerzugriff?**  
  Durch die macOS App Sandbox darf eine Mac-App-Store-App erst nach deiner Freigabe in einen Zielordner schreiben. Nach einmaliger Zustimmung merkt sich macOS diese Freigabe lokal per Bookmark. Du kannst sie jederzeit unter **Einstellungen → Ausgabeort → Zugriff zurücksetzen** löschen.

- **Warum ist HEVC deutlich schneller als AV1?**  
  **HEVC / H.265** nutzt Apples Hardware-Encoder (**Apple Media Engine / VideoToolbox**), während **AV1 (`SVT-AV1`)** auf der CPU rechnet. Für maximalen Durchsatz und höchste Gerätekompatibilität empfiehlt sich HEVC als Standard.

- **Was bedeutet die SSIM-Qualitätsprüfung?**  
  Statt pauschal eine fixe Kompressionsstufe zu raten, prüft VideoCrunch per binärer Suche über mehrere Qualitätsstufen hinweg mithilfe von **SSIM** die Bildtreue gerade in den anspruchsvollsten Szenen — und wählt die kleinste Datei, die dein Qualitätsziel sauber hält (`Beste Qualität` ≥ 0,988, `Ausgewogen` ≥ 0,980, `Kompakt` ≥ 0,960).

- **Wo finde ich die Open-Source-Lizenzen (FFmpeg / SVT-AV1 / dav1d)?**  
  Direkt in der App über **VideoCrunch → Über VideoCrunch → Open-Source-Lizenzen…**.
