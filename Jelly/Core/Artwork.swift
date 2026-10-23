import Foundation

enum ArtworkStyle { case poster, landscape, backdrop }

extension JellyfinClient {
    func artworkURL(_ item: BaseItem, _ style: ArtworkStyle, width: Int) -> URL? {
        let tags = item.imageTags ?? [:]
        func image(_ id: String?, _ kind: ImageKind, _ tag: String?) -> URL? {
            guard let id, let tag else { return nil }
            return imageURL(item: id, kind: kind, tag: tag, width: width)
        }
        let backdrop = image(item.id, .backdrop, item.backdropImageTags?.first)
            ?? image(item.parentBackdropItemId, .backdrop, item.parentBackdropImageTags?.first)
        switch style {
        case .poster:
            if item.isEpisode, let series = image(item.seriesId, .primary, item.seriesPrimaryImageTag) { return series }
            return image(item.id, .primary, tags["Primary"])
        case .landscape:
            if item.isEpisode, let still = image(item.id, .primary, tags["Primary"]) { return still }
            if item.isFolder, let primary = image(item.id, .primary, tags["Primary"]) { return primary }
            return image(item.id, .thumb, tags["Thumb"]) ?? image(item.parentThumbItemId, .thumb, item.parentThumbImageTag)
                ?? backdrop ?? image(item.id, .primary, tags["Primary"])
        case .backdrop:
            return backdrop ?? image(item.id, .thumb, tags["Thumb"]) ?? image(item.parentThumbItemId, .thumb, item.parentThumbImageTag)
        }
    }

    func logoURL(_ item: BaseItem, width: Int = 800) -> URL? {
        if let tag = item.imageTags?["Logo"] { return imageURL(item: item.id, kind: .logo, tag: tag, width: width) }
        if let id = item.parentLogoItemId, let tag = item.parentLogoImageTag { return imageURL(item: id, kind: .logo, tag: tag, width: width) }
        return nil
    }
}
