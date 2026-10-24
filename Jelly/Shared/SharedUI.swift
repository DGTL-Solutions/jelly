import SwiftUI

enum Theme {
    static let edge: CGFloat = 80
    static let background = Color(red: 0.035, green: 0.04, blue: 0.06)
    static let accent = Color(red: 0.55, green: 0.47, blue: 1.0)
    static let brand = LinearGradient(colors: [Color(red: 0.67, green: 0.36, blue: 0.86), Color(red: 0.0, green: 0.64, blue: 0.86)],
                                      startPoint: .topLeading, endPoint: .bottomTrailing)
    static let placeholder = LinearGradient(colors: [Color(white: 0.16), Color(white: 0.09)], startPoint: .top, endPoint: .bottom)
}

// MARK: - Images

actor ImagePipeline {
    static let shared = ImagePipeline()
    nonisolated(unsafe) private let cache: NSCache<NSURL, UIImage> = {
        let cache = NSCache<NSURL, UIImage>()
        cache.totalCostLimit = 180 * 1024 * 1024
        return cache
    }()
    private var running: [URL: Task<UIImage?, Never>] = [:]
    private let session: URLSession = {
        let configuration = URLSessionConfiguration.default
        configuration.urlCache = URLCache(memoryCapacity: 16 * 1024 * 1024, diskCapacity: 400 * 1024 * 1024)
        configuration.requestCachePolicy = .returnCacheDataElseLoad
        return URLSession(configuration: configuration)
    }()

    nonisolated func cached(_ url: URL) -> UIImage? { cache.object(forKey: url as NSURL) }

    func image(_ url: URL, authorization: String? = nil) async -> UIImage? {
        if let image = cache.object(forKey: url as NSURL) { return image }
        if let task = running[url] { return await task.value }
        let session = session
        var request = URLRequest(url: url)
        if let authorization { request.setValue(authorization, forHTTPHeaderField: "Authorization") }
        let task = Task<UIImage?, Never> { [request] in
            guard let (data, response) = try? await session.data(for: request),
                  (response as? HTTPURLResponse)?.statusCode == 200,
                  let image = UIImage(data: data) else { return nil }
            return await image.byPreparingForDisplay() ?? image
        }
        running[url] = task
        let image = await task.value
        running[url] = nil
        if let image {
            cache.setObject(image, forKey: url as NSURL, cost: Int(image.size.width * image.size.height * image.scale * image.scale * 4))
        }
        return image
    }
}

/// Fills the frame its parent gives it and fades the image in once loaded.
struct RemoteImage: View {
    let url: URL?
    var contentMode: ContentMode = .fill
    @State private var image: UIImage?

    init(url: URL?, contentMode: ContentMode = .fill) {
        self.url = url
        self.contentMode = contentMode
        _image = State(initialValue: url.flatMap { ImagePipeline.shared.cached($0) })
    }

    var body: some View {
        Color.clear
            .overlay {
                if let image {
                    Image(uiImage: image).resizable().aspectRatio(contentMode: contentMode).transition(.opacity)
                }
            }
            .clipped()
            .task(id: url) {
                guard let url else { image = nil; return }
                if let cached = ImagePipeline.shared.cached(url) { image = cached; return }
                let loaded = await ImagePipeline.shared.image(url)
                guard !Task.isCancelled else { return }
                withAnimation(.easeOut(duration: 0.3)) { image = loaded }
            }
    }
}

// MARK: - Ratings

/// IMDb and Rotten Tomatoes scores, each switchable in the settings.
struct RatingBadges: View {
    let item: BaseItem
    @AppStorage("showIMDb") private var showIMDb = true
    @AppStorage("showRottenTomatoes") private var showRottenTomatoes = true
    @State private var imdb: IMDbRating?

    var body: some View {
        HStack(spacing: 22) {
            if !IMDbRatings.isAvailable, showIMDb, let rating = item.communityRating, rating > 0 {
                HStack(spacing: 10) {
                    Image(systemName: "star.fill").foregroundStyle(.yellow)
                    Text(rating.formatted(.number.precision(.fractionLength(1)))).font(.callout.weight(.semibold))
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel("Bewertung \(rating.formatted(.number.precision(.fractionLength(1))))")
            }
            if showIMDb, let imdb {
                HStack(spacing: 10) {
                    Text("IMDb")
                        .font(.system(size: 19, weight: .heavy))
                        .foregroundStyle(.black)
                        .padding(.horizontal, 8).padding(.vertical, 3)
                        .background(Color(red: 0.96, green: 0.77, blue: 0.09), in: RoundedRectangle(cornerRadius: 5, style: .continuous))
                    Text(imdb.rating.formatted(.number.precision(.fractionLength(1)))).font(.callout.weight(.semibold))
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel("IMDb \(imdb.rating.formatted(.number.precision(.fractionLength(1))))")
            }
            if showRottenTomatoes, let score = item.criticRating {
                HStack(spacing: 10) {
                    if IMDbRatings.isAvailable {
                        TomatoIcon(fresh: score >= 60)
                    } else {
                        // Without the brand: a neutral critics' score from the server's metadata.
                        Image(systemName: score >= 60 ? "hand.thumbsup.fill" : "hand.thumbsdown.fill")
                            .foregroundStyle(score >= 60 ? .green : .orange)
                    }
                    Text((score / 100).formatted(.percent.precision(.fractionLength(0)))).font(.callout.weight(.semibold))
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel(IMDbRatings.isAvailable ? String(localized: "Rotten Tomatoes \(Int(score)) Prozent")
                                                            : String(localized: "Kritiker \(Int(score)) Prozent", comment: "Critics' score, e.g. Kritiker 85 Prozent"))
            }
        }
        .task(id: "\(item.imdbID ?? "")-\(showIMDb)") {
            guard IMDbRatings.isAvailable, showIMDb, let id = item.imdbID else { imdb = nil; return }
            imdb = await IMDbRatings.shared.rating(for: id)
        }
    }
}

/// Fresh: a red tomato with green leaves. Rotten: a green splat.
struct TomatoIcon: View {
    let fresh: Bool

    var body: some View {
        ZStack {
            if fresh {
                Circle()
                    .fill(LinearGradient(colors: [Color(red: 0.99, green: 0.3, blue: 0.18), Color(red: 0.82, green: 0.1, blue: 0.06)],
                                         startPoint: .topLeading, endPoint: .bottomTrailing))
                    .frame(width: 28, height: 26)
                    .offset(y: 3)
                Image(systemName: "leaf.fill")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(Color(red: 0.2, green: 0.62, blue: 0.2))
                    .rotationEffect(.degrees(-40))
                    .offset(y: -10)
            } else {
                Image(systemName: "burst.fill")
                    .font(.system(size: 28))
                    .foregroundStyle(Color(red: 0.04, green: 0.78, blue: 0.33))
            }
        }
        .frame(width: 32, height: 32)
    }
}
