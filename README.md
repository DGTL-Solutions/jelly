# Jelly für Apple TV

Nativer Jellyfin-Client für tvOS 18+, komplett in SwiftUI. Spielt die Originaldateien ab – Video wird nie vom Server neu kodiert.

## Starten

1. `Jelly.xcodeproj` in Xcode öffnen und Swift-Pakete auflösen lassen.
2. Scheme **Jelly**, Ziel Apple TV oder tvOS-Simulator.
3. Für ein echtes Gerät unter *Signing & Capabilities* das eigene Team und eine eindeutige Bundle-ID eintragen.

### Auf das Apple TV installieren – nur Terminal

Für einen Mac ohne Bildschirm: Das Skript baut, erstellt Bundle-ID und tvOS-Entwicklungsprofil über die App-Store-Connect-API, signiert mit [`rcodesign`](https://github.com/indygreg/apple-platform-rs) (kein Schlüsselbund nötig) und installiert per `devicectl` auf dem gekoppelten Apple TV.

```sh
ASC_KEY_ID=<Key-ID> ASC_ISSUER_ID=<Issuer-ID> SIGNING_CERT_DIR=<Ordner mit dev.key + dev.pem> Scripts/install-appletv.sh
```

Der API-Schlüssel braucht die Rolle Admin (App-IDs anlegen). Ohne `ASC_KEY_ID` signiert das Skript stattdessen mit der in Xcode angemeldeten Apple-ID.

Nach Änderungen an `project.yml`: `xcodegen generate`. App-Icon und Top-Shelf neu erzeugen: `xcrun swift Scripts/GenerateArtwork.swift`.

## Anmeldung

- **Server finden ohne Tippen:** UDP-Discovery (Port 7359) plus Scan des lokalen /24-Netzes auf Port 8096. Meldet ein Docker-Server eine interne Adresse, wird die echte IP genutzt. Zuletzt genutzte Server stehen oben.
- **Adresse eingeben** genügt als `192.168.1.20`, `jellyfin.example.com` oder kopierter Web-Link – Protokoll und Port werden automatisch durchprobiert.
- **Profile** mit Avataren, sofern der Server sie zeigt; Konten ohne Passwort melden sich mit einem Klick an.
- **Mit Code anmelden** (Quick Connect): Code in der Jellyfin-App auf dem Handy bestätigen.
- **Mehrere Server und Profile** auf einem Apple TV: Einstellungen › Server listet alle verbundenen Server (Adresse, Version, Anzahl Profile); ein Klick wechselt zum dort zuletzt genutzten Profil, „Server hinzufügen" verbindet einen weiteren. Darunter die Profile des aktiven Servers mit Hinzufügen und Abmelden. „Wer schaut gerade?" beim Start zeigt bei mehreren Servern den Server unter jedem Profil. Beim Wechsel werden alle Tabs frisch aufgebaut. Tokens liegen im Schlüsselbund.
- **Heimnetz automatisch:** Ist derselbe Server (gleiche Server-ID) im lokalen Netz erreichbar, spricht die App ihn direkt an statt über Internet/Proxy.

## Bibliothek

- Startseite mit Titel-Karussell, Weiterschauen, Nächste Folgen, Neu in …, Favoriten, Sammlungen, Playlists und Bibliotheken; „Weiterschauen" auch im Top Shelf.
- **Bewertungen** auf Detailseiten und im Karussell, einzeln abschaltbar (Einstellungen › Bewertungen): IMDb aus IMDbs öffentlichem Bewertungs-Datensatz (für private Nutzung frei, wöchentlich geladen, Zuordnung über die IMDb-ID des Servers) und Rotten Tomatoes aus den Kritikerwerten des Servers.
- **Bildschirmschoner „Cover-Wand"** wie bei iTunes: Nach einstellbarer Zeit ohne Eingabe im Menü füllen die Cover den Bildschirm und drehen sich nacheinander um. Jeder Tastendruck beendet ihn; nach einer Stunde übernimmt der Ruhezustand des Apple TV.

## Wiedergabe

Jede Datei läuft als Original: [AetherEngine](https://github.com/superuser404notfound/AetherEngine) öffnet sie auf dem Apple TV, verpackt H.264 und HEVC dort selbst für Apples Player um und decodiert alles andere mit eigenen Decodern. Der Server muss dafür nichts tun; Video wird nie neu kodiert.

| Datei | Weg | Ergebnis |
| --- | --- | --- |
| H.264/HEVC in MKV, MP4, TS … | AetherEngine verpackt auf dem Apple TV in fMP4 um, Apple-Player | Dolby Vision (Profil 5, 8; Profil 7 als 8.1), HDR10+, HDR10, HLG, Bildrate passend |
| E-AC-3 mit Atmos, AC-3, AAC, FLAC | Ton 1:1 kopiert | Dolby Atmos als Bitstream |
| TrueHD, DTS, DTS-HD MA, PCM … | verlustfrei als FLAC an Apples Player | Mehrkanal-PCM am Receiver (an Stereo-Ausgängen Dolby Digital+) |
| AV1 ohne AV1-Hardware, VP9, VC-1, MPEG-2, MPEG-4 … | Software-Decoder der Engine (dav1d, FFmpeg) | HDR10, HLG |

- Der Server packt nur noch, um Bandbreite zu sparen: „nur gewählte Tonspur“ (verlustfrei) oder eine Bitrate-Grenze bei zu langsamer Leitung. Taucht dabei ohne Grenze ein Grund auf, der das Video beträfe, spielt Jelly das Original. Scheitert Apples Player an einem Server-Stream, geht es mit dem Original weiter.
- Bild-Untertitel (PGS, VobSub, DVB) und Text-Untertitel zeigt Jelly auf jedem Weg; nur bei Server-Streams wechselt es für Bild-Untertitel an derselben Stelle zur Originaldatei.
- **ASS/SSA** rendert libass mit den in der MKV eingebetteten Schriften – Positionen, Effekte und Karaoke wie gestaltet.
- Bildwiederholrate und Dynamikbereich folgen dem Inhalt, wenn auf dem Apple TV *Einstellungen › Video und Audio › Inhalt anpassen* aktiv ist.
- Tonspur und Untertitel: zuletzt in der Serie gewählte Sprache, sonst Jellyfins Profileinstellung, sonst die Sprache des Apple TV.
- **Intro überspringen:** Liefert der Server Media Segments (Jellyfin 10.10+ mit Intro-Skipper-Plugin), nutzt Jelly diese. Sonst erkennt Jelly Intros selbst: Der Server wandelt nur den Ton des ersten Viertels einer Folge (höchstens 10 min) in ein kleines Mono-MP3 um, Jelly bildet daraus Audio-Fingerabdrücke (Haitsma & Kalker, alle 23 ms) und sucht die längste Strecke, die eine Nachbarfolge derselben Staffel ebenfalls enthält (15 s bis 3 min). Ergebnis und Fingerabdrücke werden gespeichert; beim Abspielen wird die nächste Folge vorbereitet, auf der Detailseite die Folge hinter dem Abspielknopf. Kapitel namens „Intro" dienen bis dahin als Notlösung (nur im ersten Drittel). Einstellbar: Intros automatisch überspringen.
- **Abspann:** über Media Segments, Kapitel namens „Credits" oder per Ton-Vergleich der letzten Minuten zweier Folgen. Letzteres greift nur bei Serien, deren Abspann in jeder Folge gleich klingt, und nur, wenn er bis ans Ende reicht – eine Szene nach dem Abspann wird nie abgeschnitten. Sonst erscheint „Nächste Folge" am Ende. Nächste Folge startet nach 10 s Countdown.
- **Nächste Folge vorbereitet:** Kurz vor dem Abspann holt Jelly Details und Stream-Infos der nächsten Folge (und misst bei großen Dateien die Leitung, solange genug Puffer da ist), damit sie sofort startet.
- **Unterbrechungen:** TV-Taste oder Ruhezustand pausieren und melden die genaue Position an Jellyfin; zurück in Jelly steht der Film pausiert an derselben Sekunde. Bricht die Verbindung mitten im Film ab oder hängt der Puffer länger als 20 s, verbindet Jelly bis zu dreimal mit wachsenden Pausen neu und spielt an derselben Sekunde weiter; erst dann kommt eine Fehlermeldung. Pufferpausen direkt nach einem Sprung zählen nicht als Hänger.
- **Leitung bricht mitten im Film ein:** Nach zwei Hängern innerhalb von fünf Minuten wählt Jelly selbst eine passende Qualität – anhand der Rate, mit der die Engine beim Nachladen tatsächlich Daten vom Server bekommt – und spielt an derselben Sekunde weiter. Nur bei „anpassen", nie nach einer eigenen Wahl im Qualität-Reiter.
- **Leitung wieder schnell:** Hat Jelly die Qualität selbst gesenkt (beim Start oder mitten im Film) und trägt die Leitung danach fünf Minuten lang ohne Hänger deutlich mehr (langsamste Sekunde zählt, mindestens das 1,5-Fache), schaltet Jelly wieder hoch – aber nur an einer ruhigen Stelle: beim nächsten Sprung (Spulen, ±10 s, Intro überspringen, Kapitel), wenn der Film mindestens 3 s pausiert (er bleibt dabei pausiert) oder zu Beginn des nächsten Kapitels; nicht in den letzten zehn Minuten. Muss Jelly danach wieder herunterschalten, wartet es beim nächsten Mal doppelt so lange. Die beim Film beobachtete Leitung gilt auch für den Start des nächsten Films.
- **Startbildschirm sofort:** Die zuletzt geladenen Reihen erscheinen beim Start direkt von der Festplatte (pro Profil) und werden im Hintergrund aufgefrischt.
- **Langsame Leitung:** Vor großen Dateien (über 15 Mbit/s) von einem Server außerhalb des Heimnetzes misst die App 4 s lang den echten Durchsatz (30 min gemerkt). Reicht er nicht, lässt sie zuerst ungenutzte Tonspuren weg (verlustfrei) und lässt erst dann den Server auf etwa 70 % der Leitung herunterrechnen. Jellyfins eigene „im Netzwerk"-Angabe ist hinter Reverse-Proxys unzuverlässig und wird nicht benutzt. Einstellbar unter Einstellungen › Langsame Verbindung, im Player unter ↓ › Qualität.
- **Verbindungsanalyse** (Einstellungen › Verbindung): prüft Erreichbarkeit und Antwortzeit des Servers, HTTPS und Proxy (z. B. Cloudflare), ob der Weg übers Heimnetz oder Internet führt und ob das Apple TV per LAN oder WLAN hängt, misst 8 s lang den Durchsatz an der größten Datei, rechnet aus, welcher Anteil der Bibliothek im Original läuft, testet bei Bedarf, wie schnell der Server umrechnet (und ob HDR erhalten bleibt), und zeigt, was Apple TV und Fernseher können. Jede Messung (auch die automatischen vor großen Filmen) wird gespeichert, daraus entsteht eine Übersicht nach Tageszeit. Am Ende stehen konkrete Tipps.
- Fortschritt, Pause, Tonspur, Untertitel und Wiedergabeart gehen an Jellyfin; „Weiterschauen" und „Nächste Folgen" erscheinen auch im Top Shelf des Apple-TV-Home-Bildschirms.

## Erkunden (Jellyseerr)

Tab „Erkunden": Filme und Serien, die noch nicht auf dem Server sind – „Gerade angesagt", beliebte und bald erscheinende Filme und Serien, „Deine Wünsche" und ganz oben eine Suchleiste für alle Filme und Serien, auch die noch nicht auf dem Server sind (der Fokus startet dort). Karten zeigen den Stand in Jellyseerr (in der Bibliothek, gewünscht, wird geladen, teilweise da) und bei laufenden Downloads einen Balken mit Prozent und Restzeit. Die Reihe „Wird geladen“ sammelt freigegebene Wünsche, die noch unterwegs sind (bei Admins des ganzen Haushalts, sonst die eigenen): laufend, in der Warteschlange, pausiert, beim Importieren oder noch ohne gefundenen Download. Die Detailseite zeigt Fortschritt, Restzeit und ungefähre Uhrzeit, bei Serien auch die einzelnen Folgen. Solange etwas lädt, fragt Jelly alle 30 Sekunden nach – Jellyseerr holt den Stand jede Minute bei Radarr und Sonarr. Die Detailseite wünscht Filme mit einem Klick, bei Serien wählt man die fehlenden Staffeln; was schon da ist, öffnet „Ansehen" direkt in der Bibliothek.

- **Automatisch verbunden:** Meldet man sich in Jelly mit Benutzername und Passwort (oder per Klick auf ein Profil ohne Passwort) bei Jellyfin an, meldet Jelly dasselbe Konto gleich auch beim Jellyseerr daneben an – das Passwort wird dafür einmal benutzt und nicht gespeichert. Nur wenn der Jellyseerr nachweislich zu diesem Jellyfin gehört: Er läuft auf demselben Rechner, oder in seinen Einstellungen ist genau diese Jellyfin-Adresse eingetragen (eine geratene Nachbaradresse wie `jellyseerr.synology.me` kann einem Fremden gehören). Nie bei Konten mit begrenzten gleichzeitigen Anmeldungen, weil Jellyseerrs Prüfung dort dauerhaft eine davon belegt. Bei Quick Connect und bei schon gespeicherten Profilen kennt Jelly kein Passwort; dort bleibt „Jellyseerr verbinden".
- Ohne Verbindung zeigt der Tab nur „Verbinde deinen Jellyseerr-Server" mit Erklärung.
- Die Adresse findet Jelly meist selbst: neben `jellyfin.example.com` werden `jellyseerr.`, `seerr.`, `requests.` usw. und Port 5055 auf demselben Rechner probiert.
- Anmeldung mit dem Jellyfin-Konto (Benutzername vorausgefüllt) oder einem Jellyseerr-Konto per E-Mail. Jelly speichert nur die Sitzung im Schlüsselbund, pro Profil; „Jellyseerr trennen" unter Einstellungen.
- Jellyseerr meldet sich zur Prüfung selbst bei Jellyfin an und belegt dort eine Sitzung, bis der Jellyfin-Server neu startet. Bei Konten mit begrenzten gleichzeitigen Anmeldungen kann das Verbinden deshalb scheitern; Jelly erklärt das dann.

## Bedienung im Player (Siri Remote)

| Taste | Aktion |
| --- | --- |
| Klick / Play-Pause | Pause und weiter; beim Spulen springen; bei eingeblendetem Hinweis Intro überspringen bzw. nächste Folge |
| Links / Rechts (Rand klicken) | −10 s / +10 s, mehrfaches Drücken wird addiert |
| Wischen auf dem Touchpad (pausiert) | Stufenlos spulen mit Zeit- und (wenn vom Server erzeugt) Bildvorschau |
| Nach unten | Panel: Untertitel (mit Größe, Hintergrund, Farbe), Audio (mit Ausgabeformat), Kapitel, Synchronisation, Info |
| Nach oben | Steuerleiste einblenden |
| Zurück | Panel schließen → Spulen abbrechen → Steuerleiste ausblenden → Player verlassen |

Vorschaubilder beim Spulen kommen aus Jellyfins Trickplay-Funktion (Dashboard › Bibliotheken › Trickplay-Bilder extrahieren).

## Prüfen

```sh
# Kernlogik ohne tvOS-Runtime
xcrun swiftc -parse-as-library Jelly/Core/Models.swift Jelly/Core/JellyfinClient.swift Jelly/Core/PlaybackSupport.swift \
  Jelly/Core/ServerDiscovery.swift Jelly/Core/IMDbRatings.swift Jelly/Core/NetworkProbe.swift Jelly/Core/Diagnostics.swift Jelly/Core/IntroDetector.swift Jelly/Core/Seerr.swift Jelly/Core/Access.swift Scripts/CoreChecks.swift -o /tmp/jelly-core-checks && /tmp/jelly-core-checks

# Gerätebuild ohne Signierung
xcodebuild -project Jelly.xcodeproj -scheme Jelly -configuration Release -destination 'generic/platform=tvOS' CODE_SIGNING_ALLOWED=NO build
```

**Auf dem Fernseher:** Einstellungen › Diagnose › Diagnose-Overlay zeigt im Player live Weg, Datei, tatsächliches Ausgabe-Bild und -Ton, ankommende Datenrate, gemessene Leitung, Bedarf, Puffer, Hänger, verlorene Bilder und A/V-Sync samt Klartext-Urteil. Dort gibt es auch das Protokoll; die ausführliche Verbindungsanalyse liegt unter Einstellungen › Verbindung.

Diagnose-Protokoll per Terminal vom Apple TV holen (Gerätefähigkeiten, gewählter Wiedergabeweg, Messungen, Hänger, verlorene Bilder alle 30 s):

```sh
xcrun devicectl device copy from --device <UDID> --domain-type appDataContainer --domain-identifier net.dgtl24.jelly \
  --source Library/Caches/jelly-diagnostics.log --destination jelly-diagnostics.log
```

Fernbedienung im Simulator ohne Simulator.app: `Scripts/simhid.m` schickt Tastendrücke über SimulatorKit (Pfeile = Touchpad-Richtungen, `select`, `menu`, `playpause`, `type:dune` tippt in Suchfelder):

```sh
clang -fobjc-arc -framework Foundation Scripts/simhid.m -o /tmp/simhid
/tmp/simhid <Simulator-UDID> down down select menu
```

XCTests (`JellyTests`) über Product › Test in Xcode. Für Simulator-Builds mit Schlüsselbund ad hoc signieren (`CODE_SIGN_IDENTITY=-`), sonst bleibt die Anmeldung nur bis zum Neustart erhalten.

Nur in Debug-Builds steuern Startparameter (`SIMCTL_CHILD_…` bei `simctl launch`) die App für Tests: `JELLY_SERVER`/`JELLY_USER`/`JELLY_PASSWORD` (Auto-Login), `JELLY_TAB`, `JELLY_OPEN`/`JELLY_PLAY` (Item-ID), `JELLY_PANEL` (optional Reiter), `JELLY_CONTROLS`, `JELLY_SCRUB` (Sekunden), `JELLY_SUBTITLE` (Index oder `ass`), `JELLY_FROM_END`, `JELLY_START` (Startposition in Sekunden), `JELLY_PLAN` (`compact`: Server-Stream mit nur der gewählten Tonspur), `JELLY_LIMIT` (Mbit/s, startet wie von Jelly heruntergeregelt), `JELLY_UPGRADE_WAIT` (Sekunden bis zum Hochschalten statt 300), `JELLY_SCROLL_EPISODES`, `JELLY_SCREENSAVER`, `JELLY_ANALYSIS` (`1` startet die Verbindungsanalyse, `end` scrollt danach ans Ende), `JELLY_SIGN_OUT`, `JELLY_SECOND_SERVER` (Kopie des Kontos als zweiter Server „Testserver“), `JELLY_SEERR_PASSWORD` (meldet die Jellyseerr-Seite automatisch an), `JELLY_SEERR_SERVER` (öffnet „Erkunden“ direkt mit dieser Jellyseerr-Adresse, z. B. dem Test-Jellyseerr `Scripts/seerr-mock.py` auf `http://127.0.0.1:15055` mit Wünschen und laufenden Downloads), `JELLY_SEERR_AUTO` (erlaubt die automatische Jellyseerr-Anmeldung nach dem Login; ohne ihn lassen Debug-Builds sie aus, damit Testläufe keine Sitzung auf fremden Servern belegen). Im Simulator meldet der Player keinen Fortschritt an den Server, damit Tests die „Weiterschauen“-Positionen des Kontos nicht überschreiben; `JELLY_REPORT=1` schaltet das wieder ein.

## App Store

Die App-Store-Fassung wird mit einem Jahresabo freigeschaltet: 9,99 € pro Jahr, die ersten 2 Wochen gratis (StoreKit 2, `Jelly/Core/Purchases.swift`, Angebot mit allen Pflichtangaben für Abos in `PaywallView`). Kaufsperre und IMDb-freie Bewertungen gibt es nur mit dem Build-Schalter `APPSTORE`, den `Scripts/release-appstore.sh` setzt; Builds aus dem Quellcode laufen ohne Sperre. Zum Testen der Oberfläche in Debug-Builds: `JELLY_ACCESS=none|trial|active|expired`.

Vorbereitung der Veröffentlichung – Lizenzen (AetherEngine und FFmpeg unter LGPL, ohne Lizenzkosten), Store-Texte, Review-Hinweise, Datenschutzerklärung und Upload-Skript (`Scripts/release-appstore.sh`): siehe [`AppStore/README.md`](AppStore/README.md). In der App: Einstellungen › Info › Open-Source-Lizenzen und Datenschutz.

## Sprachen

Jelly ist auf Deutsch und Englisch und folgt der Sprache des Apple TV; jede andere Sprache bekommt Englisch. Deutsch ist die Ausgangssprache: Die Texte stehen deutsch im Code (`Text("…")`, `String(localized: "…")`), die englischen Übersetzungen in `Jelly/Localizable.xcstrings` und `JellyTopShelf/Localizable.xcstrings` (Mehrzahl als Plural-Varianten), die Info.plist-Texte in den `InfoPlist.xcstrings`. Neue oder geänderte Texte holt man so heraus und wieder hinein:

```sh
xcodebuild -exportLocalizations -project Jelly.xcodeproj -scheme Jelly -localizationPath /tmp/jelly-loc -exportLanguage en \
  -derivedDataPath .build/loc -sdk appletvsimulator CODE_SIGN_IDENTITY=- EXCLUDED_ARCHS=x86_64
# en.xliff übersetzen, dann:
xcodebuild -importLocalizations -project Jelly.xcodeproj -localizationPath /tmp/jelly-loc/en.xcloc
```

Im Simulator testet man eine Sprache mit `xcrun simctl launch <UDID> de.jelly.tv -AppleLanguages "(en)" -AppleLocale en_US`. Das statische Top-Shelf-Bild enthält bewusst keinen Satz, weil es nicht sprachabhängig sein kann.

## Grenzen

- tvOS gibt TrueHD und DTS nie als Bitstream aus: Atmos aus TrueHD und DTS:X kommen als verlustfreies Mehrkanal-PCM ohne Objekte an. AetherEngine könnte die Objekte über optionale Paket-Traits als Apple Positional Audio ausgeben; XcodeGen kann diese Traits noch nicht setzen.
- Dolby Vision Profil 7 (UHD-Blu-ray) läuft als Profil 8.1, die Erweiterungsebene (FEL) entfällt dabei. Ohne Dolby-Vision-Decoder (Simulator, Apple TV HD) läuft die HDR10-Basis.
- AV1 decodiert ohne AV1-Hardware in Software (dav1d); ob 4K-AV1 flüssig läuft, zeigt die Diagnose (`perf … dropped`).
- Beim ersten Laden extrahiert der Server eingebettete Untertitel aus der ganzen Datei; das kann bei großen Dateien dauern (die App zeigt einen Hinweis).
- Musik und Live-TV sind nicht umgesetzt (auf dem Testserver nicht vorhanden).

## Lizenz

Jellys eigener Code steht unter der [Mozilla Public License 2.0](LICENSE) – © 2026 DGTL Solutions GmbH. Die eingebundenen Bibliotheken behalten ihre Lizenzen: AetherEngine (LGPL-3.0 mit App-Store-Ausnahme), FFmpeg mit dav1d, zimg und ZVBI (LGPL-2.1 ohne GPL-Teile, als dynamische Frameworks), libdovi (MIT), libass mit FreeType, HarfBuzz, FriBidi und libunibreak. Alle Texte stehen in `Jelly/Resources/Licenses/` und in der App unter Einstellungen › Info › Open-Source-Lizenzen. Weil Jellys Quellcode offen ist, lässt sich die App auch mit geänderten Fassungen der statisch gelinkten LGPL-Bibliotheken (FriBidi in libass) neu bauen, wie die LGPL es verlangt.

## Quellen

- [AetherEngine](https://github.com/superuser404notfound/AetherEngine) · [FFmpegBuild](https://github.com/superuser404notfound/FFmpegBuild) · [libass-build](https://github.com/mpvkit/libass-build)
- [Jellyfin-Wiedergabemodi](https://jellyfin.org/docs/general/post-install/transcoding/)
- [Jellyfin PlaybackInfo API](https://typescript-sdk.jellyfin.org/interfaces/generated-client.MediaInfoApiGetPostedPlaybackInfoRequest.html)
