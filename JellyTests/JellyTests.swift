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

    /// Every file plays from the original; the plan's reason names what the Apple TV gets out of it.
    func testPlaybackPlans() {
        let appleTV = DeviceCapabilities(dolbyVision: true, dolbyVisionProfile7: false, av1Hardware: false)
        func file(_ range: String, codec: String = "hevc", audio: String, profile: String? = nil, dvProfile: Int? = nil) -> MediaSource {
            MediaSource(id: "s", container: "mkv", bitrate: 40_000_000, mediaStreams: [
                MediaStream(type: "Video", index: 0, codec: codec, bitRate: 36_000_000, videoRangeType: range, dvProfile: dvProfile),
                MediaStream(type: "Audio", index: 1, codec: audio, profile: profile, bitRate: 1_000_000)
            ])
        }
        func plan(_ source: MediaSource, device: DeviceCapabilities = appleTV) -> PlaybackPlan {
            PlaybackPlan.make(for: source, audio: source.audioStreams.first, device: device)
        }
        XCTAssertEqual(plan(file("DOVI", audio: "eac3")).engine, .direct)
        XCTAssertEqual(plan(file("DOVI", audio: "eac3")).reason, "Dolby Vision")
        XCTAssertEqual(plan(file("DOVIWithEL", audio: "truehd", dvProfile: 7)).reason, "Dolby Vision Profil 7 als 8.1")
        XCTAssertEqual(plan(file("DOVI", audio: "eac3"), device: DeviceCapabilities(dolbyVision: false, dolbyVisionProfile7: false, av1Hardware: false)).reason,
                       "Dolby Vision als HDR10")
        XCTAssertEqual(plan(file("SDR", codec: "h264", audio: "eac3", profile: "Dolby Digital Plus + Dolby Atmos")).reason, "Dolby Atmos")
        // A slow line: first the lossless compact stream, only then a conversion at about 70 % of the line.
        let source = file("HDR10", audio: "truehd")
        let base = plan(source)
        XCTAssertEqual(base.fitting(source: source, audio: source.audioStreams.first, throughput: 60_000_000), base)
        XCTAssertEqual(base.fitting(source: source, audio: source.audioStreams.first, throughput: 44_000_000).remuxAudio, "flac,eac3,ac3,aac")
        XCTAssertEqual(base.fitting(source: source, audio: source.audioStreams.first, throughput: 20_000_000).maxBitrate, 14_000_000)
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

    /// Converted downloads only appear when they save at least half; "Besser" is recommended while it fits.
    func testDownloadOptions() {
        let film = MediaSource(id: "d", container: "mkv", size: 40_000_000_000, bitrate: 60_000_000, mediaStreams: [
            MediaStream(type: "Video", index: 0, codec: "hevc", width: 3840, height: 2160, bitRate: 58_000_000),
            MediaStream(type: "Audio", index: 1, codec: "eac3", bitRate: 768_000, channels: 6)
        ])
        let options = DownloadPlanner.options(source: film, runtime: 7200, audio: film.audioStreams.first)
        XCTAssertEqual(options.map(\.quality), [.original, .better, .good])
        XCTAssertEqual(options[1].bytes, Int64(Double(8_000_000 + 768_000) * 7200 / 8), "Dolby Digital+ is kept as it is")
        XCTAssertEqual(DownloadPlanner.recommended(options, free: 100_000_000_000), .better)
        XCTAssertEqual(DownloadPlanner.recommended(options, free: 4_000_000_000), .good)
        XCTAssertNil(DownloadPlanner.recommended(options, free: 1_000_000_000))
    }
}
