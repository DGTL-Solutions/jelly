import Foundation

struct IMDbRating: Equatable {
    let rating: Double
    let votes: Int
}

/// Real IMDb scores from IMDb's public ratings dataset (free for personal use, refreshed daily by IMDb).
/// Jellyfin's community rating usually comes from TMDb, so it can't be labelled IMDb. The dataset is fetched at most
/// once a week and kept as two compact sorted arrays (~12 MB) in the caches directory; lookups are binary searches.
actor IMDbRatings {
    /// IMDb's dataset is free for personal, non-commercial use only. The App Store version is sold, so it shows the
    /// rating the viewer's own Jellyfin server provides instead; builds from source keep IMDb.
    nonisolated static let isAvailable: Bool = {
        #if APPSTORE
        return false
        #else
        return true
        #endif
    }()

    static let shared = IMDbRatings()

    private static let source = URL(string: "https://datasets.imdbws.com/title.ratings.tsv.gz")!
    private static let maxAge: TimeInterval = 7 * 24 * 3600
    private let folder = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("imdb", isDirectory: true)

    private var ids: [UInt32] = []
    /// rating × 10 in the top 8 bits, vote count (capped) in the lower 24.
    private var values: [UInt32] = []
    private var loading: Task<Void, Never>?

    func rating(for imdbID: String) async -> IMDbRating? {
        await ensureLoaded()
        guard let id = Self.number(imdbID), let index = Self.search(ids, id) else { return nil }
        let value = values[index]
        return IMDbRating(rating: Double(value >> 24) / 10, votes: Int(value & 0xFF_FFFF))
    }

    private func ensureLoaded() async {
        if !ids.isEmpty, !isStale { return }
        if let loading { return await loading.value }
        let task = Task { await load() }
        loading = task
        await task.value
        loading = nil
    }

    private var isStale: Bool {
        let fetched = UserDefaults.standard.double(forKey: "imdbFetchedAt")
        return Date().timeIntervalSince1970 - fetched > Self.maxAge
    }

    private func load() async {
        let idsFile = folder.appendingPathComponent("ids.bin"), valuesFile = folder.appendingPathComponent("values.bin")
        if ids.isEmpty, let idData = try? Data(contentsOf: idsFile), let valueData = try? Data(contentsOf: valuesFile),
           idData.count == valueData.count {
            ids = idData.withUnsafeBytes { Array($0.bindMemory(to: UInt32.self)) }
            values = valueData.withUnsafeBytes { Array($0.bindMemory(to: UInt32.self)) }
        }
        guard ids.isEmpty || isStale else { return }
        do {
            let (compressed, response) = try await URLSession.shared.data(from: Self.source)
            guard (response as? HTTPURLResponse)?.statusCode == 200, let tsv = Self.gunzip(compressed) else { return }
            let (newIDs, newValues) = Self.parse(tsv)
            guard newIDs.count > 100_000 else { return }
            ids = newIDs
            values = newValues
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try newIDs.withUnsafeBufferPointer { Data(buffer: $0) }.write(to: idsFile)
            try newValues.withUnsafeBufferPointer { Data(buffer: $0) }.write(to: valuesFile)
            UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: "imdbFetchedAt")
        } catch {
            // Keep the previous data set; ratings simply stay hidden while offline.
        }
    }

    // MARK: Parsing

    static func number(_ imdbID: String) -> UInt32? {
        guard imdbID.hasPrefix("tt") else { return nil }
        return UInt32(imdbID.dropFirst(2))
    }

    static func search(_ sorted: [UInt32], _ id: UInt32) -> Int? {
        var low = 0, high = sorted.count - 1
        while low <= high {
            let mid = (low + high) / 2
            if sorted[mid] == id { return mid }
            if sorted[mid] < id { low = mid + 1 } else { high = mid - 1 }
        }
        return nil
    }

    /// `tconst \t averageRating \t numVotes` per line, e.g. `tt0111161\t9.3\t3012345`.
    static func parse(_ tsv: Data) -> ([UInt32], [UInt32]) {
        var ids: [UInt32] = [], values: [UInt32] = []
        ids.reserveCapacity(1_700_000)
        values.reserveCapacity(1_700_000)
        tsv.withUnsafeBytes { (buffer: UnsafeRawBufferPointer) in
            let bytes = buffer.bindMemory(to: UInt8.self)
            var index = bytes.firstIndex(of: 0x0A).map { $0 + 1 } ?? 0 // skip the header line
            while index < bytes.count {
                // "tt" prefix
                index += 2
                var id: UInt32 = 0
                while index < bytes.count, bytes[index] != 0x09 { id = id &* 10 &+ UInt32(bytes[index] &- 48); index += 1 }
                index += 1
                var rating: UInt32 = 0
                while index < bytes.count, bytes[index] != 0x09 {
                    if bytes[index] != 0x2E { rating = rating * 10 + UInt32(bytes[index] &- 48) }
                    index += 1
                }
                index += 1
                var votes: UInt32 = 0
                while index < bytes.count, bytes[index] != 0x0A, bytes[index] != 0x0D {
                    votes = votes &* 10 &+ UInt32(bytes[index] &- 48)
                    index += 1
                }
                while index < bytes.count, bytes[index] == 0x0A || bytes[index] == 0x0D { index += 1 }
                ids.append(id)
                values.append(min(rating, 100) << 24 | min(votes, 0xFF_FFFF))
            }
        }
        // The file is sorted by tconst; sort defensively if a future release isn't.
        if zip(ids, ids.dropFirst()).contains(where: { $0 > $1 }) {
            let order = ids.indices.sorted { ids[$0] < ids[$1] }
            return (order.map { ids[$0] }, order.map { values[$0] })
        }
        return (ids, values)
    }

    /// Foundation decompresses raw DEFLATE; strip the gzip header and trailer around it (RFC 1952).
    static func gunzip(_ data: Data) -> Data? {
        let bytes = [UInt8](data.prefix(10))
        guard bytes.count == 10, bytes[0] == 0x1F, bytes[1] == 0x8B, bytes[2] == 8 else { return nil }
        let flags = bytes[3]
        var offset = 10
        if flags & 0x04 != 0, data.count > offset + 2 {
            offset += 2 + Int(data[data.startIndex + offset]) + Int(data[data.startIndex + offset + 1]) << 8
        }
        if flags & 0x08 != 0 { while offset < data.count, data[data.startIndex + offset] != 0 { offset += 1 }; offset += 1 }
        if flags & 0x10 != 0 { while offset < data.count, data[data.startIndex + offset] != 0 { offset += 1 }; offset += 1 }
        if flags & 0x02 != 0 { offset += 2 }
        guard data.count > offset + 8 else { return nil }
        let deflate = data.subdata(in: data.startIndex + offset..<data.endIndex - 8)
        return try? (deflate as NSData).decompressed(using: .zlib) as Data
    }
}
