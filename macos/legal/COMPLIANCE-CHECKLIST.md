# Mac App Store Compliance-Checkliste (VideoCrunch)

Diese Checkliste fasst die kurzen manuellen Schritte vor dem Upload in App Store Connect zusammen — ergänzt zur technischen LGPL-/Open-Source-Bündelung im App-Bundle (`Contents/Resources/LICENSES/NOTICES.txt`).

## 1. Custom EULA in App Store Connect hinterlegen (LGPL §6)
1. Öffne [AppStore-Custom-EULA.txt](AppStore-Custom-EULA.txt).
2. Ersetze alle drei Platzhalter durch deine realen Kontaktdaten:
   - `[YOUR FULL NAME OR LEGAL ENTITY]` (zweimal im Text: Abschnitt 1 & Abschnitt 9)
   - `[YOUR MAILING ADDRESS]` (Abschnitt 9)
   - `[YOUR CONTACT EMAIL]` (Abschnitt 9)
3. Kopiere den kompletten Plain-Text in App Store Connect unter **App-Informationen → Lizenzvereinbarung → Eigene Lizenzvereinbarung (Custom License Agreement)**.
4. Warum: Apples Standard-EULA verbietet pauschal Reverse Engineering, während LGPL v2.1 §6 Reverse Engineering explizit *zum Debuggen eigener Änderungen an den LGPL-Bibliotheken (FFmpeg)* erlauben muss.

## 2. Unveränderte Upstream-Source-Tarballs beim GitHub-Release spiegeln
Lade beim Erstellen des passenden GitHub-Releases unter `https://github.com/ralksta/videocrunch/releases` die drei exakten, unveränderten Upstream-Quellarchive direkt als Release-Assets hoch (damit das Source-Angebot in `NOTICES.txt` auch langfristig ohne 404 abrufbar bleibt):
- `ffmpeg-8.1.tar.xz` (`https://ffmpeg.org/releases/ffmpeg-8.1.tar.xz`)
- `SVT-AV1-v3.0.2.tar.bz2` (`https://gitlab.com/AOMediaCodec/SVT-AV1/-/archive/v3.0.2/SVT-AV1-v3.0.2.tar.bz2`)
- `dav1d-1.5.1.tar.bz2` (`https://code.videolan.org/videolan/dav1d/-/archive/1.5.1/dav1d-1.5.1.tar.bz2`)

## 3. Export-Compliance (Verschlüsselung)
- Prüfe vor dem Upload in `Info.plist`, dass `ITSAppUsesNonExemptEncryption` auf `false` (`NO`) steht.
- VideoCrunch nutzt **keine** Netzwerk-Entitlements (`com.apple.security.network.client` und `com.apple.security.network.server` fehlen bewusst in `VideoCrunch.entitlements`) und ruft keine OpenSSL-Kryptofunktionen aus der eingebetteten Python-Standardbibliothek auf (OpenSSL 3.5.9 ist lediglich Teil der unveränderten `python-build-standalone`-Binary).
- Beim App-Store-Connect-Fragebogen zur Export-Compliance entsprechend angeben, dass die App keine nicht ausgenommene Verschlüsselung nutzt.

## 4. App-Datenschutz (App Privacy)
- In App Store Connect unter **App-Datenschutz** kann **„Daten werden nicht erfasst“ (Data Not Collected)** angegeben werden: VideoCrunch arbeitet zu 100 % lokal offline ohne Telemetrie, Analytics oder Netzwerkzugriff.
