# Jelly bekannt machen – fertige Texte

Stand 3.11.2026, für Version 1.1. Alles hier postet oder sendet man selbst, mit dem eigenen Konto. Überall offen sagen,
dass man Jelly selbst gebaut hat – die Communities (vor allem r/selfhosted) entfernen versteckte Werbung.

Links: App Store https://apps.apple.com/app/id6826379119 · Quellcode https://github.com/DGTL-Solutions/jelly

## 1. Reddit r/jellyfin

**Titel:** I built Jelly, a native Jellyfin client for Apple TV, iPhone and iPad that plays your files in original quality

**Text:**

Hi all – I'm the developer of Jelly, a Jellyfin client written fully in SwiftUI. I built it because I wanted my
remuxes to play on the Apple TV exactly as they are, without my server transcoding anything.

What it does:

- Plays the original file on the device: MKV, MP4, TS with H.264, HEVC, AV1, VC-1, MPEG-2. Dolby Vision (profiles 5/8,
  profile 7 as 8.1), HDR10+, Atmos in DD+ as bitstream, TrueHD/DTS-HD as lossless multichannel PCM.
- ASS/SSA subtitles rendered with libass and the fonts embedded in the MKV, plus PGS/VobSub.
- Skips intros and credits even without the Intro Skipper plugin (it compares the audio of neighbouring episodes).
- New in 1.1: downloads on iPhone/iPad in Original, Better (1080p) or Good (720p), with offline playback; positions
  watched offline sync back to the server.
- Jellyseerr built in, Quick Connect, several servers and profiles, Top Shelf.

It's free to download with a 2-week trial, then €9.99/year for all devices (one subscription covers Apple TV, iPhone
and iPad). No ads, no tracking – the app only talks to your own servers. The source is open (MPL-2.0).

App Store: https://apps.apple.com/app/id6826379119 – I'd love feedback, bug reports and feature wishes.

*Screenshots anhängen: AppStore/screenshots/en-US/2-details.png, 4-info.png und AppStore/screenshots-ios/en-US/iphone/3-player.png.*

## 2. Reddit r/appletv

**Titel:** Jelly – a Jellyfin player for Apple TV with Dolby Vision, Atmos and properly styled subtitles

**Text:**

If you run a Jellyfin server at home: I made Jelly, an Apple TV app that plays your library in original quality –
Dolby Vision and HDR10+ through Apple's player with match content, Atmos (DD+) as bitstream to your receiver, lossless
TrueHD/DTS-HD, and ASS subtitles exactly as they were authored. Continue Watching sits in the Top Shelf, and there's a
cover-wall screensaver like the old iTunes one.

Same subscription works on iPhone and iPad, where 1.1 adds offline downloads. Two weeks free to try.
I'm the developer – happy to answer questions. https://apps.apple.com/app/id6826379119

## 3. Reddit r/selfhosted

**Titel:** Jelly: native Jellyfin client for Apple devices that never makes your server transcode video

**Text:**

Developer here. Jelly is a SwiftUI client for Jellyfin on Apple TV, iPhone and iPad. The point: your server stays idle.
The app opens the original file itself (FFmpeg-based engine on the device), so even a small NAS can serve 4K remuxes.
On slow connections it first asks the server to drop unused audio tracks (lossless remux) and only converts the
picture if that still doesn't fit. Jellyseerr is built in, and it learns your server's LAN address so it skips your
reverse proxy at home.

Open source (MPL-2.0): https://github.com/DGTL-Solutions/jelly · App Store (2 weeks free, then €9.99/year for all
devices): https://apps.apple.com/app/id6826379119

## 4. Jellyfin-Forum (forum.jellyfin.org › Third Party Apps)

**Titel:** Jelly – native client for Apple TV, iPhone and iPad (original quality, offline downloads)

Text wie bei r/jellyfin, dazu am Ende: „Known limits: TrueHD Atmos and DTS:X objects are played as lossless
multichannel PCM, music and Live TV aren't there yet.“

## 5. Apple: Feature-Vorschlag (App Store Connect › App › Featuring › Nominations)

Am besten 4–8 Wochen vor dem gewünschten Termin; für Version 1.1 also sofort einreichen und als Zeitraum „nach
Freigabe“ angeben.

- **Nominierungstyp:** App Enhancements (Update 1.1)
- **Name:** Jelly 1.1 – offline downloads and six languages
- **Beschreibung (en):** Jelly is a native SwiftUI player for people who run their own Jellyfin media server. It plays
  every file in its original quality on Apple TV, iPhone and iPad – Dolby Vision and HDR10+ through AVKit with match
  content, Dolby Atmos as bitstream, ASS subtitles with their embedded fonts – so the home server never has to
  transcode. Version 1.1 adds downloads in three qualities with a recommendation for the device and the free space,
  full offline playback with skip intro and next episode, and positions that sync back once the server is reachable.
  Jelly is now available in German, English, French, Spanish, Italian and Dutch.
- **Was es besonders macht:** Built entirely with SwiftUI, AVKit, Picture in Picture, Top Shelf, StoreKit 2; one
  subscription across tvOS, iOS and iPadOS; no ads, no tracking, no data collection.
- **Länder:** alle, Schwerpunkt Deutschland, Frankreich, USA, Schweiz, Niederlande.

## 6. YouTuber anschreiben

Kanäle mit Jellyfin-, NAS- und Apple-TV-Setups (z. B. Videos zu „Jellyfin Apple TV“, „Infuse alternative“, „Home
server 2026“). Dafür braucht es Aktionscodes (App Store Connect › Abos › Jelly Jahresabo › Angebotscodes), z. B.
„1 Jahr gratis“, einmalig nutzbar.

**Betreff:** Jelly – a Jellyfin player for Apple TV & iPhone (free year for you to try)

Hi <Name>, I enjoyed your video on <Thema>. I'm the developer of Jelly, a native Jellyfin client for Apple TV, iPhone
and iPad that plays files in original quality (Dolby Vision, Atmos, ASS subtitles) so the server never transcodes, and
since 1.1 has offline downloads on iPhone and iPad. If it's useful for a future video, here's a code for a free year:
<Code>. No strings attached – I'd simply be glad about honest feedback. Best, <Name>

## 7. Was danach zu beobachten ist

Im Bericht „App Store Discovery and Engagement“: Einblendungen und Seitenaufrufe pro Land (Frankreich, Spanien,
Italien, Niederlande nach der Lokalisierung), im Abo-Bericht der Anteil der Testabos an den Erstdownloads (bis 1.0:
etwa 13 %).
