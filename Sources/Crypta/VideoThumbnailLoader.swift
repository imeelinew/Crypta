import AppKit
import AVFoundation

enum VideoThumbnailLoader {
    static func thumbnail(for video: CryptaVideo) async -> NSImage? {
        await Task.detached(priority: .utility) {
            do {
                let store = CryptaStore()
                let playback = try store.preparePlaybackURL(for: video)
                defer {
                    if let cleanupURL = playback.cleanupURL {
                        try? FileManager.default.removeItem(at: cleanupURL)
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
        let requestedTime = try await thumbnailTime(for: asset)
        let cgImage: CGImage = try await withCheckedThrowingContinuation { continuation in
            generator.generateCGImageAsynchronously(
                for: requestedTime
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

    private static func thumbnailTime(for asset: AVURLAsset) async throws -> CMTime {
        let durationTime = try await asset.load(.duration)
        let duration = CMTimeGetSeconds(durationTime)
        let seconds = duration.isFinite && duration > 0 ? duration / 2 : 0.2
        return CMTime(seconds: seconds, preferredTimescale: 600)
    }
}
