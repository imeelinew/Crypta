import AppKit
import AVFoundation

enum VideoThumbnailLoader {
    @MainActor
    private static let coordinator = VideoThumbnailCoordinator()
    private static let generationGate = ThumbnailGenerationGate(maxConcurrentCount: 2)
    private static let maximumThumbnailDimension: CGFloat = 1600

    @MainActor
    static func cachedThumbnail(for video: CryptaVideo) -> NSImage? {
        coordinator.cachedThumbnail(for: video)
    }

    @MainActor
    static func removeCachedThumbnail(for video: CryptaVideo) {
        coordinator.removeCachedThumbnail(for: video)
    }

    @MainActor
    static func clearMemoryCache() {
        coordinator.clearMemoryCache()
    }

    static func thumbnail(for video: CryptaVideo) async -> NSImage? {
        await coordinator.thumbnail(for: video)
    }

    fileprivate static func loadOrGenerateThumbnail(for video: CryptaVideo) async -> NSImage? {
        do {
            try Task.checkCancellation()
            let store = CryptaStore()
            if let data = try store.loadThumbnailData(for: video),
               let image = NSImage(data: data) {
                return image
            }

            try Task.checkCancellation()
            await generationGate.wait()
            defer {
                Task {
                    await generationGate.signal()
                }
            }

            try Task.checkCancellation()
            if let data = try store.loadThumbnailData(for: video),
               let image = NSImage(data: data) {
                return image
            }

            let image = try await thumbnailFromPlaybackURL(for: video, store: store)
            try Task.checkCancellation()
            if let data = jpegData(from: image) {
                try? store.saveThumbnailData(data, for: video)
            }
            return image
        } catch is CancellationError {
            return nil
        } catch {
            return nil
        }
    }

    private static func thumbnailFromPlaybackURL(for video: CryptaVideo, store: CryptaStore) async throws -> NSImage {
        let playback = try store.preparePlaybackURL(for: video)
        defer {
            if let cleanupURL = playback.cleanupURL {
                try? FileManager.default.removeItem(at: cleanupURL)
            }
        }
        guard let image = try await image(from: playback.url) else {
            throw CryptaError.thumbnailFailed
        }
        return image
    }

    private static func image(from url: URL) async throws -> NSImage? {
        let asset = AVURLAsset(url: url)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(
            width: maximumThumbnailDimension,
            height: maximumThumbnailDimension
        )
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

    private static func jpegData(from image: NSImage) -> Data? {
        guard let tiffData = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiffData) else {
            return nil
        }
        return bitmap.representation(using: .jpeg, properties: [.compressionFactor: 0.82])
    }
}

@MainActor
private final class VideoThumbnailCoordinator {
    private let cache = NSCache<NSUUID, NSImage>()
    private var inFlightTasks: [UUID: Task<NSImage?, Never>] = [:]

    init() {
        cache.countLimit = 80
        cache.totalCostLimit = 64 * 1024 * 1024
    }

    func cachedThumbnail(for video: CryptaVideo) -> NSImage? {
        cache.object(forKey: key(for: video))
    }

    func thumbnail(for video: CryptaVideo) async -> NSImage? {
        let cacheKey = key(for: video)
        if let image = cache.object(forKey: cacheKey) {
            return image
        }

        if let task = inFlightTasks[video.id] {
            return await task.value
        }

        let task = Task.detached(priority: .utility) {
            await VideoThumbnailLoader.loadOrGenerateThumbnail(for: video)
        }
        inFlightTasks[video.id] = task

        let image = await task.value
        inFlightTasks[video.id] = nil

        if let image {
            cache.setObject(image, forKey: cacheKey, cost: Self.cost(of: image))
        }

        return image
    }

    func removeCachedThumbnail(for video: CryptaVideo) {
        cache.removeObject(forKey: key(for: video))
        inFlightTasks[video.id]?.cancel()
        inFlightTasks[video.id] = nil
    }

    func clearMemoryCache() {
        cache.removeAllObjects()
    }

    private func key(for video: CryptaVideo) -> NSUUID {
        video.id as NSUUID
    }

    private static func cost(of image: NSImage) -> Int {
        if let representation = image.representations.first {
            return max(1, representation.pixelsWide * representation.pixelsHigh * 4)
        }
        return max(1, Int(image.size.width * image.size.height * 4))
    }
}

private actor ThumbnailGenerationGate {
    private let maxConcurrentCount: Int
    private var availableCount: Int
    private var waiters: [CheckedContinuation<Void, Never>] = []

    init(maxConcurrentCount: Int) {
        self.maxConcurrentCount = max(1, maxConcurrentCount)
        self.availableCount = max(1, maxConcurrentCount)
    }

    func wait() async {
        if availableCount > 0 {
            availableCount -= 1
            return
        }

        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    func signal() {
        if waiters.isEmpty {
            availableCount = min(availableCount + 1, maxConcurrentCount)
        } else {
            waiters.removeFirst().resume()
        }
    }
}
