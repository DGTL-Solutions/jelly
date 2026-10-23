# Jelly im App Store (kostenlos)

Stand 23.10.2026. Technisch ist alles vorbereitet; offen sind die Entscheidungen unten und die Schritte, die nur im Browser gehen.

## 1. Lizenzen – ohne laufende Kosten

Jelly spielt seit dem 23.10.2026 mit **AetherEngine** statt KSPlayer (KSPlayer hätte für den App Store mindestens 15 $ im Monat gekostet). Keine Komponente kostet etwas oder steht unter GPL:

| Komponente | Lizenz | Was dafür zu tun ist |
| --- | --- | --- |
| AetherEngine 7.46.0 | LGPL-3.0 mit ausdrücklicher App-Store-/DRM-Ausnahme | Lizenztext zeigen (erledigt), auf den genauen Tag verweisen (in der App: Version 7.46.0 + Link); eigene Änderungen an der Engine müssten veröffentlicht werden – Jelly ändert sie nicht |
| FFmpeg 8.1.3 (FFmpegBuild 3.9.0), dav1d, zimg, ZVBI | LGPL-2.1 ohne GPL-Teile bzw. BSD/WTFPL/MIT | als dynamische Frameworks in `Jelly.app/Frameworks` (geprüft), Lizenztexte und Quellcode-Link in der App (erledigt) |
| libdovi | MIT | Copyright-Hinweis von quietvoid (erledigt) |
| libass, FreeType, HarfBuzz, libunibreak | ISC, FTL, MIT, zlib | Hinweise in der App (erledigt) |
| GNU FriBidi (für libass) | LGPL-2.1 | steckt statisch in der App-Binärdatei; erfüllt, weil Jellys Quellcode offen ist (MPL-2.0, https://github.com/DGTL-Solutions/jelly) und jeder die App mit einer geänderten FriBidi neu bauen kann |

## 1a. Preis: Jahresabo 9,99 € mit 2 Wochen gratis

Die App ist **gratis**, freigeschaltet wird sie mit dem **automatisch verlängerten Jahresabo „Jelly Jahresabo“ für 9,99 € pro Jahr**; neue Abonnenten bekommen als Einführungsangebot **2 Wochen gratis**. Das Abo gehört zur Apple-ID: ein Abo gilt auf allen Apple TVs dieser Apple-ID, Neuinstallieren gibt keinen neuen Probezeitraum, gekündigt wird in den Apple-TV-Einstellungen (Benutzer und Accounts › Abonnements). Ohne Abo bleiben Bibliothek und Einstellungen offen, nur das Abspielen verlangt das Abo.

In der App fertig (nur im App-Store-Build mit dem Schalter `APPSTORE`, den `Scripts/release-appstore.sh` setzt):
- Angebot nach der ersten Anmeldung und bei jedem Abspielen ohne Abo, mit allem, was Apple für Abos verlangt (Richtlinie 3.1.2): Name, Laufzeit, Preis pro Jahr, Probezeit und was danach passiert, automatische Verlängerung und Kündigung bis 24 h vor Ablauf, wo man kündigt, **Nutzungsbedingungen** (Apples Standard-EULA) und **Datenschutz** – auf dem Fernseher ohne Browser als Adresse mit QR-Code, den Datenschutz zusätzlich als Text (Screenshot für die Prüfung: `screenshots/iap-review-angebot.png`).
- Einstellungen › Jahresabo: Status (Probezeit mit Resttagen, aktiv, abgelaufen), Abo abschließen, **Käufe wiederherstellen**.
- StoreKit 2 mit Apples signierten Transaktionen: Verlängerungen, Kündigungen, Erstattungen, Kulanzfrist bei Zahlungsproblemen und Käufe von anderen Geräten kommen automatisch an.
- Ohne `APPSTORE` (eigene Builds, Quellcode) gibt es keine Sperre.

In App Store Connect zu tun:
1. **Verträge:** Business › „Vereinbarung für kostenpflichtige Apps“ annehmen, Bank- und Steuerdaten hinterlegen – ohne sie lassen sich keine Abos verkaufen. Tipp: **Small Business Program** beantragen – dann behält Apple 15 % statt 30 %.
2. **EU-Händlerstatus (DSA):** als Händler eintragen; Anschrift, Telefon und E-Mail erscheinen öffentlich im App Store.
3. **Impressum und Datenschutz** veröffentlichen (Vorlage in `docs/`, wird als GitHub-Pages-Seite von `DGTL-Solutions/jelly` veröffentlicht; die Datenschutz-Adresse `https://dgtl-solutions.github.io/jelly/datenschutz/` steht schon in der App).
4. **Abo anlegen** (App › Monetarisierung › Abonnements):
   - Abo-Gruppe „Jelly“ (Anzeigename de: „Jelly“)
   - Abo: Referenzname „Jelly Jahresabo“, Produkt-ID **`net.dgtl24.jelly.yearly`** (= Bundle-ID + `.yearly`), Dauer **1 Jahr**, Preis **9,99 €** (Basisland Deutschland, andere Länder automatisch), Anzeigename „Jelly Jahresabo“, Beschreibung „Alle Funktionen von Jelly, ein Jahr lang“, Familienfreigabe nach Wunsch
   - Einführungsangebot: **Gratis-Testzeitraum, 2 Wochen**, alle Länder, für neue Abonnenten
   - Review-Screenshot hochladen und das Abo **mit der ersten App-Version** zur Prüfung einreichen
5. **App-Preis:** Gratis. **App-Datenschutz** bleibt „Keine Daten erfasst“ – das Abo wickelt Apple ab, Jelly gibt nichts weiter.
6. **Lizenzvereinbarung:** Apples Standard-EULA belassen; der Link steht in App und Beschreibung.

Rechtliches, kurz: Apple ist beim Verkauf im App Store in der EU Wiederverkäufer, führt die Umsatzsteuer ab und übernimmt Widerruf, Kündigung und Erstattungen. Die Lizenzen der eingebauten Software erlauben den Verkauf (LGPL/MPL verbieten keine Preise). Für den Verkauf entfernt: IMDb-Daten (nur nicht-kommerziell frei) und der Name „Rotten Tomatoes“; die App-Store-Fassung zeigt Bewertungen vom Jellyfin-Server des Nutzers. Abos verlangt Apple für Apps mit fortlaufendem Nutzen (Richtlinie 3.1.2) – bei einem gepflegten Mediaplayer mit Updates üblich (wie Infuse oder Plex), ein Restrisiko bei der Prüfung bleibt. Weitere Restrisiken jeder Mediaplayer-App: Codec-Patente (H.264/HEVC laufen über Apples lizenzierte Hardware-Decoder, MPEG-2- und AC-3-Patente sind abgelaufen) und – wegen des offenen Quellcodes – Nachbauten: MPL erlaubt Weitergabe, aber nicht Name und Symbol. Das ersetzt keine Rechtsberatung.

## 2. Weitere Entscheidungen

- **Verkäufer und Rechte (entschieden 23.10.2026):** Jelly erscheint über das Entwicklerkonto der **Nessy GmbH** (Team Q7R4G28Q55) – dort stehen Verkäufername, EU-Händlerangaben und Auszahlungen; Nessy und DGTL verrechnen intern. **Rechteinhaber** bleibt die DGTL Solutions GmbH: „© 2026 DGTL Solutions GmbH“ in der App (`AppInfo`) und im Copyright-Feld von App Store Connect, Quellcode unter https://github.com/DGTL-Solutions/jelly. Ein späterer Umzug auf ein eigenes DGTL-Konto geht per App-Übertragung (Einmalkäufe ziehen mit; Nutzer melden sich danach einmal neu bei ihrem Jellyfin-Server an, weil sich mit der Team-ID die Schlüsselbund-Gruppe ändert).
- **Name:** „Jelly“ (`metadata/de-DE/name.txt`). App-Namen sind im App Store eindeutig; ist „Jelly“ schon vergeben, meldet App Store Connect das beim Anlegen.
- **Bundle-ID:** `net.dgtl24.jelly` (wie die installierte Version, Top Shelf `.topshelf`). Lässt sich vor dem ersten Upload noch ändern.
- **Länder:** Die Oberfläche ist nur Deutsch – Deutschland, Österreich, Schweiz oder weltweit.
- **Exportkonformität:** Jelly nutzt HTTPS nur noch über Apples Frameworks (AetherEngines FFmpeg hat keinen eigenen Netzwerk-Stack, die Engine lädt über URLSession). Damit passt im Fragebogen „nur Verschlüsselung innerhalb von Apples Betriebssystem“; der Herausgeber bestätigt das, danach `ITSAppUsesNonExemptEncryption = NO` in `project.yml` setzen, dann fragt App Store Connect nicht bei jedem Build.
- **IMDb-Bewertungen:** in der App-Store-Fassung entfernt (IMDb erlaubt den Datensatz nur nicht-kommerziell); dort zeigt Jelly die Bewertungen des Jellyfin-Servers. Eigene Builds behalten IMDb.

## 3. Im Browser (App Store Connect)

1. **App anlegen** (Apps › + › Neue App): Plattform tvOS, Name, Primärsprache Deutsch, Bundle-ID `net.dgtl24.jelly`, SKU z. B. `jelly-tvos`. Die API kann keine Apps anlegen.
2. **Datenschutzerklärung und Support-Seite mit Impressum:** liegen in `docs/` und erscheinen per GitHub Pages unter `https://dgtl-solutions.github.io/jelly/datenschutz/` und `/support/` (stehen schon in `metadata/de-DE/` und in der App); vorher die Platzhalter ausfüllen.
3. **App-Datenschutz:** „Es werden keine Daten erfasst“ (Jelly sendet nur an die Server des Nutzers; Privacy Manifest liegt bei).
4. **Altersfreigabe:** Alle Fragen zu Inhalten mit „Keine“ beantworten (Jelly hat keine eigenen Inhalte); bei „Uneingeschränkter Webzugriff“ Nein. Apple kann für Mediaplayer, die beliebige Inhalte abspielen, trotzdem eine höhere Stufe verlangen.
5. **Kategorie:** Unterhaltung. **Preis:** Gratis, freigeschaltet wird per Jahresabo (siehe 1a).
6. **Texte** aus `metadata/de-DE/`, **Review-Hinweise** aus `review-notes.txt` (Demo-Server `demo.jellyfin.org/stable`, Konto „demo“ ohne Passwort – getestet am 23.10.2026: 11 frei lizenzierte Filme, kein Admin).
7. **Screenshots:** 1920×1080 oder 3840×2160, 1–10 Stück. Am besten im Simulator mit dem Demo-Server – dessen Filme (Caminandes, Dracula …) sind frei lizenziert, fremde Filmplakate könnten in der Prüfung abgelehnt werden.

## 4. Build hochladen

```sh
# Einmal pro Team: Apple-Distribution-Zertifikat anlegen (legt ein Zertifikat im Account an)
python3 Scripts/asc_certificate.py <Key-ID> <Issuer-ID> ~/.appstoreconnect/private_keys/AuthKey_<Key-ID>.p8 ~/.appstoreconnect/jelly-dist

# Bauen, signieren, prüfen, hochladen (UPLOAD=0: nur die .ipa bauen)
ASC_KEY_ID=<Key-ID> ASC_ISSUER_ID=<Issuer-ID> DIST_CERT_DIR=~/.appstoreconnect/jelly-dist Scripts/release-appstore.sh
```

Das Skript erzeugt die App-Store-Profile über die API, baut mit fortlaufender Build-Nummer, signiert ohne Schlüsselbund (rcodesign) und lädt per `altool` hoch. Es ist noch nie gelaufen – der erste Durchgang zeigt, ob Apple die Signatur und die eingebetteten Frameworks so annimmt.

## 5. Was in der App schon vorbereitet ist

- Einstellungen › Info: Version mit Build-Nummer, **Open-Source-Lizenzen** (AetherEngine zuerst, 11 Komponenten mit Version, Copyright, Quelle und vollständigem Lizenztext aus `Jelly/Resources/Licenses/`), Hinweise zu IMDb, TMDB, Rotten Tomatoes und Jellyfin sowie **Datenschutz**.
- Privacy Manifests für App und Top Shelf (`PrivacyInfo.xcprivacy`): kein Tracking, keine erfassten Daten, Begründungen für UserDefaults (CA92.1), Datei-Metadaten (C617.1) und freien Speicherplatz für den Zwischenspeicher der Engine (E174.1) – ermittelt aus den Symbolen der fertigen App und ihrer Frameworks.
- Debug-Hilfen (`JELLY_*`) sind nur in Debug-Builds enthalten.

## 6. Mögliche Rückfragen in der Prüfung

- **„Erkunden“ (Jellyseerr):** Apple prüft Apps, die Inhalte „besorgen“, streng. Jellyseerr ist eine Wunschliste für den eigenen Server – so ist es in den Review-Hinweisen beschrieben. Falls Apple nachfragt: erklären, nicht verstecken.
- **App Transport Security** (`NSAllowsArbitraryLoads`): begründet in den Review-Hinweisen (Server im Heimnetz per HTTP).
- **Marken:** Jellyfin, Dolby, IMDb und Rotten Tomatoes werden nur beschreibend genannt; die App sagt ausdrücklich, dass sie kein offizielles Jellyfin-Produkt ist.
