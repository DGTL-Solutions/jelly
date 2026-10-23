import XCTest
@testable import Jelly

final class JellyTests: XCTestCase {
    func testAddressCandidatesForLocalAndRemoteHosts() throws {
        XCTAssertEqual(try ServerLocator.candidates(for: "192.168.1.20").first?.absoluteString, "http://192.168.1.20:8096")
        XCTAssertEqual(try ServerLocator.candidates(for: "jellyfin.example.com").first?.absoluteString, "https://jellyfin.example.com")
        XCTAssertEqual(try ServerLocator.candidates(for: "nas:8920").first?.absoluteString, "https://nas:8920")
        XCTAssertEqual(try ServerLocator.candidates(for: "https://media.example.com/jellyfin/web/index.html#/home.html"),
                       [URL(string: "https://media.example.com/jellyfin")!])
        for invalid in ["", "two words", "https://user:pw@example.com"] {
            XCTAssertThrowsError(try ServerLocator.candidates(for: invalid))
        }
    }

    func testSubpathQueryEncodingAndTokenStaysInHeader() throws {
        let client = JellyfinClient(server: URL(string: "https://example.com/jellyfin")!, token: "secret", deviceID: "tv")
        let url = client.url("Items", query: ["SearchTerm": "A & B / C"])
        XCTAssertEqual(url.path, "/jellyfin/Items")
        XCTAssertEqual(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first?.value, "A & B / C")
        XCTAssertTrue(client.authorization.contains(#"Token="secret""#))
        let source = MediaSource(id: "src", container: "mkv")
        XCTAssertFalse(client.streamURL(itemID: "1", source: source, playSessionID: nil).absoluteString.contains("secret"))
    }

    func testPascalCaseDecodingAndProgress() throws {
        let json = #"{"Id":"2","Name":"Film","Type":"Movie","RunTimeTicks":100,"UserData":{"PlaybackPositionTicks":150,"Played":false},"ImageTags":{"Primary":"abc"}}"#
        let item = try JSONDecoder.jellyfin.decode(BaseItem.self, from: Data(json.utf8))
        XCTAssertEqual(item.id, "2")
        XCTAssertTrue(item.isMovie)
        XCTAssertEqual(item.progress, 1)
        XCTAssertEqual(item.imageTags?["Primary"], "abc")
        let sparse = try JSONDecoder.jellyfin.decode(BaseItem.self, from: Data(#"{"Id":"1","Name":"X"}"#.utf8))
        XCTAssertEqual(sparse.progress, 0)
        XCTAssertEqual(sparse.metadataLine, "")
    }

    func testEngineSelection() {
        func source(_ container: String, video: String, tag: String? = nil, audio: [String] = ["aac"], embeddedSubs: Bool = false) -> MediaSource {
            var streams = [MediaStream(type: "Video", index: 0, codec: video, codecTag: tag)]
            streams += audio.enumerated().map { MediaStream(type: "Audio", index: $0.offset + 1, codec: $0.element) }
            if embeddedSubs { streams.append(MediaStream(type: "Subtitle", index: 9, codec: "subrip", isExternal: false)) }
            return MediaSource(id: "s", container: container, mediaStreams: streams)
        }
        XCTAssertEqual(PlaybackEngine.choose(for: source("mov,mp4,m4a,3gp,3g2,mj2", video: "hevc", tag: "hvc1", audio: ["eac3"])), .native)
        XCTAssertEqual(PlaybackEngine.choose(for: source("mp4", video: "hevc", tag: "hev1")), .ffmpeg)
        XCTAssertEqual(PlaybackEngine.choose(for: source("mkv", video: "hevc")), .ffmpeg)
        XCTAssertEqual(PlaybackEngine.choose(for: source("mp4", video: "h264", audio: ["dts"])), .ffmpeg)
        XCTAssertEqual(PlaybackEngine.choose(for: source("mp4", video: "h264", embeddedSubs: true)), .ffmpeg)
        XCTAssertEqual(PlaybackEngine.choose(for: source("mp4", video: "h264"), preference: .ffmpeg), .ffmpeg)
    }

    func testQualityRouting() {
        let appleTV = DeviceCapabilities(dolbyVision: true, dolbyVisionProfile7: false, av1Hardware: false)
        func file(_ range: String, codec: String = "hevc", audio: String, profile: String? = nil) -> MediaSource {
            MediaSource(id: "s", container: "mkv", mediaStreams: [
                MediaStream(type: "Video", index: 0, codec: codec, videoRangeType: range),
                MediaStream(type: "Audio", index: 1, codec: audio, profile: profile)
            ])
        }
        func plan(_ source: MediaSource, device: DeviceCapabilities = appleTV, subtitle: MediaStream? = nil) -> PlaybackPlan {
            PlaybackPlan.make(for: source, audio: source.audioStreams.first, subtitle: subtitle, device: device)
        }
        XCTAssertEqual(plan(file("DOVI", audio: "eac3")).engine, .remux, "Profile 5 needs Apple's decoder")
        XCTAssertEqual(plan(file("DOVIWithHDR10", audio: "truehd")).remuxAudio, "flac,eac3,ac3,aac", "DV with lossless audio")
        XCTAssertEqual(plan(file("DOVIWithHDR10", audio: "eac3")).remuxAudio, "eac3,ac3,aac", "Audio copied when possible")
        XCTAssertEqual(plan(file("DOVIWithEL", audio: "truehd")).engine, .ffmpeg, "Profile 7 needs device support")
        XCTAssertTrue(plan(file("DOVIWithEL", audio: "truehd"), device: DeviceCapabilities(dolbyVision: true, dolbyVisionProfile7: true, av1Hardware: false)).allowsDolbyVisionProfile7)
        XCTAssertEqual(plan(file("HDR10Plus", audio: "dts")).engine, .remux, "Dynamic HDR10+")
        XCTAssertEqual(plan(file("SDR", codec: "h264", audio: "eac3", profile: "Dolby Digital Plus + Dolby Atmos")).reason, "Dolby Atmos")
        XCTAssertEqual(plan(file("HDR10", audio: "eac3")).engine, .ffmpeg, "Nothing to gain")
        XCTAssertEqual(plan(file("DOVIWithHDR10", codec: "av1", audio: "eac3")).engine, .ffmpeg)
        XCTAssertEqual(plan(file("DOVI", audio: "eac3"), device: DeviceCapabilities(dolbyVision: false, dolbyVisionProfile7: false, av1Hardware: false)).engine, .ffmpeg)
        let pgs = MediaStream(type: "Subtitle", index: 3, codec: "PGSSUB", isTextSubtitleStream: false)
        XCTAssertEqual(plan(file("HDR10Plus", audio: "eac3"), subtitle: pgs).engine, .ffmpeg, "Bitmap subtitles need FFmpeg")
        XCTAssertFalse(PlaybackEngine.remux.canShow(pgs))
        XCTAssertTrue(PlaybackEngine.ffmpeg.canShow(pgs))
    }

    func testIntroAndCreditsChapters() {
        XCTAssertTrue(Chapter(startPositionTicks: 0, name: "Intro").isIntro)
        XCTAssertTrue(Chapter(startPositionTicks: 0, name: "End Credits").isCredits)
        XCTAssertFalse(Chapter(startPositionTicks: 0, name: "Chapter 1").isIntro)
    }

    func testSeriesTrackMemory() {
        let source = MediaSource(id: "s", container: "mkv", mediaStreams: [
            MediaStream(type: "Audio", index: 1, codec: "eac3", language: "eng"), MediaStream(type: "Audio", index: 2, codec: "eac3", language: "ger"),
            MediaStream(type: "Subtitle", index: 3, codec: "subrip", language: "ger", isForced: true),
            MediaStream(type: "Subtitle", index: 4, codec: "subrip", language: "ger", isForced: false)
        ])
        let memory = TrackMemory(audioLanguage: "de", subtitleLanguage: "de", subtitleForced: false)
        XCTAssertEqual(memory.audioIndex(in: source), 2)
        XCTAssertEqual(memory.subtitleIndex(in: source), 4)
        XCTAssertEqual(TrackMemory(audioLanguage: "en", subtitleLanguage: nil).subtitleIndex(in: source), -1)
    }

    func testAudioFollowsDeviceLanguageWithoutProfilePreference() {
        let source = MediaSource(id: "s", container: "mkv", mediaStreams: [
            MediaStream(type: "Audio", index: 1, codec: "dts", language: "eng", channels: 8),
            MediaStream(type: "Audio", index: 2, codec: "dts", language: "ger", channels: 6),
            MediaStream(type: "Audio", index: 3, codec: "ac3", language: "ger", channels: 2)
        ], defaultAudioStreamIndex: 1)
        XCTAssertEqual(TrackPreference.audioIndex(for: source, userLanguage: nil, deviceLanguage: "de"), 2)
        XCTAssertEqual(TrackPreference.audioIndex(for: source, userLanguage: "eng", deviceLanguage: "de"), 1, "Profile setting wins")
        XCTAssertEqual(TrackPreference.audioIndex(for: source, userLanguage: nil, deviceLanguage: "fr"), 1)
    }

    func testTechBadges() {
        let source = MediaSource(id: "s", container: "mkv", mediaStreams: [
            MediaStream(type: "Video", index: 0, codec: "hevc", width: 3840, height: 2160, videoRange: "HDR", videoRangeType: "DOVIWithHDR10"),
            MediaStream(type: "Audio", index: 1, codec: "truehd", profile: "Dolby TrueHD + Dolby Atmos", channels: 8),
            MediaStream(type: "Subtitle", index: 2, codec: "pgssub")
        ])
        XCTAssertEqual(TechInfo.badges(source), ["4K", "Dolby Vision", "Dolby Atmos", "7.1", "UT"])
        XCTAssertEqual(JellyfinClient.fileExtension(container: "matroska,webm"), "mkv")
    }
}
