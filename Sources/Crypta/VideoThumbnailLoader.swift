import AppKit
import AVFoundation

enum VideoThumbnailLoader {
    static func thumbnail(for video: CryptaVideo) async -> NSImage? {
        await Task.detached(priority: .utility) {
            do {
                let store = CryptaStore()
                let playback = try store.preparePlaybackURL(for: video, cleanCache: false)
                defer {
                    if playback.temporary {
                        try? FileManager.default.removeItem(at: playback.url)
                    }
                }
                return try await image(from: playback.url)
            } catch {
                return nil
            }
        }.value
    }

    private static func image(from url: URL) async throws -> NSImage? {
        let asset = AVURLAsset(url: url)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 192, height: 108)
        let cgImage: CGImage = try await withCheckedThrowingContinuation { continuation in
            generator.generateCGImageAsynchronously(
                for: CMTime(seconds: 0.2, preferredTimescale: 600)
            ) { cgImage, _, error in
                if let error {
                    continuation.resume(throwing: error)
                } else if let cgImage {
                    continuation.resume(returning: cgImage)
                } else {
                    continuation.resume(throwing: CryptaError.thumbnailFailed)
                }
            }
        }
        return NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
    }
}
