import Foundation

/// Intro and credits markers for servers without the Intro Skipper plugin: compares an episode with its neighbours in
/// the season (see `IntroDetector`) and remembers the result, so every episode is analysed only once.
actor IntroFinder {
    static let shared = IntroFinder()

    /// What to look for: the opening near the start, or the closing credits at the end of an episode.
    enum Part: String {
        case intro, credits

        /// The stretch of the episode that is compared: the first quarter (at most ten minutes) for the intro,
        /// the last fifth (four to eight minutes) for the credits.
        func window(runtime: Double) -> ClosedRange<Double> {
            switch self {
            case .intro:
                return 0...min(600, max(180, runtime * 0.25))
            case .credits:
                let length = min(480, max(240, runtime * 0.2))
                return max(0, runtime - length)...runtime
            }
        }

        /// Credits need a longer shared stretch: a recurring musical cue must not end an episode early.
        var minimum: Double { self == .intro ? 15 : 25 }
        var maximum: Double { self == .intro ? 180 : 600 }

        fileprivate func key(_ itemID: String) -> String { self == .intro ? itemID : "credits:\(itemID)" }
        fileprivate func file(_ itemID: String) -> String { self == .intro ? "\(itemID).fp" : "\(itemID).end.fp" }
    }

    /// Raise when the detection changes, so stored results are worked out again.
    private static let version = 1
    /// The server sends 32 kbit/s MP3: 4000 bytes per second of sound.
    private static let bytesPerSecond = 4000.0

    private struct Stored: Codable {
        var start: Double?
        var end: Double?
        var date: Date
    }

    private struct Archive: Codable {
        var version: Int
        var results: [String: Stored]
    }

    private let directory = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Intros", isDirectory: true)
    private var results: [String: Stored]?
    private var fingerprints: [String: Task<[UInt32]?, Never>] = [:]
    /// Downloads run one after another, so the server never reads several large files at once next to the stream.
    private var queue: Task<[UInt32]?, Never>?

    /// The stored result: `nil` if the episode wasn't analysed yet, `.some(nil)` if nothing recognisable was found.
    func known(_ itemID: String, _ part: Part = .intro) -> ClosedRange<Double>?? {
        guard let stored = archive()[part.key(itemID)] else { return nil }
        guard let start = stored.start, let end = stored.end else {
            // Episodes without a match get another chance once more of the season is on the server.
            return Date().timeIntervalSince(stored.date) < 7 * 86_400 ? .some(nil) : nil
        }
        return .some(start...end)
    }

    func intro(for episode: BaseItem, client: JellyfinClient, user: String) async -> ClosedRange<Double>? {
        await find(.intro, for: episode, client: client, user: user)
    }

    /// Finds the intro or the credits by comparing with the next and previous episodes of the season.
    func find(_ part: Part, for episode: BaseItem, client: JellyfinClient, user: String) async -> ClosedRange<Double>? {
        if let known = known(episode.id, part) { return known }
        guard episode.isEpisode, let seriesID = episode.seriesId,
              let season = try? await client.episodes(user: user, seriesID: seriesID, seasonID: episode.seasonId),
              let position = season.firstIndex(where: { $0.id == episode.id })
        else {
            Diagnostics.log("\(part.rawValue) skipped \(label(episode)): season not found")
            return nil
        }
        let current = season[position]
        // The end can only be found when the length is known.
        guard part == .intro || current.runtimeSeconds > 0 else { return nil }
        Diagnostics.log("\(part.rawValue) analysing \(label(current))")
        // Pilots often open differently, so the following episode is the best partner, then the one before.
        let partners = [position + 1, position - 1, position + 2].filter { season.indices.contains($0) }.map { season[$0] }
            .filter { part == .intro || $0.runtimeSeconds > 0 }
        guard !partners.isEmpty, let own = await fingerprint(current, part, client: client) else { return nil }
        var compared = false
        for partner in partners {
            guard let other = await fingerprint(partner, part, client: client) else { continue }
            compared = true
            guard let match = IntroDetector.match(own, other, minimum: part.minimum, maximum: part.maximum) else {
                Diagnostics.log("\(part.rawValue) none \(label(current)) vs \(label(partner))")
                continue
            }
            // Fingerprint times count from the start of the analysed window.
            let found = adjusted(match.first, part, offset: part.window(runtime: current.runtimeSeconds).lowerBound)
            let partnerFound = adjusted(match.second, part, offset: part.window(runtime: partner.runtimeSeconds).lowerBound)
            // Credits must run to (nearly) the end: if more follows, it's a scene after the credits nobody should miss.
            guard part == .intro || found.upperBound >= current.runtimeSeconds - 25 else {
                Diagnostics.log(String(format: "credits %@ end %.0f s before the end – scene after credits, ignored",
                                       label(current), current.runtimeSeconds - found.upperBound))
                continue
            }
            store(current.id, part, found)
            if known(partner.id, part) == nil, part == .intro || partnerFound.upperBound >= partner.runtimeSeconds - 25 {
                store(partner.id, part, partnerFound)
            }
            Diagnostics.log(String(format: "%@ %@ %.1f–%.1f s (via %@)", part.rawValue, label(current), found.lowerBound, found.upperBound, label(partner)))
            return found
        }
        // Only a real comparison counts as "nothing found"; a failed download is tried again next time.
        if compared { store(current.id, part, nil) }
        return nil
    }

    /// Fingerprint of the analysed stretch: from disk, from a download already running, or freshly made.
    private func fingerprint(_ item: BaseItem, _ part: Part, client: JellyfinClient) async -> [UInt32]? {
        let name = part.file(item.id)
        let file = directory.appendingPathComponent(name)
        if let data = try? Data(contentsOf: file), !data.isEmpty {
            return data.withUnsafeBytes { Array($0.bindMemory(to: UInt32.self)) }
        }
        if let running = fingerprints[name] { return await running.value }
        let previous = queue
        let task = Task<[UInt32]?, Never> {
            _ = await previous?.value
            let prints = await Self.analyse(item, part, client: client)
            if let prints, !prints.isEmpty {
                try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                try? prints.withUnsafeBytes { Data($0) }.write(to: file)
            }
            return prints
        }
        fingerprints[name] = task
        queue = task
        let prints = await task.value
        fingerprints[name] = nil
        return prints
    }

    /// Lets the server convert just the sound of the analysed stretch to a small mono MP3 and turns it into fingerprints.
    private static func analyse(_ item: BaseItem, _ part: Part, client: JellyfinClient) async -> [UInt32]? {
        let window = part.window(runtime: item.runtimeSeconds > 0 ? item.runtimeSeconds : 2400)
        let session = "\(part.rawValue)-\(UUID().uuidString.prefix(8))"
        var query = [
            "AudioCodec": "mp3", "AudioBitRate": "32000", "AudioChannels": "1", "AudioSampleRate": "11025",
            "DeviceId": client.deviceID, "PlaySessionId": session
        ]
        if window.lowerBound > 0 { query["StartTimeTicks"] = String(Int64(window.lowerBound * 10_000_000)) }
        var request = URLRequest(url: client.url("Audio/\(item.id)/stream.mp3", query: query), timeoutInterval: 60)
        request.setValue(client.authorization, forHTTPHeaderField: "Authorization")
        let started = Date()
        let target = Int((window.upperBound - window.lowerBound) * bytesPerSecond)
        var data = Data()
        data.reserveCapacity(target)
        do {
            let (bytes, response) = try await URLSession.shared.bytes(for: request)
            defer { bytes.task.cancel() }
            guard (response as? HTTPURLResponse)?.statusCode == 200 else {
                Diagnostics.log("\(part.rawValue) audio failed status=\((response as? HTTPURLResponse)?.statusCode ?? 0) \(label(item))")
                return nil
            }
            for try await byte in bytes {
                data.append(byte)
                if data.count >= target { break }
            }
        } catch {
            Diagnostics.log("\(part.rawValue) audio failed \(label(item)): \(error.localizedDescription)")
        }
        await client.stopEncoding(playSessionID: session)
        // A shorter download is fine as long as there's enough to hold an intro or credits.
        guard Double(data.count) / bytesPerSecond >= 60 else { return nil }
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("\(session).mp3")
        defer { try? FileManager.default.removeItem(at: file) }
        do {
            try data.write(to: file)
            let prints = IntroDetector.fingerprint(try IntroDetector.samples(of: file))
            Diagnostics.log(String(format: "%@ audio %@ %.0f s in %.1f s", part.rawValue, label(item), Double(data.count) / bytesPerSecond,
                                   Date().timeIntervalSince(started)))
            return prints
        } catch {
            Diagnostics.log("\(part.rawValue) decode failed \(label(item)): \(error.localizedDescription)")
            return nil
        }
    }

    /// Moves a match into episode time. Intros end just before the shared sound does, so not a moment of the episode
    /// itself is skipped.
    private func adjusted(_ range: ClosedRange<Double>, _ part: Part, offset: Double) -> ClosedRange<Double> {
        let start = range.lowerBound + offset, end = range.upperBound + offset
        return part == .intro ? start...max(start + 10, end - 1) : start...end
    }

    private static func label(_ item: BaseItem) -> String {
        "\(item.seriesName ?? item.name) \(item.episodeLabel ?? item.id)"
    }

    private func label(_ item: BaseItem) -> String { Self.label(item) }

    // MARK: Storage

    private var archiveFile: URL { directory.appendingPathComponent("results.json") }

    private func archive() -> [String: Stored] {
        if let results { return results }
        let archive = (try? Data(contentsOf: archiveFile)).flatMap { try? JSONDecoder().decode(Archive.self, from: $0) }
        let loaded = archive?.version == Self.version ? archive?.results ?? [:] : [:]
        results = loaded
        return loaded
    }

    private func store(_ itemID: String, _ part: Part, _ range: ClosedRange<Double>?) {
        var all = archive()
        all[part.key(itemID)] = Stored(start: range?.lowerBound, end: range?.upperBound, date: Date())
        results = all
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? JSONEncoder().encode(Archive(version: Self.version, results: all)).write(to: archiveFile)
    }
}
