import AppKit
import Foundation

nonisolated struct V2ImportInspection: Sendable {
    let durationSeconds: Double?
    let thumbnailData: Data?

    static func inspect(url: URL, mediaType: MediaType) async -> V2ImportInspection {
        switch mediaType {
        case .video:
            async let thumbnail = VideoThumbnailLoader.thumbnailData(from: url)
            return V2ImportInspection(
                durationSeconds: VideoThumbnailLoader.duration(from: url),
                thumbnailData: await thumbnail
            )
        case .image:
            return V2ImportInspection(
                durationSeconds: nil,
                thumbnailData: imageThumbnailData(from: url)
            )
        }
    }

    static func imageThumbnailData(from url: URL) -> Data? {
        guard let image = NSImage(contentsOf: url) else { return nil }
        return jpegThumbnailData(from: image)
    }

    static func jpegThumbnailData(from image: NSImage) -> Data? {
        let maximumDimension: CGFloat = 1_600
        let sourceSize = image.size
        guard sourceSize.width > 0, sourceSize.height > 0 else { return nil }
        let scale = min(
            1,
            maximumDimension / sourceSize.width,
            maximumDimension / sourceSize.height
        )
        let targetSize = NSSize(
            width: max(1, sourceSize.width * scale),
            height: max(1, sourceSize.height * scale)
        )
        let rendered = NSImage(size: targetSize)
        rendered.lockFocus()
        NSGraphicsContext.current?.imageInterpolation = .high
        image.draw(
            in: NSRect(origin: .zero, size: targetSize),
            from: NSRect(origin: .zero, size: sourceSize),
            operation: .copy,
            fraction: 1
        )
        rendered.unlockFocus()
        guard let tiffData = rendered.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiffData) else {
            return nil
        }
        return bitmap.representation(
            using: .jpeg,
            properties: [.compressionFactor: 0.82]
        )
    }
}
