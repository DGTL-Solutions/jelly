import Foundation

/// Measures how fast the server can actually deliver a media file to this Apple TV.
/// Jellyfin's own "in network" flag is unreliable behind reverse proxies, so the decision is based on throughput.
enum NetworkProbe {
    struct Result: Codable, Equatable {
        /// Bits per second.
        var throughput: Double
        var latency: Double?
        var date: Date
        /// Throughput of each full second, to judge stability.
        var samples: [Double] = []

        var megabits: Double { throughput / 1_000_000 }
        var minimum: Double? { samples.min() }
    }

    /// Every measurement per server, to show at which time of day the line is fast or slow.
    struct HistoryEntry: Codable, Equatable {
        var server: String
        var date: Date
        var throughput: Double
    }

    static var history: [HistoryEntry] {
        get { (UserDefaults.standard.data(forKey: "connectionHistory")).flatMap { try? JSONDecoder().decode([HistoryEntry].self, from: $0) } ?? [] }
        set { UserDefaults.standard.set(try? JSONEncoder().encode(Array(newValue.suffix(300))), forKey: "connectionHistory") }
    }

    private static var cache: [String: Result] = [:]
    private static let lock = NSLock()

    /// A measurement younger than 30 minutes for this server, if any.
    static func recent(for server: URL) -> Result? {
        lock.withLock { cache[server.absoluteString] }.flatMap { Date().timeIntervalSince($0.date) < 30 * 60 ? $0 : nil }
    }

    /// What the player itself received during a film, so the next one starts with the line as it is now.
    static func remember(throughput: Double, for server: URL) {
        lock.withLock {
            cache[server.absoluteString] = Result(throughput: throughput, latency: cache[server.absoluteString]?.latency, date: Date())
        }
    }

    /// Streams part of the original file for a few seconds, starting a third into it, and counts the bytes.
    static func measure(client: JellyfinClient, itemID: String, source: MediaSource, seconds: TimeInterval = 4) async -> Result? {
        let started = Date()
        let latency = try? await { () async throws -> Double in
            _ = try await client.publicInfo(timeout: 5)
            return Date().timeIntervalSince(started)
        }()
        // From the start of the file: a range request deep into a huge file can stall behind proxies such as Cloudflare.
        var request = URLRequest(url: client.streamURL(itemID: itemID, source: source, playSessionID: nil), timeoutInterval: seconds + 10)
        request.setValue(client.authorization, forHTTPHeaderField: "Authorization")
        let counter = ByteCounter(limit: seconds)
        let session = URLSession(configuration: .ephemeral, delegate: counter, delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        let (throughput, samples) = await counter.run(session.dataTask(with: request))
        guard let throughput, throughput > 0 else {
            Diagnostics.log("probe failed status=\(counter.status) bytes=\(counter.received) error=\(counter.failure ?? "-")")
            return nil
        }
        let result = Result(throughput: throughput, latency: latency, date: Date(), samples: samples)
        lock.withLock { cache[client.server.absoluteString] = result }
        history.append(HistoryEntry(server: client.server.absoluteString, date: result.date, throughput: throughput))
        Diagnostics.log(String(format: "probe %.1f Mbit/s latency %.0f ms", result.megabits, (latency ?? 0) * 1000))
        return result
    }

    private final class ByteCounter: NSObject, URLSessionDataDelegate, @unchecked Sendable {
        private let limit: TimeInterval
        private var bytes = 0
        private var firstByte: Date?
        private var secondBytes = 0
        private var secondStart: Date?
        private var samples: [Double] = []
        private(set) var status = 0
        private(set) var failure: String?
        var received: Int { lock.withLock { bytes } }
        private var continuation: CheckedContinuation<(Double?, [Double]), Never>?
        private var task: URLSessionDataTask?
        private let lock = NSLock()

        init(limit: TimeInterval) { self.limit = limit }

        func run(_ task: URLSessionDataTask) async -> (Double?, [Double]) {
            await withCheckedContinuation { continuation in
                lock.withLock {
                    self.continuation = continuation
                    self.task = task
                }
                task.resume()
                // Up to eight seconds for the first byte, then the measuring window.
                DispatchQueue.global().asyncAfter(deadline: .now() + limit + 8) { [weak self] in self?.finish() }
            }
        }

        func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
            let done: Bool = lock.withLock {
                let now = Date()
                if firstByte == nil { firstByte = now; secondStart = now }
                bytes += data.count
                secondBytes += data.count
                if let start = secondStart, now.timeIntervalSince(start) >= 1 {
                    samples.append(Double(secondBytes) * 8 / now.timeIntervalSince(start))
                    secondBytes = 0
                    secondStart = now
                }
                return Date().timeIntervalSince(firstByte!) >= limit
            }
            if done { finish() }
        }

        func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
            status = (response as? HTTPURLResponse)?.statusCode ?? 0
            completionHandler(.allow)
        }

        func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
            if let error, (error as? URLError)?.code != .cancelled { failure = error.localizedDescription }
            finish()
        }

        /// Throughput from the first byte on, so connection setup doesn't count against the line.
        private func finish() {
            let (continuation, value, samples, task): (CheckedContinuation<(Double?, [Double]), Never>?, Double?, [Double], URLSessionDataTask?) = lock.withLock {
                let elapsed = firstByte.map { Date().timeIntervalSince($0) } ?? 0
                let value = elapsed > 0.5 ? Double(bytes) * 8 / elapsed : nil
                defer { self.continuation = nil }
                return (self.continuation, value, self.samples, self.task)
            }
            task?.cancel()
            continuation?.resume(returning: (value, samples))
        }
    }
}
