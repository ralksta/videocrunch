# VideoCrunch — App Store Connect Metadata (ASO-optimiert, Copy & Paste)

Dieses Dokument bündelt alle fertigen Felder für **App Store Connect** (Deutsch & Englisch), inklusive **App Review Notes** und einer **Screenshot-Checkliste** für macOS.

> [!NOTE]
> **Warum „Kostenlos“ im Werbetext & ganz oben in der Beschreibung steht (statt im App-Namen):**
> 1. **Apple App Review Guideline 2.3.7:** Apple lehnt Preisangaben wie „Kostenlos“ oder „Free“ im App-Namen und Untertitel ab — die Kostenlos-Botschaft muss stattdessen klar im Werbetext, in der Beschreibung und im App-Store-Preismodell (*Gratis*) stehen.
> 2. **30-Zeichen-Limit:** App-Name und Untertitel sind hart auf maximal 30 Zeichen begrenzt (`VideoCrunch – Videokonverter` nutzt 28/30 Zeichen, `Videos verkleinern & schneiden` 30/30).
> 3. **ASO-Maximierung:** Wörter aus Name & Untertitel müssen nicht in das 100-Zeichen-Keyword-Feld wiederholt werden — dort stecken ausschließlich zusätzliche Suchbegriffe ohne Dubletten. *(Untertitel, Werbetext & Beschreibung nennen zusätzlich stolz die moderne native macOS-App sowie vollständige Kostenfreiheit ohne Abo oder Wasserzeichen.)*

---

## 1. App Information & Settings (App Store Connect)

| Feld | Wert |
|---|---|
| **App Store Display Name (DE / EN)** | `VideoCrunch – Videokonverter` / `VideoCrunch: Video Converter` *(im Dock/Menü bleibt `VideoCrunch` über `CFBundleName`)* |
| **Bundle ID** | `io.github.ralksta.videocrunch` |
| **Platform / Architecture** | macOS `14.0+` · Apple Silicon (`arm64`) |
| **Version / Build** | `1.0` (`1`) |
| **Primary Category** | `Video` (`public.app-category.video`) |
| **Secondary Category** | `Utilities` |
| **Pricing** | Free / Kostenlos (keine In-App-Käufe, keine Abos, keine Wasserzeichen) |
| **Age Rating** | `4+` (alle Inhaltsdeskriptoren: None) |
| **Privacy Policy URL** | `https://github.com/ralksta/videocrunch/blob/main/PRIVACY.md` |
| **Support URL** | `https://github.com/ralksta/videocrunch/blob/main/SUPPORT.md` |
| **Marketing URL** (optional) | `https://github.com/ralksta/videocrunch` |
| **App Privacy** | **Data Not Collected** (Daten werden nicht erfasst) |
| **Export Compliance** | **No** (`ITSAppUsesNonExemptEncryption = false` in `Info.plist`) |
| **EU Digital Services Act (DSA)** | **Non-Trader / Kein Händler** *(kostenloses Open-Source-/Hobbyprojekt ohne Einnahmen — dadurch erscheinen private Anschrift/Telefon nicht öffentlich auf der EU-Store-Seite)* |
| **Copyright** | `© 2026 Ralf Ohlenbostel` |
| **License Agreement (EULA)** | **Custom License Agreement** → Text aus `macos/legal/AppStore-Custom-EULA.local.txt` (Vorlage: `macos/legal/AppStore-Custom-EULA.txt`) |

---

## 2. Deutsch (`de-DE`)

### Name (max. 30 Zeichen)

```text
VideoCrunch – Videokonverter
```

### Subtitle / Untertitel (max. 30 Zeichen)

```text
Videos verkleinern & schneiden
```

### Promotional Text / Werbetext (max. 170 Zeichen)

```text
100 % kostenlos, ohne Abo & Wasserzeichen: Videos blitzschnell verkleinern, schneiden & in MP4, HEVC, AV1 oder GIF wandeln. Moderne, lokale Mac-App ohne Tracking.
```

### Keywords / Schlüsselwörter (max. 100 Zeichen, ohne Leerzeichen nach Kommas)

```text
komprimieren,kompressor,mp4,mov,hevc,h265,av1,4k,trimmen,gif,batch,dateigröße,mail,ffmpeg,offline
```

### Description / Beschreibung (max. 4000 Zeichen)

```text
100 % kostenlos — kein Abo, keine In-App-Käufe, keine Wasserzeichen, keine Dateilimits.
VideoCrunch ist eine moderne, native macOS-App für Apple Silicon, mit der du riesige 4K-Videos, Bildschirmmitschnitte und volle iPhone-Ordner blitzschnell verkleinerst, konvertierst, schneidest oder fürs Teilen per Mail & Chat passend machst.

Warum eine moderne Mac-App statt veralteter Profi-Tools?
Andere Konverter überfordern dich mit zahllosen Reglern oder raten blind eine feste Bitrate — das Ergebnis wird entweder zu groß oder matschig. VideoCrunch geht einen klügeren Weg: Die App analysiert deine Clips vorab und sucht automatisch die kleinste Dateigröße, bei der das Bild sichtbar genauso scharf bleibt wie das Original (automatische Bildqualitätsprüfung per SSIM). Alles verpackt in einer klaren, aufgeräumten macOS-Oberfläche im nativen Design mit Drag-and-Drop, Live-Telemetrie und Dark Mode.

Alle Funktionen — komplett gratis im Paket:

• Intelligenter Ordner-Scan vor dem Start
Zieh einzelne Videos oder ganze Ordner ins Fenster oder direkt aufs Dock-Icon. Sofort siehst du nach erwarteter Ersparnis sortiert, bei welchen Clips sich das Verkleinern wirklich lohnt — bevor überhaupt ein Bild neu gerechnet wird.

• Blitzschnelles HEVC (Apple Media Engine) & modernes AV1
Nutzt die Hardware-Beschleunigung deines M1/M2/M3/M4-Macs über Apple VideoToolbox für extrem schnelles MP4/HEVC — oder AV1 für noch kleinere Archive. 10-Bit-HDR bleibt sauber erhalten; iPhone-Dolby-Vision-Videos (Profil 8.4 & 8.1) behalten automatisch ihre kompatible HDR-Basisschicht.

• Feste Zielgrößen für E-Mail & Messenger (10 / 25 / 50 / 100 MB)
Ein Klick bringt jedes Video zuverlässig unter das Upload-Limit für Mail, WhatsApp, Discord oder Webformulare — inklusive automatischer Anpassung von Bitrate und Auflösung.

• Verlustfrei trimmen & Clips zusammenfügen
Kürze Videos bildgenau in der Zoom-Timeline per Stream-Copy in wenigen Sekunden ohne Qualitätsverlust — oder verbinde mehrere kompatible Clips nahtlos zu einer einzigen MP4-Datei.

• GIFs mit Größen-Vorschau erstellen
Mach aus kurzen Szenen knackige GIFs (320 bis 800 px, 10 bis 25 fps, Zeitlupe, Normal oder Zeitraffer) mit optimierter Farbpalette und vorab berechneter Dateigröße.

• Clever Platz sparen bis ins Detail
Skaliere 4K sauber auf 2K, 1080p oder 720p herunter, halbiere 60 fps auf 30 fps (echte Zeitlupen bleiben geschützt), schneide schwarze Balken automatisch weg oder gleiche leise Clips zweistufig auf −16 LUFS an. Mit dem interaktiven Vorher/Nachher-Vergleichsregler (inkl. 100-%-Zoom) und dem Medien-Inspektor (⌘I) prüfst du jedes Detail direkt in der App.

• Volle Kontrolle & Schutz deiner Originale
Das Live-Cockpit zeigt Tempo, Bitrate, Qualitätsstufe sowie CPU- und GPU-Auslastung in Echtzeit. Deine Originale bleiben standardmäßig unangetastet neben der neuen Datei liegen; optionales Verschieben in den Papierkorb passiert erst nach vollständiger Integritätsprüfung.

Privat, 100 % offline & Open Source
VideoCrunch läuft komplett in der geschützten macOS App Sandbox ohne Internetzugang, ohne Konto und ohne Werbung oder Tracking — in 11 Sprachen (u. a. Deutsch, Englisch, Französisch, Spanisch, Italienisch, Niederländisch, Polnisch, Portugiesisch und Japanisch).
```

### What's New / Neue Funktionen (`1.0`)

```text
Erster Release von VideoCrunch im Mac App Store — komplett kostenlos, modern und 100 % lokal:
• Ordner-Scan mit Ersparnis-Prognose vor dem Konvertieren
• Schnelles Hardware-HEVC (Apple Media Engine) & AV1 mit automatischer Qualitätsprüfung
• Zielgröße-Modus (10 / 25 / 50 / 100 MB) für E-Mail & Chat
• Verlustfreies Trimmen, Zusammenfügen (Merge) & GIF-Export
• Moderne macOS-Oberfläche mit Live-Cockpit, CPU-/GPU-Anzeige, Vorher/Nachher-Vergleich & Medien-Inspektor
```

---

## 3. English (`en-US` & `en-GB`)

### Name (max 30 chars)

```text
VideoCrunch: Video Converter
```

### Subtitle (max 30 chars)

```text
Compress, Shrink & Trim Videos
```

### Promotional Text (max 170 chars)

```text
100% free with zero subscriptions or watermarks: shrink, convert, trim & merge 4K/HD videos into MP4, HEVC, AV1 & GIF. Modern native Mac app, 100% offline.
```

### Keywords (max 100 chars, no spaces after commas)

```text
compressor,mp4,mov,hevc,h265,av1,4k,gif,merge,batch,size,reduce,email,cut,lossless,ffmpeg,offline
```

### Description (max 4000 chars)

```text
100% free — zero subscriptions, zero in-app purchases, zero watermarks, and zero file caps.
VideoCrunch is a modern, native macOS app built for Apple Silicon that lets you compress huge 4K footage, screen recordings, and phone video libraries quickly — without trading away visual sharpness or wrestling with cryptic encoder sliders.

Why a modern Mac app instead of legacy tools?
Most video converters force you to guess a bitrate or quality number and hope the output looks okay. VideoCrunch analyzes each clip upfront, locates demanding high-action moments, and runs an automatic search verified by structural similarity (SSIM) — automatically stopping at the smallest file size that still looks clean to the eye. All inside a crisp, fast SwiftUI interface with native macOS Dark Mode, drag-and-drop, and live telemetry.

Everything included for free:

• Smart Folder Scan Before You Convert
Drop individual clips or entire folders into the window or onto the Dock icon. VideoCrunch ranks which videos are actually worth compressing and estimates disk savings upfront before encoding a single frame.

• Fast Apple Silicon HEVC & Modern AV1
Encode at top speed using Apple's hardware Media Engine (VideoToolbox) for MP4/HEVC, or pick AV1 (SVT-AV1) for maximum density. 10-bit HDR stays intact, and iPhone Dolby Vision clips (Profiles 8.4 & 8.1) automatically preserve their compatible HLG or HDR10 base layer.

• Target Size Presets for Email & Chat (10 / 25 / 50 / 100 MB)
Fit any video under strict upload limits for email, Slack, Discord, or messaging with automatic bitrate and resolution scaling.

• Lossless Trim & Merge
Cut clips frame-accurately on a zoomable timeline using zero-re-encode stream copy in seconds, or merge compatible clips seamlessly into a single MP4.

• High-Quality GIF Export with Size Estimates
Turn short moments into smooth GIFs (320 to 800 px wide, 10 to 25 fps, slow motion, normal, or time-lapse) with palette optimization and upfront size estimation.

• Thoughtful Space-Saving Switches
Downscale 4K to 2K, 1080p, or 720p, halve 60 fps footage to 30 fps (keeping true slow motion untouched), auto-crop black letterbox bars, or normalize quiet audio to −16 LUFS. Inspect every change with the interactive Before/After wipe comparison (with 100% pixel zoom) and Media Info inspector (⌘I).

• Live Cockpit & Safe Originals
Watch real-time speed, bitrate, quality level, and CPU & GPU load while batches run. Your originals stay untouched beside the output file by default; optional Move Originals to Trash activates only after a full integrity decode check passes.

Private, 100% Offline & Open Source
Runs strictly inside the macOS App Sandbox with zero network permissions, zero accounts, and zero ads or tracking — localized in 11 languages.
```

### What's New (`1.0`)

```text
Initial Mac App Store release of VideoCrunch — 100% free, modern, and completely offline:
• Folder scan with upfront savings ranking
• Fast Apple Media Engine HEVC & AV1 compression with automatic quality verification
• Target Size mode (10 / 25 / 50 / 100 MB) for email and chat
• Lossless Trim, Merge, and palette-optimized GIF export
• Modern macOS interface with live CPU/GPU cockpit, Before/After comparison slider, and Media Info inspector
```

---

## 4. App Review Information (Notes for Apple App Review)

```text
VideoCrunch is a 100% offline, completely free local macOS video converter, compressor, trimmer, merger, and GIF utility. No login, demo account, subscription, or network connection is required.

Quick verification steps:
1. Launch VideoCrunch and drop any local .mp4 or .mov video (or a folder of videos) onto the window, or click "Choose Videos or Folders…".
2. Review the non-destructive scan estimate, select a video, pick a preset (e.g., "Archive (Balanced)" or "Mail / Chat (25 MB)"), and click "Start Encode".
3. Once finished, click "Compare" to inspect the Before/After wipe view or "Reveal in Finder" to verify the output file saved next to the original.

App Sandbox & Bundled Helpers Notes:
- Network entitlements are intentionally omitted; all processing occurs strictly on-device.
- VideoCrunch requests `com.apple.security.files.user-selected.read-write`, `com.apple.security.files.bookmarks.app-scope` (for persistent custom destination folders chosen by the user), and `com.apple.security.assets.movies.read-write` (for direct access inside ~/Movies).
- Embedded CLI helpers inside Contents/Helpers/ (LGPL v2.1+ FFmpeg/FFprobe, BSD SVT-AV1/dav1d, and PSF CPython runtime) are signed with `com.apple.security.app-sandbox` and `com.apple.security.inherit`. Complete open-source license texts, configure details, and upstream source links are viewable inside the app under VideoCrunch → About VideoCrunch → Open-Source Licenses…, and our Custom EULA complies with LGPL v2.1 Section 6.

Contact: videocrunch@ralfus.de
```

---

## 5. Empfohlene macOS-Screenshots (5 Stück · `2880 × 1800` oder `2560 × 1600` px)

1. **Shot 1 — Scan / Drop & Übersicht:** Startansicht oder Auswahl-Liste (`SelectionStep`) mit mehreren Videos, grünen Ersparnis-Prognosen und Ersparnis-Ranking — zeigt auf einen Blick: *„Analysiert vor dem Rechnen“*.
2. **Shot 2 — Optionen + Trim-Timeline:** `OptionsStep` mit geöffnetem Video in der linken Trim-Timeline und klar sichtbaren Zielen (*Nach Qualität / Maximalgröße 25 MB*, *HEVC / AV1*, *1080p*, *30 fps*, *Balken*).
3. **Shot 3 — Live Encoding Cockpit:** Aktives Encoding (`EncodingStep`) bei ~30–60 % mit sichtbarem Tempo (`×`), Bitrate, Qualitätsstufe, CPU-/GPU-Balken und laufender SSIM-Pipeline.
4. **Shot 4 — Vorher / Nachher-Vergleich:** Geöffneter `Compare`-Slider (`Vorher / Nachher`) über einer knackigen Szene inklusive `100 %`-Zoom-Badge.
5. **Shot 5 — Ergebnis & Medien-Inspektor:** `CompletedStep` mit klaren MB-/Prozent-Ersparnis-Karten + `SSIM 0.9xx` neben dem `Medien-Info (⌘I)`-Fenster (Bitraten-Kurve & Hotspot-Marker).
