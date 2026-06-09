import AppKit

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
        await thumbnail(for: video, store: CryptaStore())
    }

    static func thumbnail(for video: CryptaVideo, store: CryptaStore) async -> NSImage? {
        await coordinator.thumbnail(for: video, store: store)
    }

    fileprivate static func loadOrGenerateThumbnail(for video: CryptaVideo, store: CryptaStore) async -> NSImage? {
        do {
            try Task.checkCancellation()
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
        if video.isImage {
            guard let image = NSImage(contentsOf: playback.url) else {
                throw CryptaError.thumbnailFailed
            }
            return image
        }
        guard let image = try await image(from: playback.url, durationSeconds: video.durationSeconds) else {
            throw CryptaError.thumbnailFailed
        }
        return image
    }

    static func image(from url: URL) async throws -> NSImage? {
        try await image(from: url, durationSeconds: nil)
    }

    private static func image(from url: URL, durationSeconds: Double?) async throws -> NSImage? {
        let duration = durationSeconds ?? (try? ffprobeDuration(from: url))
        let seconds = thumbnailSeconds(for: duration)
        return try ffmpegImage(from: url, seconds: seconds)
    }

    private static func ffmpegImage(from url: URL, seconds: Double) throws -> NSImage {
        guard let ffmpegURL = ffmpegExecutableURL() else {
            throw CryptaError.thumbnailFailed
        }

        let outputDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("CryptaThumbnail-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: outputDirectory)
        }

        let outputURL = outputDirectory.appendingPathComponent("thumbnail.png", isDirectory: false)
        let process = Process()
        process.executableURL = ffmpegURL
        process.arguments = [
            "-v", "error",
            "-y",
            "-ss", String(format: "%.3f", seconds),
            "-i", url.path,
            "-frames:v", "1",
            "-an",
            "-sn",
            "-vf", "scale=min(\(Int(maximumThumbnailDimension))\\,iw):-2",
            outputURL.path
        ]
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()

        guard process.terminationStatus == 0,
              FileManager.default.fileExists(atPath: outputURL.path),
              let image = NSImage(contentsOf: outputURL) else {
            throw CryptaError.thumbnailFailed
        }
        return image
    }

    private static func ffprobeDuration(from url: URL) throws -> Double {
        guard let ffprobeURL = ffprobeExecutableURL() else {
            throw CryptaError.thumbnailFailed
        }

        let output = Pipe()
        let process = Process()
        process.executableURL = ffprobeURL
        process.arguments = [
            "-v", "error",
            "-show_entries", "format=duration",
            "-of", "default=noprint_wrappers=1:nokey=1",
            url.path
        ]
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()

        let data = output.fileHandleForReading.readDataToEndOfFile()
        guard process.terminationStatus == 0,
              let value = String(data: data, encoding: .utf8),
              let duration = Double(value.trimmingCharacters(in: .whitespacesAndNewlines)),
              duration.isFinite,
              duration > 0 else {
            throw CryptaError.thumbnailFailed
        }
        return duration
    }

    private static func ffmpegExecutableURL() -> URL? {
        let fileManager = FileManager.default
        let candidates = [
            "/opt/homebrew/bin/ffmpeg",
            "/usr/local/bin/ffmpeg",
            "/usr/bin/ffmpeg"
        ]
        return candidates
            .map { URL(fileURLWithPath: $0) }
            .first { fileManager.isExecutableFile(atPath: $0.path) }
    }

    private static func ffprobeExecutableURL() -> URL? {
        let fileManager = FileManager.default
        let candidates = [
            "/opt/homebrew/bin/ffprobe",
            "/usr/local/bin/ffprobe",
            "/usr/bin/ffprobe"
        ]
        return candidates
            .map { URL(fileURLWithPath: $0) }
            .first { fileManager.isExecutableFile(atPath: $0.path) }
    }

    private static func thumbnailSeconds(for duration: Double?) -> Double {
        guard let duration, duration.isFinite, duration > 0 else {
            return 0.2
        }
        return max(0.2, duration / 2)
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

    func thumbnail(for video: CryptaVideo, store: CryptaStore) async -> NSImage? {
        let cacheKey = key(for: video)
        if let image = cache.object(forKey: cacheKey) {
            return image
        }

        if let task = inFlightTasks[video.id] {
            return await task.value
        }

        let task = Task.detached(priority: .utility) {
            await VideoThumbnailLoader.loadOrGenerateThumbnail(for: video, store: store)
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
