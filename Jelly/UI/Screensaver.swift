import SwiftUI
import UIKit
import UIKit.UIGestureRecognizerSubclass

/// Starts the cover wall after a period without remote input while browsing.
@MainActor
final class IdleMonitor: ObservableObject {
    static let shared = IdleMonitor()

    @Published var screensaverActive = false
    /// Set by the root view: only while browsing a library, never during playback or onboarding.
    var isAllowed: () -> Bool = { false }

    private var lastActivity = Date()
    private var timer: Timer?
    private var wakeTask: Task<Void, Never>?
    private var installed = false

    func start() {
        guard !installed else { return }
        installed = true
        NotificationCenter.default.addObserver(forName: UIFocusSystem.didUpdateNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.activity() }
        }
        installRecognizer()
        timer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.check() }
        }
    }

    /// Watches every press and touch on the window without consuming it.
    private func installRecognizer() {
        guard let window = UIApplication.shared.connectedScenes.compactMap({ ($0 as? UIWindowScene)?.keyWindow }).first else {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in self?.installRecognizer() }
            return
        }
        window.addGestureRecognizer(ActivityRecognizer { [weak self] in self?.activity() })
    }

    func activity() { lastActivity = Date() }

    private func check() {
        let minutes = UserDefaults.standard.object(forKey: "screensaverMinutes") as? Int ?? 5
        guard minutes > 0, !screensaverActive, isAllowed(), Date().timeIntervalSince(lastActivity) > Double(minutes) * 60 else { return }
        activate()
    }

    func activate() {
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) { screensaverActive = true }
        // Keep the wall up instead of the system screen saver, but let the Apple TV sleep after an hour.
        UIApplication.shared.isIdleTimerDisabled = true
        wakeTask?.cancel()
        wakeTask = Task {
            try? await Task.sleep(for: .seconds(3600))
            guard !Task.isCancelled else { return }
            UIApplication.shared.isIdleTimerDisabled = false
        }
    }

    func dismiss() {
        guard screensaverActive else { return }
        wakeTask?.cancel()
        UIApplication.shared.isIdleTimerDisabled = false
        lastActivity = Date()
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) { screensaverActive = false }
    }
}

private final class ActivityRecognizer: UIGestureRecognizer {
    private let onActivity: () -> Void

    init(onActivity: @escaping () -> Void) {
        self.onActivity = onActivity
        super.init(target: nil, action: nil)
        cancelsTouchesInView = false
        delaysTouchesBegan = false
        delaysTouchesEnded = false
        allowedTouchTypes = [NSNumber(value: UITouch.TouchType.indirect.rawValue), NSNumber(value: UITouch.TouchType.direct.rawValue)]
        allowedPressTypes = [UIPress.PressType.select, .menu, .playPause, .upArrow, .downArrow, .leftArrow, .rightArrow]
            .map { NSNumber(value: $0.rawValue) }
    }

    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent) {
        onActivity()
        state = .failed
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
        onActivity()
        state = .failed
    }

    override func canPrevent(_ preventedGestureRecognizer: UIGestureRecognizer) -> Bool { false }
}

// MARK: - Cover wall

/// The classic iTunes artwork screen saver: covers fill the screen edge to edge and flip, one after another,
/// to reveal other titles from the library.
struct CoverWallView: View {
    @EnvironmentObject private var model: AppModel
    @ObservedObject private var idle = IdleMonitor.shared
    @State private var tiles: [CoverTile] = []
    @State private var pool: [URL] = []
    @State private var visible = false
    @FocusState private var focused: Bool

    private let columns = 10
    private let rows = 4

    struct CoverTile: Identifiable {
        let id: Int
        var url: URL?
        var angle: Double = 0
    }

    var body: some View {
        GeometryReader { proxy in
            let width = proxy.size.width / CGFloat(columns)
            let height = width * 1.5
            let top = (proxy.size.height - height * CGFloat(rows)) / 2
            ZStack(alignment: .topLeading) {
                Color.black
                ForEach(tiles) { tile in
                    ZStack {
                        Theme.placeholder
                        RemoteImage(url: tile.url)
                    }
                    .frame(width: width - 2, height: height - 2)
                    .clipped()
                    .rotation3DEffect(.degrees(tile.angle), axis: (x: 0, y: 1, z: 0), perspective: 0.55)
                    .position(x: (CGFloat(tile.id % columns) + 0.5) * width, y: top + (CGFloat(tile.id / columns) + 0.5) * height)
                }
                RadialGradient(colors: [.clear, .black.opacity(0.55)], center: .center, startRadius: proxy.size.height * 0.45,
                               endRadius: proxy.size.width * 0.75)
            }
        }
        .ignoresSafeArea()
        .opacity(visible ? 1 : 0)
        .background(Color.black.ignoresSafeArea())
        .overlay {
            // Any press wakes the app without reaching the screen underneath.
            Button { idle.dismiss() } label: { Color.clear }
                .buttonStyle(InvisibleButtonStyle())
                .focused($focused)
                .onMoveCommand { _ in idle.dismiss() }
                .ignoresSafeArea()
        }
        .onPlayPauseCommand { idle.dismiss() }
        .onExitCommand { idle.dismiss() }
        .onAppear { focused = true }
        .task { await run() }
    }

    private func run() async {
        guard let client = model.client, let session = model.session else { return }
        let query = JellyfinClient.ItemQuery(types: ["Movie", "Series"], sortBy: "Random", limit: 160)
        let items = (try? await client.items(user: session.userID, query))?.items ?? []
        let urls = items.filter { $0.imageTags?["Primary"] != nil }.compactMap { client.artworkURL($0, .poster, width: 360) }
        guard !urls.isEmpty else { return }
        pool = urls.uniqued()
        // Small libraries repeat covers so the wall is always full; otherwise every cover appears once.
        let count = columns * rows
        let first = pool.count >= count ? Array(pool.shuffled().prefix(count)) : (0..<count).map { pool[$0 % pool.count] }.shuffled()
        await withTaskGroup(of: Void.self) { group in
            for url in first { group.addTask { _ = await ImagePipeline.shared.image(url) } }
        }
        tiles = first.enumerated().map { CoverTile(id: $0.offset, url: $0.element) }
        withAnimation(.easeIn(duration: 1.6)) { visible = true }
        Task.detached(priority: .background) { [pool] in
            for url in pool { _ = await ImagePipeline.shared.image(url) }
        }
        var recent: [Int] = []
        while !Task.isCancelled {
            try? await Task.sleep(for: .milliseconds(Int.random(in: 550...1100)))
            guard !Task.isCancelled else { return }
            // Now and then a short wave of neighbouring tiles, like the original.
            let wave = Int.random(in: 0..<9) == 0
            let start = Int.random(in: 0..<tiles.count)
            let indices = wave ? [start, start + 1, start + columns, start + columns + 1].filter { $0 < tiles.count } : [start]
            for (step, index) in indices.enumerated() where !recent.contains(index) {
                recent = Array((recent + [index]).suffix(12))
                let delay = Double(step) * 0.12
                Task {
                    try? await Task.sleep(for: .seconds(delay))
                    flip(index)
                }
            }
        }
    }

    /// Turns the tile edge-on, swaps the cover while it's invisible, and turns the new one into view.
    private func flip(_ index: Int) {
        let shown = Set(tiles.compactMap(\.url))
        let ready = pool.shuffled().filter { ImagePipeline.shared.cached($0) != nil && $0 != tiles[index].url }
        guard let next = ready.first(where: { !shown.contains($0) }) ?? (pool.count < tiles.count ? ready.first : nil) else { return }
        withAnimation(.easeIn(duration: 0.32)) {
            tiles[index].angle = 90
        } completion: {
            tiles[index].url = next
            tiles[index].angle = -90
            withAnimation(.easeOut(duration: 0.38)) { tiles[index].angle = 0 }
        }
    }
}

struct InvisibleButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.frame(maxWidth: .infinity, maxHeight: .infinity).contentShape(Rectangle())
    }
}
