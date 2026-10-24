# iPhone/iPad app – handoff to the MacBook Pro

The Mac mini was overloaded by four agents with simulators running at once, so the remaining iOS work moves to the
MacBook Pro (M5 Pro, 64 GB). This branch (`ios-app`) holds the unfinished work of the four packages as a WIP commit:
nothing here has been reviewed, and it may not build yet. Merge into `main` only after the iOS and tvOS builds are clean
and the screenshots have been reviewed; delete this file before merging.

## Setup on the MacBook
- Xcode 27.1 with the iOS 27 and tvOS 27 simulators, XcodeGen (`brew install xcodegen`), then `xcodegen generate`.
- Simulator builds need no signing (`CODE_SIGN_IDENTITY=-`). Signing keys, App Store Connect API key and the upload
  scripts stay on the Mac mini; uploads and App Store Connect changes are done there.
- Python scripts that parse XML need `/usr/bin/python3`.

## State per package (WIP commit on this branch)
- LIBRARY – `JellyMobile/Library/LibraryScreens.swift` (≈1,700 lines): Home, Library grid, Search, Item detail, Person.
- PLAYER – `JellyMobile/Player/` (Screen, Controls, Overlays, Panel, System): touch player, PiP, Now Playing.
- ACCOUNT – `JellyMobile/Account/` (AccountScreens, OnboardingFlow, SettingsScreen, MobilePaywall, AboutScreens) and the
  shared `Jelly/Shared/AboutData.swift` split out of `Jelly/Views/AboutViews.swift`.
- DISCOVER – `JellyMobile/Discover/DiscoverScreens.swift` (≈1,200 lines): Jellyseerr discover, search, downloads, connect sheet.
Each package was stopped mid-work: first get every package building, then check each against its brief below.

## After the packages
1. Integrate, build iOS and tvOS clean, review screenshots on iPhone and iPad in German and English.
2. Translate new strings: `xcodebuild -exportLocalizations` → fill English → `-importLocalizations`.
3. Store screenshots iPhone 6.9" and iPad 13" with demo-server content (Discover with `Scripts/seerr-mock.py`),
   built with `SWIFT_ACTIVE_COMPILATION_CONDITIONS='DEBUG APPSTORE'`.
4. Then on the Mac mini: add the iOS platform to the App Store record (same bundle ID, universal purchase).

## Shared brief (given to every package)


Project: the repository root
Jelly is a native Jellyfin client. The Apple TV app (tvOS, folder Jelly/) is finished and in App Store review prep.
We are adding an iPhone and iPad app (target JellyMobile, folder JellyMobile/, iOS 18 deployment, Xcode 27.1 / iOS 27 SDK).
Goal: an *excellent*, native-feeling iOS/iPadOS app – the quality bar is Apple's TV app and Infuse: clean SwiftUI,
dark theme, Theme.accent tint, smooth animations, proper iPad layouts (wider grids, more columns, split layouts),
Dynamic Type friendly, VoiceOver labels on icon-only buttons, haptics where it helps. No placeholder-looking UI.

## What exists (read, don't edit unless your package says so)
- Jelly/Core/*: AppModel (session, accounts, servers, play(), playSeries(), setWatched, setFavorite, seerr account,
  purchases, showsPaywall, pendingOpen, refreshID, contentChanged()), JellyfinClient (views, resume, nextUp, latest,
  items(ItemQuery), item, seasons, episodes, similar, setPlayed, setFavorite, imageURL, artworkURL(item, .poster/.landscape/
  .backdrop, width:), logoURL, publicUsers, authenticate, quickConnect*, playbackInfo …), Models (BaseItem with progress,
  episodeLabel, runtimeText, remainingText, metadataLine, subtitleLine, isWatched, isFavorite, isSeries, isEpisode, isMovie,
  isPlayable, isFolder, people, mediaSources …), Seerr (SeerrClient, SeerrStatus, DownloadProgress), Purchases/Access,
  PlaybackSupport (SubtitleSize/Background/Color, EnginePreference, SlowConnectionPolicy, TechInfo badges), ServerDiscovery.
- Jelly/Shared/*: Theme, ImagePipeline, RemoteImage(url:), RatingBadges(item:), TomatoIcon, SubtitleOverlay, DisplayCapabilities.
- Jelly/Player/PlayerController.swift: the playback engine wrapper (start, stop, togglePlayPause, seek, pause, selectAudio,
  selectSubtitle, selectQuality, setAudioDelay/SubtitleDelay, thumbnail(at:), intro, creditsStart, nextEpisode, chapters,
  audioOptions/subtitleOptions/qualityOptions, phase, position, duration, isPlaying, isBuffering, notice, aether: AetherEngine).
- JellyMobile/JellyMobileApp.swift (root, tabs – sidebar on iPad), JellyMobile/MobileComponents.swift (MobileRoute,
  MobileBrowseStack, @Environment(\.openMobileItem), ArtworkImage, WatchProgressBar, PosterCard, WideCard,
  MobileItemActions, ShelfSection, MobileLoadingView, MobileErrorView). You may use these; if you need a change there,
  describe it in your report instead of editing (another package may use them concurrently).
- The tvOS views in Jelly/Views, Jelly/Player/PlayerView.swift, Jelly/UI are the reference implementation of behaviour
  (what to load, which texts, edge cases). Port the behaviour and wording, not the tvOS layout/focus code.

## Rules
- Edit only the files of your package (listed in your task). Replace the placeholder file(s) you own; add new files only
  inside your package folder. Never commit, never run git commands that change state.
- Localization: German is the source language. Literals in Text/Label/Button/Toggle/Section/navigationTitle/Picker/
  TextField/ContentUnavailableView are localized automatically; every other visible String must be
  String(localized: "…") (interpolation allowed, add comment: for short/ambiguous words). Reuse the exact German wording
  the tvOS app already uses for the same thing (it is already translated to English), e.g. "Weiterschauen",
  "Nächste Folgen", "Abspielen", "Fortsetzen", "Von vorn", "Untertitel", "Wird geladen …".
- Build check (use YOUR derived data path so packages don't clash):
  xcodebuild -project Jelly.xcodeproj -scheme JellyMobile -configuration Debug \
    -destination 'platform=iOS Simulator,name=<YOUR SIMULATOR>' -derivedDataPath .build/ios-<package> \
    -clonedSourcePackagesDirPath .build/ios/SourcePackages CODE_SIGN_IDENTITY=- build 2>&1 | grep -E "error:|BUILD"
  If your package touches shared code (Jelly/…), also build tvOS: -scheme Jelly -destination 'platform=tvOS Simulator,name=Jelly Test'
  -derivedDataPath .build/sim-<package>.
- Testing in the simulator (your own simulator only): boot it, install
  .build/ios-<package>/Build/Products/Debug-iphonesimulator/Jelly.app, launch bundle id de.jelly.tv with
  SIMCTL_CHILD_JELLY_SERVER=demo.jellyfin.org/stable SIMCTL_CHILD_JELLY_USER=demo (debug auto-login to the public demo
  server; never sign in to any other server) and SIMCTL_CHILD_JELLY_ACCESS=active (skips the paywall), screenshot with
  xcrun simctl io <udid> screenshot. Add `-AppleLanguages "(en)"` to check English. Look at your screenshots critically.
- Don't break the tvOS target. Don't touch App Store files, scripts, project.yml.

## Report (short)
What you built (screens, notable behaviour), what you verified (build, screenshots), open issues/limits, and any change
you need in shared files.

## Package briefs

### Library

Your package: LIBRARY. Your folder: JellyMobile/Library/ (replace the placeholders in JellyMobile/Library/LibraryScreens.swift; you may split into several files in that folder). Your simulator: "iPhone 17" for phone checks and "iPad Pro 13-inch (M5)" for iPad checks. Derived data: .build/ios-library.

Build these screens (keep the type names and initializers of the placeholders, other code uses them):
- HomeScreen(): like the Apple TV app's home. A large hero carousel of featured items (backdrop, title logo if present via client.logoURL, metadata line, Play/Resume + Details buttons, page dots; swipeable; on iPad wider/taller), then rows: "Weiterschauen" (WideCard; tap plays/resumes, long-press menu), "Nächste Folgen", latest per library ("Neu in <Library>" as the tvOS app titles it), and the libraries themselves. Pull to refresh; reload on model.refreshID. Port the data logic from Jelly/Views/HomeView.swift.
- LibraryScreen(title:types:parentID:personID:) and LibraryScreen(library:): an adaptive grid of PosterCards (more columns on iPad and landscape), large navigation title with the item count, sort and filter menus in the toolbar (port LibrarySort/filters from Jelly/Views/LibraryViews.swift), paging as you scroll, empty and error states.
- SearchScreen(): library search across movies, series and episodes (.searchable, debounce like tvOS), sectioned results, a helpful empty state.
- ItemDetailScreen(item:): load the full item. Stretchy backdrop header with title logo or title, metadata line, RatingBadges, tech badges, overview (expandable), primary Play/Resume button plus "Von vorn", watched and favourite toggles, version choice for multiple media sources. Series: season picker and episode list (stills, episode label, runtime, progress, overview; tap plays; the next-up episode highlighted), "Weiterschauen"/play next episode via model.playSeries. Seasons and episodes open correctly from other places too. Cast & crew row (people with images) opening PersonScreen; similar titles row. On iPad use the extra width (e.g. poster beside the text, two-column episode grid).
- PersonScreen(person:): photo, name, role, and the person's films and series (grid).
Port behaviour and German wording from Jelly/Views/HomeView.swift, LibraryViews.swift, ItemDetailView.swift. Verify on iPhone and iPad with screenshots (demo server), in German and English.

### Player

Your package: PLAYER. Your folder: JellyMobile/Player/ (replace the placeholder JellyMobile/Player/MobilePlayerScreen.swift; add files in that folder). You may ALSO make minimal, clearly guarded changes in Jelly/Player/PlayerController.swift if iOS needs them (wrap in #if os(iOS); tvOS behaviour must stay identical; build both iOS and tvOS). Your simulator: "iPhone 18 Pro" (and "iPad Air 11-inch (M4)" for an iPad check). Derived data: .build/ios-player and .build/sim-player.

Build MobilePlayerScreen(request:client:userID:) – a first-class touch video player, porting the session logic of Jelly/Player/PlayerView.swift (PlaybackScreen: start with preference/audio language, stop + model.contentChanged() on dismiss, scenePhase handling, skip intro (auto-skip setting), up-next with countdown and autoplay setting, notices, preparing view, failure with retry using forceSoftware, next-episode replacement of the request, trickplay thumbnails while scrubbing):
- Video via AetherPlayerSurface(engine:) full screen (black background, ignores safe area), ASSOverlay and SubtitleOverlay (scale the subtitle size to the view: the tvOS sizes are for 1080 pt tall screens).
- Controls overlay that auto-hides: top bar with close (chevron down / xmark), title and episode line, AirPlay route button (AVRoutePickerView in UIViewRepresentable), Picture-in-Picture button if possible; centre: back 10 s, play/pause, forward 10 s; bottom: scrubber (drag to seek with a thumbnail preview and time bubble), elapsed / remaining time, "Ends at" time; a button that opens a sheet/menu for Untertitel, Audio, Qualität, Kapitel, Synchronisation (audio/subtitle delay), Info – reuse the texts of the tvOS panel.
- Gestures: tap toggles controls, double-tap left/right half skips ∓10 s with a brief indicator, pinch toggles fill/fit (aspect), swipe down closes.
- Prefer landscape on iPhone while playing (request the orientation via UIWindowScene.requestGeometryUpdate and restore portrait on close); iPad any orientation. Hide the status bar / home indicator auto-hide.
- Picture in Picture and background: read AetherEngine's README (".build/ios/SourcePackages/checkouts/AetherEngine/README.md", sections on Picture in Picture, background audio, Now Playing) and docs. Implement PiP if the engine allows it on the route in use (native path: AVPictureInPictureController around the engine's player layer / currentAVPlayer; software path: softwarePiPSource sample-buffer PiP). When PiP is active the app may go to background without pausing; otherwise keep today's behaviour (pause and report). Also System Now Playing / lock screen controls if the engine supports it via an option. If something isn't feasible, leave it out cleanly and say so.
- Skip Intro / Abspann buttons, Up Next card, buffering spinner, notices – iOS-styled (materials, capsules).
Verify by playing a demo-server title (e.g. JELLY_PLAY=c002f0f88ee970cce7f138bbc925de64 is "Dracula" on the demo server; the debug env JELLY_PLAY/JELLY_START are handled in AppModel) with screenshots of controls, the options sheet, scrubbing, landscape; German and English.

### Account

Your package: ACCOUNT. Your folder: JellyMobile/Account/ (replace the placeholders in JellyMobile/Account/AccountScreens.swift; add files in that folder). You may ALSO move platform-neutral data out of the tvOS file Jelly/Views/AboutViews.swift into a new shared file Jelly/Shared/AboutData.swift (e.g. AppInfo, OpenSourceComponent, the licence-file loading, the privacy text) so both apps use it – keep the tvOS views working (build tvOS too). Your simulator: "iPad Pro 11-inch (M5)" and "iPhone 17e". Derived data: .build/ios-account and .build/sim-account.

Build:
- OnboardingFlow(): welcome screen with the Jelly mark (port AppMark style: flat play button in Theme.brand), servers found on the network (ServerDiscovery; note iOS may block UDP broadcast without the multicast entitlement – then the manual address path must be great), manual address entry (ServerLocator.resolve), profile choice with avatars (publicUsers), sign-in with password (AppModel.signIn …), Quick Connect (show code, poll, like tvOS), errors in plain words. Support adding another server/profile (model.addingAccount / preselectedServer / cancelAddingProfile). Port logic and wording from Jelly/Views/OnboardingView.swift.
- ProfilePickerScreen(): "Wer schaut gerade?" grid of profiles with avatars, add profile.
- SettingsScreen(): its own NavigationStack and a native Form: servers and profiles (switch, add, sign out), Jellyseerr (connected as …, disconnect; "Jellyseerr verbinden" presents SeerrConnectSheet() – that view is provided by the Discover package, just present it), playback (autoplay next episode, skip intros, subtitle size/background/color, engine preference, slow-connection policy – same @AppStorage keys as tvOS SettingsView so behaviour matches), annual subscription section (status from purchases.access, restore, manage subscription via .manageSubscriptionsSheet or AppStore.showManageSubscriptions), Info (version, open-source licences with full licence texts, privacy notice, source code link, imprint/support links that open in Safari), diagnostics log view + delete. Port from Jelly/Views/SettingsView.swift and AboutViews.swift.
- MobilePaywall(): the subscription offer full screen, iOS style, with exactly the disclosures of the tvOS PaywallView (App Review guideline 3.1.2): title, explanation, subscribe button with trial text, restore, "Später"/"Fertig", footer line, Terms of Use and Privacy Policy as real links (Link to AppInfo.termsURL / privacyURL). Use Purchases (EnvironmentObject) exactly like tvOS.
Verify on iPhone and iPad with screenshots (launch without JELLY_SERVER to see onboarding; with JELLY_ACCESS=none to see the paywall via playing something or model.showsPaywall), German and English.

### Discover

Your package: DISCOVER. Your folder: JellyMobile/Discover/ (replace the placeholders in JellyMobile/Discover/DiscoverScreens.swift – both DiscoverScreen and SeerrConnectSheet; add files in that folder). Your simulator: "iPhone 18 Pro Max" (and "iPad Air 13-inch (M4)" for iPad). Derived data: .build/ios-discover.

Port Jelly/Views/DiscoverView.swift (Jellyseerr) to iPhone and iPad:
- DiscoverScreen(): its own NavigationStack. Without a connected Jellyseerr: an inviting explanation and a button presenting SeerrConnectSheet. Connected: a prominent search (native .searchable on this screen or a search field at the top that pushes the search results) for films and series to request; the "Wird geladen" row (approved wishes still on their way, running downloads first) with progress bars, percent and time left; "Deine Wünsche"; the discover shelves (trending, popular, upcoming); following downloads every 30 s while anything loads (same logic as tvOS: approvedRequests + myRequests, patching shelves). Pull to refresh.
- Cards: poster with status badge (SeerrStatus symbol/colour), download bar (DownloadProgress, colours per phase) and the card text (DownloadProgress.cardText / "Wartet auf Download" / year · type).
- Detail screen: backdrop, poster, title, metadata (TMDB rating locale-formatted), overview, actions: "Wünschen" (films), season selection sheet for series (seasons already there or requested are shown but not selectable), "Ansehen" when it's in the library (open via model.pendingOpen like tvOS, or playing), the download panel (overall bar, phase, time left, "fertig gegen …", per-episode rows for series), polling while loading; messages after requesting.
- SeerrConnectSheet(): a sheet (NavigationStack + Form) to connect: address (auto-found via SeerrClient.find near model.homeAddress/session.server, or model.lastSeerrServer), status line, sign-in with Jellyfin account (username prefilled) or Jellyseerr local account, errors – port SeerrConnectView logic incl. the debug env JELLY_SEERR_SERVER / JELLY_SEERR_PASSWORD (DEBUG only) so it can be tested.
Test with the local mock: start `python3 Scripts/seerr-mock.py` (port 15055, prints a log) in the background, launch the app with SIMCTL_CHILD_JELLY_SEERR_SERVER=http://127.0.0.1:15055 SIMCTL_CHILD_JELLY_SEERR_PASSWORD=x plus the demo-server login env, open the Discover tab (you may add a DEBUG-only JELLY_TAB handling in your own code if needed – or navigate by tapping isn't available; a DEBUG env read in DiscoverScreen that presents the connect sheet automatically is fine). Never sign in to a real Jellyseerr. Stop the mock when done. Screenshots on iPhone and iPad, German and English.
