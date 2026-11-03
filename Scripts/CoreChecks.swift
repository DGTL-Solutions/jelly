import Foundation

/// Runs the platform-independent core logic without a tvOS runtime. See README for the command.
@main
struct CoreChecks {
    static func main() throws {
        let expectations = [
            "192.168.1.20": "http://192.168.1.20:8096",
            "jellyfin.example.com": "https://jellyfin.example.com",
            "https://media.example.com/jellyfin/web/index.html#/home": "https://media.example.com/jellyfin"
        ]
        for (input, expected) in expectations {
            let first = try ServerLocator.candidates(for: input).first?.absoluteString
            precondition(first == expected, "\(input) → \(first ?? "nil")")
        }
        for invalid in ["", "two words", "https://u:p@example.com"] {
            do { _ = try ServerLocator.candidates(for: invalid); fatalError("Invalid address accepted: \(invalid)") } catch {}
        }

        let client = JellyfinClient(server: URL(string: "https://example.com/jellyfin")!, token: "secret", deviceID: "test")
        let url = client.url("Items", query: ["SearchTerm": "A & B / C"])
        precondition(url.path == "/jellyfin/Items")
        precondition(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first?.value == "A & B / C")
        precondition(client.authorization.contains("Token=\"secret\""))
        precondition(!client.streamURL(itemID: "1", source: MediaSource(id: "s", container: "mkv"), playSessionID: nil).absoluteString.contains("secret"))

        let item = try JSONDecoder.jellyfin.decode(BaseItem.self, from: Data(#"{"Id":"2","Name":"Film","Type":"Movie","RunTimeTicks":100,"UserData":{"PlaybackPositionTicks":150}}"#.utf8))
        precondition(item.isMovie && item.progress == 1)

        let mp4 = MediaSource(id: "a", container: "mov,mp4,m4a", mediaStreams: [
            MediaStream(type: "Video", index: 0, codec: "hevc", codecTag: "hvc1"), MediaStream(type: "Audio", index: 1, codec: "eac3")
        ])
        let mkv = MediaSource(id: "b", container: "mkv", mediaStreams: [
            MediaStream(type: "Video", index: 0, codec: "hevc", width: 3840, height: 2160, videoRangeType: "DOVIWithHDR10"),
            MediaStream(type: "Audio", index: 1, codec: "truehd", profile: "Dolby TrueHD + Dolby Atmos", channels: 8)
        ])
        // Every file plays from the original on the Apple TV; the reason names what the device gets out of it.
        precondition(PlaybackPlan.make(for: mp4, audio: nil).engine == .direct)
        let profile5 = MediaSource(id: "c", container: "mkv", mediaStreams: [
            MediaStream(type: "Video", index: 0, codec: "hevc", videoRangeType: "DOVI"), MediaStream(type: "Audio", index: 1, codec: "eac3")
        ])
        let appleTV = DeviceCapabilities(dolbyVision: true, dolbyVisionProfile7: false, av1Hardware: false)
        let simulator = DeviceCapabilities(dolbyVision: false, dolbyVisionProfile7: false, av1Hardware: false)
        precondition(PlaybackPlan.make(for: profile5, audio: nil, device: appleTV).reason == "Dolby Vision")
        precondition(PlaybackPlan.make(for: profile5, audio: nil, device: simulator).reason == "Dolby Vision als HDR10")
        let dvTrueHD = MediaSource(id: "e", container: "mkv", mediaStreams: [
            MediaStream(type: "Video", index: 0, codec: "hevc", videoRangeType: "DOVIWithHDR10"), MediaStream(type: "Audio", index: 1, codec: "truehd")
        ])
        precondition(PlaybackPlan.make(for: dvTrueHD, audio: nil, device: appleTV).engine == .direct)
        // Saving bandwidth, the server keeps only the chosen track: copied when Apple's player takes it, else lossless FLAC.
        precondition(PlaybackPlan.compact(audio: dvTrueHD.audioStreams.first).remuxAudio.hasPrefix("flac"))
        precondition(PlaybackPlan.compact(audio: profile5.audioStreams.first).remuxAudio.hasPrefix("eac3"))
        precondition(PlaybackPlan.limited(9_000_000).engine == .server && PlaybackPlan.limited(9_000_000).playMethod == "Transcode")
        let atmos = MediaSource(id: "f", container: "mkv", mediaStreams: [
            MediaStream(type: "Video", index: 0, codec: "hevc", videoRangeType: "SDR"),
            MediaStream(type: "Audio", index: 1, codec: "eac3", profile: "Dolby Digital Plus + Dolby Atmos")
        ])
        precondition(PlaybackPlan.make(for: atmos, audio: nil, device: appleTV).reason == "Dolby Atmos")
        let profile7 = MediaSource(id: "g", container: "mkv", mediaStreams: [
            MediaStream(type: "Video", index: 0, codec: "hevc", videoRangeType: "DOVIWithEL"), MediaStream(type: "Audio", index: 1, codec: "truehd")
        ])
        precondition(PlaybackPlan.make(for: profile7, audio: nil, device: appleTV).reason == "Dolby Vision Profil 7 als 8.1")
        precondition(PlaybackPlan.make(for: mkv, audio: nil, device: simulator).engine == .direct)
        precondition(TechInfo.badges(mkv) == ["4K", "Dolby Vision", "Dolby Atmos", "7.1"])
        let languages = MediaSource(id: "d", container: "mkv", mediaStreams: [
            MediaStream(type: "Audio", index: 1, codec: "dts", language: "eng", channels: 8),
            MediaStream(type: "Audio", index: 4, codec: "dts", language: "deu", channels: 6)
        ], defaultAudioStreamIndex: 1)
        precondition(TrackPreference.audioIndex(for: languages, userLanguage: nil, deviceLanguage: "de") == 4)
        precondition(TrackPreference.audioIndex(for: languages, userLanguage: "eng", deviceLanguage: "de") == 1)
        let tsv = Data("tconst\taverageRating\tnumVotes\ntt0000001\t5.7\t2105\ntt2024544\t8.1\t796889\n".utf8)
        let (ids, values) = IMDbRatings.parse(tsv)
        precondition(ids == [1, 2024544] && values[1] >> 24 == 81 && values[1] & 0xFFFFFF == 796889)
        precondition(IMDbRatings.number("tt2024544").flatMap { IMDbRatings.search(ids, $0) } == 1)
        // Intro detection: the same 30 s theme at 0:40 in one episode and at 1:35 in the other, everything else differs.
        var seed: UInt64 = 1
        func noise() -> Float {
            seed = seed &* 6364136223846793005 &+ 1442695040888963407
            return Float(seed >> 40) / Float(1 << 24) * 2 - 1
        }
        func melody(_ seconds: Double) -> [Float] {
            var samples: [Float] = []
            var phase: Float = 0
            for _ in 0..<Int(seconds * 4) {
                let frequency = 1100 + noise() * 900
                for _ in 0..<Int(IntroDetector.sampleRate / 4) {
                    phase += 2 * .pi * frequency / Float(IntroDetector.sampleRate)
                    samples.append(sin(phase) * 0.5 + noise() * 0.05)
                }
            }
            return samples
        }
        let theme = melody(30)
        let intro = IntroDetector.match(IntroDetector.fingerprint(melody(40) + theme + melody(50)),
                                        IntroDetector.fingerprint(melody(95) + theme + melody(20)))
        precondition(intro.map { abs($0.first.lowerBound - 40) < 1.5 && abs($0.first.upperBound - 70) < 1.5
            && abs($0.second.lowerBound - 95) < 1.5 && abs($0.second.upperBound - 125) < 1.5 } == true, "intro \(String(describing: intro))")
        precondition(IntroDetector.match(IntroDetector.fingerprint(melody(120)), IntroDetector.fingerprint(melody(120))) == nil)
        // Jellyseerr next to Jellyfin: subdomain guesses first, then the default port on the same host.
        let seerr = SeerrClient.candidates(near: [URL(string: "https://jellyfin.example.com")!])
        precondition(seerr.first?.absoluteString == "https://jellyseerr.example.com", "\(seerr)")
        precondition(seerr.contains(URL(string: "https://jellyfin.example.com:5055")!))
        precondition(SeerrClient.candidates(near: [URL(string: "http://192.168.1.20:8096")!]) == [URL(string: "http://192.168.1.20:5055")!])
        precondition(SeerrClient.address(from: "requests.example.com/").first?.absoluteString == "https://requests.example.com")
        // Automatic sign-in only where the Jellyseerr provably belongs to this Jellyfin.
        let lan = [URL(string: "http://192.168.1.10:8096")!]
        let jellyfinSettings = SeerrClient.PublicSettings(mediaServerLogin: true, mediaServerType: 2)
        precondition(SeerrClient.belongs(URL(string: "http://192.168.1.10:5055")!, settings: jellyfinSettings, to: lan))
        precondition(!SeerrClient.belongs(URL(string: "http://192.168.1.11:5055")!, settings: jellyfinSettings, to: lan))
        precondition(!SeerrClient.belongs(URL(string: "http://192.168.1.10:5055")!, settings: .init(mediaServerType: 1), to: lan))
        precondition(!SeerrClient.belongs(URL(string: "http://192.168.1.10:5055")!, settings: .init(mediaServerLogin: false, mediaServerType: 2), to: lan))
        let ddns = [URL(string: "https://name.synology.me")!]
        precondition(!SeerrClient.belongs(URL(string: "https://jellyseerr.synology.me")!, settings: jellyfinSettings, to: ddns))
        precondition(!SeerrClient.belongs(URL(string: "https://jellyseerr.synology.me")!,
                                          settings: .init(mediaServerType: 2, jellyfinExternalHost: "https://other.synology.me"), to: ddns))
        precondition(SeerrClient.belongs(URL(string: "https://jellyseerr.example.com")!,
                                         settings: .init(mediaServerType: 2, jellyfinExternalHost: "https://jellyfin.example.com/"),
                                         to: [URL(string: "https://jellyfin.example.com")!]))
        precondition(SeerrClient.belongs(URL(string: "https://requests.example.com")!,
                                         settings: .init(mediaServerType: 2, jellyfinExternalHost: "jellyfin.example.com"),
                                         to: [URL(string: "https://jellyfin.example.com")!]))
        let wished = try JSONDecoder().decode(SeerrClient.Title.self, from: Data(#"{"id":603,"mediaType":"movie","title":"Matrix","releaseDate":"1999-03-31","posterPath":"/p.jpg","mediaInfo":{"status":5,"jellyfinMediaId":"abc"}}"#.utf8))
        precondition(wished.status == .available && wished.year == "1999" && wished.id == "movie-603")
        precondition(wished.download == nil && !(wished.mediaInfo?.isLoading ?? true))
        // Download progress from Jellyseerr's tracker: a season pack counts once, the slowest running download sets the time.
        let loading = try JSONDecoder().decode(SeerrClient.Title.self, from: Data(#"""
            {"id":1399,"mediaType":"tv","name":"Game of Thrones","mediaInfo":{"status":3,"downloadStatus":[
             {"size":4000,"sizeLeft":1000,"status":"downloading","timeLeft":"00:10:00","estimatedCompletionTime":"2027-01-15T08:10:00.000Z","downloadId":"A","episode":{"seasonNumber":1,"episodeNumber":2}},
             {"size":4000,"sizeLeft":1000,"status":"downloading","timeLeft":"00:10:00","estimatedCompletionTime":"2027-01-15T08:10:00.000Z","downloadId":"A","episode":{"seasonNumber":1,"episodeNumber":1}},
             {"size":2000,"sizeLeft":2000,"status":"queued","timeLeft":null,"estimatedCompletionTime":null,"downloadId":"B","episode":{"seasonNumber":2,"episodeNumber":1}}],
             "downloadStatus4k":[]}}
            """#.utf8))
        let clock = try Date.ISO8601FormatStyle().parse("2027-01-15T08:00:00Z")
        let progress = DownloadProgress(loading.mediaInfo!.downloads, now: clock)!
        precondition(loading.mediaInfo!.isLoading && progress.phase == .downloading && progress.percent == "50 %", "\(progress)")
        precondition(progress.remaining == 600 && progress.cardText == "50 % · noch 10 Min.", "\(progress)")
        precondition(progress.parts.map(\.label) == ["S1 E1", "S1 E2", "S2 E1"] && progress.parts[0].fraction == 0.75 && progress.parts[2].phase == .queued)
        precondition(DownloadProgress([.init(size: 100, sizeLeft: 0, status: "completed")])?.summary == "Wird importiert")
        precondition(DownloadProgress([.init(size: 100, sizeLeft: 60, status: "paused")])?.cardText == "Pausiert · 40 %")
        precondition(DownloadProgress([.init(size: 100, sizeLeft: 60, status: "warning")])?.phase == .stalled)
        precondition(DownloadProgress([.init(size: 100, sizeLeft: 60, status: "downloading", timeLeft: "1.02:00:00")])?.remaining == 93_600)
        precondition(DownloadProgress.seconds("00:12:34.5") == 754.5 && DownloadProgress.seconds("00:00:00") == nil && DownloadProgress([]) == nil)
        let request = try JSONDecoder().decode(SeerrClient.Request.self, from: Data(#"{"id":7,"status":2,"media":{"tmdbId":603,"mediaType":"movie","status":3,"downloadStatus":[{"size":10,"sizeLeft":5,"status":"downloading"}]}}"#.utf8))
        precondition(request.media?.key == "movie-603" && request.media?.info.download?.percent == "50 %")
        // App Store version: yearly subscription with two free weeks; without an active subscription playback stops.
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        precondition(Access.state(entitled: false, trialEnds: nil, everSubscribed: false, now: now) == .notSubscribed)
        precondition(Access.state(entitled: true, trialEnds: now.addingTimeInterval(14 * 86_400), everSubscribed: true, now: now) == .trial(daysLeft: 14))
        precondition(Access.state(entitled: true, trialEnds: now.addingTimeInterval(0.4 * 86_400), everSubscribed: true, now: now) == .trial(daysLeft: 1))
        precondition(Access.state(entitled: true, trialEnds: now.addingTimeInterval(-60), everSubscribed: true, now: now) == .subscribed)
        precondition(Access.state(entitled: true, trialEnds: nil, everSubscribed: true, now: now) == .subscribed)
        precondition(Access.state(entitled: false, trialEnds: nil, everSubscribed: true, now: now) == .expired)
        precondition(!Access.expired.canPlay && !Access.notSubscribed.canPlay && Access.trial(daysLeft: 3).canPlay && Access.subscribed.canPlay && Access.checking.canPlay)
        // Downloads: a converted copy only appears when it saves at least half; "Besser" is recommended when it fits.
        let film = MediaSource(id: "d", container: "mkv", size: 40_000_000_000, bitrate: 60_000_000, mediaStreams: [
            MediaStream(type: "Video", index: 0, codec: "hevc", width: 3840, height: 2160, bitRate: 58_000_000),
            MediaStream(type: "Audio", index: 1, codec: "truehd", channels: 8)
        ])
        let filmOptions = DownloadPlanner.options(source: film, runtime: 7200, audio: film.audioStreams.first)
        precondition(filmOptions.map(\.quality) == [.original, .better, .good], "\(filmOptions)")
        precondition(filmOptions[1].bytes == Int64(Double(8_000_000 + 640_000) * 7200 / 8) && filmOptions[1].resolution == "1080p")
        precondition(filmOptions[2].resolution == "720p" && filmOptions[2].bytes < filmOptions[1].bytes / 2)
        precondition(DownloadPlanner.recommended(filmOptions, free: 64_000_000_000) == .better)
        precondition(DownloadPlanner.recommended(filmOptions, free: 5_000_000_000) == .good)
        precondition(DownloadPlanner.recommended(filmOptions, free: 1_500_000_000) == nil)
        precondition(DownloadPlanner.options(source: film, runtime: 7200, audio: nil, canConvert: false).count == 1)
        // A small 1080p file: "Besser" would hardly be smaller, so only "Original" and maybe "Gut".
        let small = MediaSource(id: "e", container: "mp4", size: 2_700_000_000, bitrate: 9_000_000, mediaStreams: [
            MediaStream(type: "Video", index: 0, codec: "h264", width: 1920, height: 1080, bitRate: 8_600_000),
            MediaStream(type: "Audio", index: 1, codec: "ac3", bitRate: 384_000, channels: 6)
        ])
        let smallOptions = DownloadPlanner.options(source: small, runtime: 2400, audio: small.audioStreams.first)
        precondition(smallOptions.map(\.quality) == [.original, .good], "\(smallOptions)")
        precondition(DownloadPlanner.recommended(smallOptions, free: 64_000_000_000) == .original)
        // A whole season: each episode adds its own size, or its next larger one where it has no smaller copy.
        let season = DownloadPlanner.combined([filmOptions, smallOptions])
        precondition(season.map(\.quality) == [.original, .better, .good])
        precondition(season[1].bytes == filmOptions[1].bytes + smallOptions[0].bytes)
        let converted = JellyfinClient(server: URL(string: "https://example.com")!, token: "t", deviceID: "dev")
            .downloadURL(itemID: "9", source: film, quality: .better, audioIndex: 1).absoluteString
        precondition(converted.contains("Videos/9/stream.mp4") && converted.contains("MaxHeight=1080") && converted.contains("AudioStreamIndex=1")
            && converted.contains("SubtitleMethod=Drop") && !converted.contains("Static=true"))
        precondition(JellyfinClient(server: URL(string: "https://example.com")!, deviceID: "d")
            .downloadURL(itemID: "9", source: film, quality: .original, audioIndex: nil).path == "/Items/9/Download")
        print("Core checks passed: address detection, URL building, token handling, decoding, engine selection, Dolby Vision routing, HDR badges, audio language, IMDb dataset, intro detection, Jellyseerr, download progress, subscription and trial, offline downloads.")
    }
}
