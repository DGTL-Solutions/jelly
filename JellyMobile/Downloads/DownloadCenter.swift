import Foundation
import UIKit

/// A film or episode saved on this device, with everything needed to show and play it without the server.
struct DownloadRecord: Codable, Identifiable, Equatable {
    enum State: String, Codable { case preparing, downloading, finished, failed }

    /// Also the folder name.
    let id: String
    /// The profile it was saved for (`Session.key`); every profile sees only its own downloads.
    let profileKey: String
    let itemID: String
    var name: String
    var type: String?
    var seriesID: String?
    var seriesName: String?
    var season: Int?
    var episode: Int?
    var runtime: Double
    var quality: DownloadQuality
    var state: State
    var expectedBytes: Int64
    var receivedBytes: Int64 = 0
    var fileName: String?
    var sourceID: String
    /// The audio track a converted copy carries.
    var audioIndex: Int?
    var subtitleFiles: [Int: String] = [:]
    var fontFiles: [String] = []
    var hasImage = false
    var intro: [Double]?
    var creditsStart: Double?
    /// Where it was left off and whether it was watched, also when that happened without a connection.
    var position: Double = 0
    var played = false
    var needsSync = false
    var added = Date()
    var error: String?

    var progress: Double {
        guard state != .finished else { return 1 }
        guard expectedBytes > 0 else { return 0 }
        return min(0.99, Double(receivedBytes) / Double(expectedBytes))
    }
}

/// Downloads on iPhone and iPad. A background `URLSession` carries on while Jelly is closed; the files live in
/// Application Support (not purged by the system, not backed up to iCloud).
@MainActor
final class DownloadCenter: NSObject, ObservableObject {
    static let shared = DownloadCenter()

    @Published private(set) var records: [DownloadRecord] = []
    /// Called once the system has delivered every background event (see the app delegate).
    var backgroundCompletion: (() -> Void)?

    nonisolated static let directory: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        var url = base.appendingPathComponent("Downloads", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? url.setResourceValues(values)
        return url
    }()

    private static let index = directory.appendingPathComponent("index.json")
    static let sessionIdentifier = "de.jelly.downloads"
    private var urlSession: URLSession!
    private var lastProgressUpdate: [String: Date] = [:]

    override private init() {
        super.init()
        records = (try? Data(contentsOf: Self.index)).flatMap { try? JSONDecoder().decode([DownloadRecord].self, from: $0) } ?? []
        let configuration = URLSessionConfiguration.background(withIdentifier: Self.sessionIdentifier)
        configuration.sessionSendsLaunchEvents = true
        configuration.isDiscretionary = false
        // The server converts "Besser" and "Gut" while sending; two at a time keeps it responsive for streaming.
        configuration.httpMaximumConnectionsPerHost = 2
        configuration.timeoutIntervalForRequest = 300
        configuration.timeoutIntervalForResource = 60 * 60 * 24 * 3
        urlSession = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
        reconcile()
    }

    // MARK: Lookups

    func records(profileKey: String?) -> [DownloadRecord] {
        records.filter { $0.profileKey == profileKey }
    }

    func record(itemID: String, profileKey: String?) -> DownloadRecord? {
        records.first { $0.itemID == itemID && $0.profileKey == profileKey }
    }

    func folder(_ record: DownloadRecord) -> URL { Self.directory.appendingPathComponent(record.id, isDirectory: true) }

    func imageURL(_ record: DownloadRecord) -> URL? {
        record.hasImage ? folder(record).appendingPathComponent("image.jpg") : nil
    }

    /// Free space for new downloads, as the system counts it for files the user asked for.
    var freeSpace: Int64? {
        let values = try? Self.directory.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        return values?.volumeAvailableCapacityForImportantUsage
    }

    var usedSpace: Int64 {
        records.filter { $0.state == .finished }.reduce(0) { $0 + $1.receivedBytes }
    }

    func item(_ record: DownloadRecord) -> BaseItem? {
        (try? Data(contentsOf: folder(record).appendingPathComponent("item.json")))
            .flatMap { try? JSONDecoder.jellyfin.decode(BaseItem.self, from: $0) }
            .map { item in
                var item = item
                item.userData = item.userData ?? UserItemData()
                item.userData?.playbackPositionTicks = Ticks.from(seconds: record.position)
                item.userData?.played = record.played
                return item
            }
    }

    /// The download as the player needs it, with the next downloaded episode of the series for "Nächste Folge".
    func offlineMedia(for item: BaseItem, profileKey: String?) -> OfflineMedia? {
        guard let record = record(itemID: item.id, profileKey: profileKey), record.state == .finished,
              let fileName = record.fileName, let source = source(record) else { return nil }
        let folder = folder(record)
        let file = folder.appendingPathComponent(fileName)
        guard FileManager.default.fileExists(atPath: file.path) else { return nil }
        var media = OfflineMedia(file: file, source: record.quality == .original ? source : Self.converted(source, record: record),
                                 subtitles: record.subtitleFiles.mapValues { folder.appendingPathComponent($0) },
                                 fonts: record.fontFiles.map { folder.appendingPathComponent($0) },
                                 keepsStreamIndexes: record.quality == .original)
        if let intro = record.intro, intro.count == 2, intro[0] < intro[1] { media.intro = intro[0]...intro[1] }
        media.creditsStart = record.creditsStart
        if let seriesID = record.seriesID {
            let order = { (r: DownloadRecord) in (r.season ?? 0) * 10_000 + (r.episode ?? 0) }
            let next = records(profileKey: profileKey)
                .filter { $0.seriesID == seriesID && $0.state == .finished && order($0) > order(record) }
                .min { order($0) < order($1) }
            media.nextEpisode = next.flatMap(self.item)
        }
        return media
    }

    private func source(_ record: DownloadRecord) -> MediaSource? {
        guard let data = try? Data(contentsOf: folder(record).appendingPathComponent("playback.json")),
              let info = try? JSONDecoder.jellyfin.decode(JellyfinClient.PlaybackInfoResponse.self, from: data) else { return nil }
        return info.mediaSources.first { $0.id == record.sourceID } ?? info.mediaSources.first
    }

    /// The stream layout of a converted copy: the picture at its new size, the one audio track, text subtitles as sidecars.
    static func converted(_ source: MediaSource, record: DownloadRecord) -> MediaSource {
        var copy = source
        let height = min(record.quality.maxHeight ?? 1080, source.video?.height ?? 1080)
        copy.container = "mp4"
        copy.size = record.receivedBytes
        copy.bitrate = record.runtime > 0 ? Int(Double(record.receivedBytes) * 8 / record.runtime) : nil
        copy.mediaStreams = source.streams.compactMap { stream in
            var stream = stream
            switch stream.type {
            case "Video":
                guard stream.index == source.video?.index else { return nil }
                if let width = stream.width, let original = stream.height, original > height {
                    stream.width = width * height / original
                    stream.height = height
                }
                stream.codec = "h264"
                stream.videoRange = "SDR"
                stream.videoRangeType = "SDR"
                stream.dvProfile = nil
                stream.bitRate = record.quality.videoBitrate
            case "Audio":
                guard stream.index == (record.audioIndex ?? source.defaultAudioStreamIndex) else { return nil }
            case "Subtitle":
                guard record.subtitleFiles[stream.index] != nil else { return nil }
                stream.isExternal = true
            default:
                return nil
            }
            return stream
        }
        copy.defaultAudioStreamIndex = record.audioIndex ?? source.defaultAudioStreamIndex
        if let subtitle = copy.defaultSubtitleStreamIndex, record.subtitleFiles[subtitle] == nil { copy.defaultSubtitleStreamIndex = nil }
        return copy
    }

    // MARK: Starting

    enum StartError: LocalizedError {
        case notAllowed, noSpace
        var errorDescription: String? {
            switch self {
            case .notAllowed: return String(localized: "Dein Jellyfin-Profil darf keine Downloads speichern. Das lässt sich im Jellyfin-Dashboard unter Benutzer › Zugriff ändern.")
            case .noSpace: return String(localized: "Auf diesem Gerät ist nicht genug Platz frei.")
            }
        }
    }

    /// Saves the item's details and stream info, artwork, subtitles and markers, then hands the file to the background
    /// session. `audioLanguage` picks the track a converted copy keeps.
    func start(_ item: BaseItem, quality: DownloadQuality, client: JellyfinClient, session: Session, audioLanguage: String?) async throws {
        let user = session.userID
        if let existing = record(itemID: item.id, profileKey: session.key) {
            guard existing.state == .failed else { return }
            remove(existing)
        }
        let itemData = try await client.itemData(user: user, id: item.id)
        let full = try JSONDecoder.jellyfin.decode(BaseItem.self, from: itemData)
        let infoData = try await client.playbackInfoData(user: user, itemID: item.id, mediaSourceID: nil)
        let info = try JSONDecoder.jellyfin.decode(JellyfinClient.PlaybackInfoResponse.self, from: infoData)
        guard let source = info.mediaSources.first(where: { $0.requiresOpening != true }) ?? info.mediaSources.first else {
            throw JellyError.unsupported
        }
        let memory = full.seriesId.flatMap { TrackMemory.load(seriesID: $0) }
        let audioIndex = memory?.audioIndex(in: source) ?? TrackPreference.audioIndex(for: source, userLanguage: audioLanguage)
        let audio = source.audioStreams.first { $0.index == audioIndex }
        let option = DownloadPlanner.options(source: source, runtime: full.runtimeSeconds, audio: audio)
            .first { $0.quality == quality } ?? DownloadPlanner.options(source: source, runtime: full.runtimeSeconds, audio: audio)[0]
        guard DownloadPlanner.fits(option, free: freeSpace) else { throw StartError.noSpace }

        var record = DownloadRecord(id: UUID().uuidString, profileKey: session.key, itemID: full.id, name: full.name, type: full.type,
                                    seriesID: full.seriesId, seriesName: full.seriesName, season: full.parentIndexNumber,
                                    episode: full.indexNumber, runtime: max(full.runtimeSeconds, Ticks.seconds(source.runTimeTicks)),
                                    quality: option.quality, state: .preparing, expectedBytes: option.bytes, sourceID: source.id,
                                    audioIndex: option.quality == .original ? nil : audioIndex)
        record.position = full.resumeSeconds
        record.played = full.isWatched
        records.append(record)
        persist()

        let folder = folder(record)
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try itemData.write(to: folder.appendingPathComponent("item.json"))
            try infoData.write(to: folder.appendingPathComponent("playback.json"))
            record.hasImage = await save(client.artworkURL(full, full.isEpisode ? .landscape : .poster, width: 600), client: client,
                                         to: folder.appendingPathComponent("image.jpg"))
            // Sidecar subtitles: every text track of a converted copy (it carries none), and for the original only what
            // isn't inside the file plus ASS scripts, which libass reads whole.
            for stream in source.subtitleStreams where !stream.isImageSubtitle {
                guard option.quality != .original || stream.isExternal == true || stream.isASS else { continue }
                let name = "subtitle-\(stream.index).\(client.subtitleURL(itemID: full.id, sourceID: source.id, stream: stream).pathExtension)"
                if await save(client.subtitleURL(itemID: full.id, sourceID: source.id, stream: stream), client: client,
                              to: folder.appendingPathComponent(name)) {
                    record.subtitleFiles[stream.index] = name
                }
            }
            if source.subtitleStreams.contains(where: \.isASS) {
                for attachment in (source.mediaAttachments ?? []).filter(\.isFont) {
                    let name = "font-\(attachment.index)-" + (attachment.fileName ?? "font").replacingOccurrences(of: "/", with: "_")
                    if await save(client.url("Videos/\(full.id)/\(source.id)/Attachments/\(attachment.index)"), client: client,
                                  to: folder.appendingPathComponent(name)) {
                        record.fontFiles.append(name)
                    }
                }
            }
            let segments = await client.mediaSegments(itemID: full.id)
            if let intro = segments.first(where: { $0.type == "Intro" }) {
                record.intro = [Ticks.seconds(intro.startTicks), Ticks.seconds(intro.endTicks)]
            } else if case let known?? = await IntroFinder.shared.known(full.id, .intro) {
                record.intro = [known.lowerBound, known.upperBound]
            }
            if let outro = segments.first(where: { $0.type == "Outro" }) {
                record.creditsStart = Ticks.seconds(outro.startTicks)
            } else if case let known?? = await IntroFinder.shared.known(full.id, .credits) {
                record.creditsStart = known.lowerBound
            }
        } catch {
            remove(record)
            throw error
        }

        let ext = option.quality == .original ? JellyfinClient.fileExtension(container: source.container) : "mp4"
        record.fileName = "media.\(ext)"
        record.state = .downloading
        update(record)
        var request = URLRequest(url: client.downloadURL(itemID: full.id, source: source, quality: option.quality,
                                                         audioIndex: record.audioIndex))
        request.setValue(client.authorization, forHTTPHeaderField: "Authorization")
        let task = urlSession.downloadTask(with: request)
        task.taskDescription = "\(record.id)|\(ext)"
        task.resume()
        Diagnostics.log("download start \"\(full.name)\" \(option.quality.rawValue) ≈\(DownloadPlanner.size(option.bytes))")
    }

    private func save(_ url: URL?, client: JellyfinClient, to file: URL) async -> Bool {
        guard let url else { return false }
        var request = URLRequest(url: url, timeoutInterval: 120)
        request.setValue(client.authorization, forHTTPHeaderField: "Authorization")
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200, !data.isEmpty else { return false }
        return (try? data.write(to: file)) != nil
    }

    // MARK: Changing

    /// Stops a running download or deletes a saved one.
    func remove(_ record: DownloadRecord) {
        urlSession.getAllTasks { tasks in
            tasks.filter { $0.taskDescription?.hasPrefix(record.id + "|") == true }.forEach { $0.cancel() }
        }
        try? FileManager.default.removeItem(at: folder(record))
        records.removeAll { $0.id == record.id }
        persist()
    }

    /// The position and watched state after playing; offline they wait for the next connection.
    func notePlayback(itemID: String, profileKey: String?, position: Double, ended: Bool, offline: Bool) {
        guard var record = record(itemID: itemID, profileKey: profileKey) else { return }
        let played = ended || (record.runtime > 0 && position / record.runtime > 0.9)
        record.position = played ? 0 : position
        record.played = record.played || played
        if offline { record.needsSync = true }
        update(record)
    }

    /// Sends positions measured offline to the server once it answers again.
    func sync(client: JellyfinClient, session: Session) async {
        for record in records(profileKey: session.key) where record.needsSync {
            do {
                try await client.saveUserData(user: session.userID, itemID: record.itemID, seconds: record.position, played: record.played)
                if var current = self.record(itemID: record.itemID, profileKey: session.key) {
                    current.needsSync = false
                    update(current)
                }
            } catch {
                return
            }
        }
    }

    static let autoNextKey = "autoDownloadNext"

    /// Optional: for every series with downloads, the next two unwatched episodes are kept on the device and watched
    /// ones make room – so there is always something to watch on the train.
    func keepNextEpisodes(client: JellyfinClient, session: Session, audioLanguage: String?) async {
        guard UserDefaults.standard.bool(forKey: Self.autoNextKey), !keepingNext else { return }
        keepingNext = true
        defer { keepingNext = false }
        let series = Dictionary(grouping: records(profileKey: session.key).filter { $0.seriesID != nil }, by: { $0.seriesID ?? "" })
        for (seriesID, saved) in series {
            // Only series the viewer is in the middle of: the server names the next unwatched episode.
            guard let next = try? await client.nextUp(user: session.userID, seriesID: seriesID, limit: 1).first,
                  let episodes = try? await client.episodes(user: session.userID, seriesID: seriesID),
                  let index = episodes.firstIndex(where: { $0.id == next.id }) else { continue }
            let wanted = Array(episodes[index...].prefix(2))
            let quality = saved.max { $0.added < $1.added }?.quality ?? .original
            for episode in wanted where record(itemID: episode.id, profileKey: session.key) == nil {
                do {
                    try await start(episode, quality: quality, client: client, session: session, audioLanguage: audioLanguage)
                    Diagnostics.log("auto download \"\(episode.name)\"")
                } catch {
                    Diagnostics.log("auto download failed: \(error)")
                    return
                }
            }
            let before = Set(episodes[..<index].map(\.id))
            for record in saved where record.state == .finished && record.played && !record.needsSync && before.contains(record.itemID) {
                remove(record)
            }
        }
    }

    private var keepingNext = false

    private func update(_ record: DownloadRecord) {
        guard let index = records.firstIndex(where: { $0.id == record.id }) else { return }
        records[index] = record
        persist()
    }

    private func persist() {
        try? JSONEncoder().encode(records).write(to: Self.index, options: .atomic)
    }

    /// Downloads that were running when Jelly was ended without the system finishing them count as failed.
    private func reconcile() {
        urlSession.getAllTasks { tasks in
            let running = Set(tasks.compactMap { $0.taskDescription?.split(separator: "|").first.map(String.init) })
            Task { @MainActor in
                for var record in self.records where [.preparing, .downloading].contains(record.state) && !running.contains(record.id) {
                    record.state = .failed
                    record.error = String(localized: "Der Download wurde unterbrochen.")
                    self.update(record)
                }
            }
        }
    }

    fileprivate func received(_ id: String, bytes: Int64, expected: Int64) {
        guard var record = records.first(where: { $0.id == id }), record.state == .downloading else { return }
        let now = Date()
        if let last = lastProgressUpdate[id], now.timeIntervalSince(last) < 0.5 { return }
        lastProgressUpdate[id] = now
        record.receivedBytes = bytes
        if expected > 0 { record.expectedBytes = expected }
        if let index = records.firstIndex(where: { $0.id == id }) { records[index] = record }
    }

    fileprivate func finished(_ id: String, bytes: Int64?, error: String?) {
        guard var record = records.first(where: { $0.id == id }) else { return }
        if let bytes {
            record.state = .finished
            record.receivedBytes = bytes
            record.expectedBytes = bytes
            record.error = nil
            Diagnostics.log("download done \"\(record.name)\" \(DownloadPlanner.size(bytes))")
        } else {
            guard record.state != .finished else { return }
            record.state = .failed
            record.error = error
            Diagnostics.log("download failed \"\(record.name)\": \(error ?? "-")")
        }
        update(record)
    }
}

extension DownloadCenter: URLSessionDownloadDelegate {
    nonisolated func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
                                totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        guard let id = downloadTask.taskDescription?.split(separator: "|").first.map(String.init) else { return }
        Task { @MainActor in self.received(id, bytes: totalBytesWritten, expected: totalBytesExpectedToWrite) }
    }

    /// The file has to leave the temporary location before this returns.
    nonisolated func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        guard let parts = downloadTask.taskDescription?.split(separator: "|").map(String.init), parts.count == 2 else { return }
        let id = parts[0]
        let status = (downloadTask.response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else {
            let message = status == 403 ? DownloadCenter.StartError.notAllowed.errorDescription
                : String(localized: "Der Server hat den Download abgelehnt (Fehler \(status)).")
            Task { @MainActor in self.finished(id, bytes: nil, error: message) }
            return
        }
        let folder = Self.directory.appendingPathComponent(id, isDirectory: true)
        let destination = folder.appendingPathComponent("media.\(parts[1])")
        do {
            guard FileManager.default.fileExists(atPath: folder.path) else { return }
            try? FileManager.default.removeItem(at: destination)
            try FileManager.default.moveItem(at: location, to: destination)
            let size = (try? destination.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init) ?? 0
            Task { @MainActor in self.finished(id, bytes: size, error: nil) }
        } catch {
            Task { @MainActor in self.finished(id, bytes: nil, error: error.localizedDescription) }
        }
    }

    nonisolated func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let error, let id = task.taskDescription?.split(separator: "|").first.map(String.init) else { return }
        if (error as? URLError)?.code == .cancelled { return }
        Task { @MainActor in self.finished(id, bytes: nil, error: error.localizedDescription) }
    }

    nonisolated func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        Task { @MainActor in
            self.backgroundCompletion?()
            self.backgroundCompletion = nil
        }
    }
}
