#if canImport(ActivityKit) && !targetEnvironment(macCatalyst)
import ActivityKit
import Combine
import Foundation

/// Keeps the download Live Activity in step with `DownloadCenter`. While Jelly is in the background the system
/// carries the downloads on without waking it, so the activity is marked stale then and says so instead of showing
/// an old percentage.
@MainActor
final class DownloadActivityController {
    static let shared = DownloadActivityController()
    private var activity: Activity<DownloadActivityAttributes>?
    private var subscription: AnyCancellable?
    private var lastUpdate = Date.distantPast

    func start() {
        guard subscription == nil else { return }
        // Activities left over from an earlier run have nobody to update them.
        for old in Activity<DownloadActivityAttributes>.activities { Task { await old.end(nil, dismissalPolicy: .immediate) } }
        subscription = DownloadCenter.shared.$records.sink { [weak self] records in self?.update(records) }
    }

    private func update(_ records: [DownloadRecord]) {
        let running = records.filter { [.preparing, .downloading].contains($0.state) }
        guard let first = running.first else {
            guard let activity else { return }
            self.activity = nil
            let done = DownloadActivityAttributes.ContentState(title: activity.content.state.title, remaining: 0, progress: 1, finished: true)
            Task { await activity.end(ActivityContent(state: done, staleDate: nil), dismissalPolicy: .after(Date().addingTimeInterval(20))) }
            return
        }
        let expected = running.reduce(0) { $0 + max($1.expectedBytes, 1) }, received = running.reduce(0) { $0 + $1.receivedBytes }
        let name = first.seriesName.map { "\($0) – \(first.name)" } ?? first.name
        let state = DownloadActivityAttributes.ContentState(title: name, remaining: running.count, progress: min(1, Double(received) / Double(expected)), finished: false)
        let content = ActivityContent(state: state, staleDate: Date().addingTimeInterval(20))
        if let activity {
            guard Date().timeIntervalSince(lastUpdate) > 1 else { return }
            lastUpdate = Date()
            Task { await activity.update(content) }
        } else if ActivityAuthorizationInfo().areActivitiesEnabled {
            activity = try? Activity.request(attributes: DownloadActivityAttributes(), content: content)
        }
    }
}
#endif
