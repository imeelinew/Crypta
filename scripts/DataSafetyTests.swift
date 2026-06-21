import AppKit
import AVFoundation
import Foundation

@main
struct DataSafetyTests {
    static func main() async throws {
        try testEncryptionLevelPolicies()
        try testVideoSortModes()
        try testLegacyVideosDefaultToSafeLibraryKind()
        try await testMissingKeyDoesNotCreateReplacementWhenIndexExists()
        try await testMissingKeyDoesNotCreateReplacementWhenVaultContainsProtectedFiles()
        try await testCorruptedIndexFallsBackToBackup()
        try await testVideoLibraryImportsStayEncrypted()
        try await testEncryptedMediaDataSourceReadsRangesWithoutTemporaryPlaintext()
        try await testInMemoryPlaybackSourceLoadsSyntheticAsset()
        try await testEncryptedVideoThumbnailDoesNotMaterializePlaybackFile()
        try await testSubtitlesEmbedIntoEncryptedVideoAtRest()
        try await testConcurrentSubtitleCommitDoesNotLosePlaybackPosition()
        try testSubtitleConfigurationTranslatesByDefaultWhenKeyExists()
        try await testSubtitleProcessCancellationReportsCancellation()
        try await testSubtitleTranslationRepairsMissingIDs()
        try await testEncryptedImageImportsStayEncryptedAndThumbnailsAreProtected()
        try await testImagePlaybackDecryptsOnlyRequestedImage()
        try await testMkvThumbnailUsesMiddleFrame()
        try await testFailedImportKeepsSourceFileUntilIndexIsSaved()
        try await testFailedDeleteKeepsBlobWhenIndexCannotBeSaved()
        try await testMediaLeaseOwnsTemporaryPlaintext()
        try await testImageGroupPreparationIsSharedAndLeaseSurvivesInvalidation()
        try await testMissingImageGroupFileIsRebuilt()
        try await testStartingAnotherSessionDoesNotDeleteLiveFiles()
        try await testSessionStartupRemovesOrphanedFiles()
        try await testExportDecryptRemovesVideoFromVaultAfterIndexSave()
        try await testExportDecryptUsesUniqueDestinationName()
        try await testFailedExportKeepsEncryptedBlobAndIndexEntry()
        try await testFailedIndexSaveAfterExportKeepsEncryptedBlobAndIndexEntry()
        try await testExportRejectsVaultInternalDestination()
        if let smokeMediaPath = ProcessInfo.processInfo.environment["CRYPTA_SUBTITLE_SMOKE_MEDIA"],
           !smokeMediaPath.isEmpty {
            try await testSubtitleGenerationSmoke(mediaURL: URL(fileURLWithPath: smokeMediaPath))
        }
        print("Data safety tests passed")
    }

    private static func testEncryptionLevelPolicies() throws {
        try expect(!EncryptionLevel.standard.requiresAuthentication, "Standard encryption should not authenticate.")
        try expect(EncryptionLevel.extended.requiresAuthentication, "Extended encryption should authenticate.")
        try expect(EncryptionLevel.maximum.requiresAuthentication, "Maximum encryption should authenticate.")
        try expect(!EncryptionLevel.extended.locksOnGroupChange, "Extended encryption should remain unlocked across groups.")
        try expect(EncryptionLevel.maximum.locksOnGroupChange, "Maximum encryption should lock on group change.")
        try expect(EncryptionLevel.extended.allowsManualLock, "Extended encryption should allow manual locking.")
        try expect(!EncryptionLevel.maximum.allowsManualLock, "Maximum encryption should not offer manual locking.")
    }

    private static func testVideoSortModes() throws {
        let older = Date(timeIntervalSince1970: 1_700_000_000)
        let newer = Date(timeIntervalSince1970: 1_800_000_000)
        let videos = [
            sampleVideo(displayName: "Video 10", importedAt: older),
            sampleVideo(displayName: "Video 2", importedAt: older),
            sampleVideo(displayName: "Alpha", importedAt: newer)
        ]

        try expect(
            VideoSortMode.name.sorted(videos).map(\.displayName) == ["Alpha", "Video 2", "Video 10"],
            "Name sort should use localized standard ordering."
        )
        try expect(
            VideoSortMode.recentlyAdded.sorted(videos).map(\.displayName) == ["Alpha", "Video 2", "Video 10"],
            "Recently-added sort should use imported date with name fallback."
        )
    }

    private static func testLegacyVideosDefaultToSafeLibraryKind() throws {
        let encryptedJSON = Data("""
        {
          "id": "00000000-0000-0000-0000-000000000001",
          "displayName": "Legacy Secret",
          "originalExtension": "mp4",
          "storageState": "encrypted",
          "plainFileName": null,
          "encryptedFileName": "blob",
          "importedAt": 0,
          "byteCount": 12,
          "durationSeconds": null
        }
        """.utf8)
        let plainJSON = Data("""
        {
          "id": "00000000-0000-0000-0000-000000000002",
          "displayName": "Legacy Plain",
          "originalExtension": "mp4",
          "storageState": "plain",
          "plainFileName": "Legacy Plain.mp4",
          "encryptedFileName": null,
          "importedAt": 0,
          "byteCount": 12,
          "durationSeconds": null
        }
        """.utf8)
        let decoder = JSONDecoder()

        let encryptedVideo = try decoder.decode(CryptaVideo.self, from: encryptedJSON)
        let plainVideo = try decoder.decode(CryptaVideo.self, from: plainJSON)

        try expect(
            encryptedVideo.libraryKind == .encrypted,
            "Legacy encrypted videos should default to the encrypted section."
        )
        try expect(
            plainVideo.libraryKind == .encrypted,
            "Legacy plain videos without an explicit category should stay out of the video section."
        )
        try expect(
            encryptedVideo.mediaType == .video,
            "Legacy encrypted videos should default to video media type."
        )
        try expect(
            plainVideo.mediaType == .video,
            "Legacy plain videos should default to video media type."
        )
    }

    private static func testMissingKeyDoesNotCreateReplacementWhenIndexExists() async throws {
        let harness = try StoreHarness()
        defer { harness.cleanup() }

        let seededStore = CryptaStore(
            locations: harness.locations,
            keyStore: InMemoryKeyStore(data: harness.keyData)
        )
        try seededStore.saveIndex(CryptaIndex(videos: [harness.sampleVideo(encryptedFileName: "blob")]))

        let missingKeyStore = InMemoryKeyStore(data: nil)
        let store = CryptaStore(locations: harness.locations, keyStore: missingKeyStore)

        do {
            _ = try store.loadIndex()
            throw TestFailure("Loading an existing encrypted index without a key should fail closed.")
        } catch CryptaError.missingEncryptionKey {
            try expect(missingKeyStore.savedKeyCount == 0, "Missing-key load created a replacement key.")
        }
    }

    private static func testMissingKeyDoesNotCreateReplacementWhenVaultContainsProtectedFiles() async throws {
        let harness = try StoreHarness()
        defer { harness.cleanup() }

        try FileManager.default.createDirectory(at: harness.locations.moviesVault, withIntermediateDirectories: true)
        try Data([1, 2, 3]).write(to: harness.locations.moviesVault.appendingPathComponent("orphaned-blob"))

        let keyStore = InMemoryKeyStore(data: nil)
        let store = CryptaStore(locations: harness.locations, keyStore: keyStore)

        do {
            try store.saveIndex(CryptaIndex())
            throw TestFailure("Saving with protected vault files but no key should fail closed.")
        } catch CryptaError.protectedDataRequiresExistingKey {
            try expect(keyStore.savedKeyCount == 0, "Protected vault save created a replacement key.")
        }
    }

    private static func testCorruptedIndexFallsBackToBackup() async throws {
        let harness = try StoreHarness()
        defer { harness.cleanup() }

        let store = CryptaStore(locations: harness.locations, keyStore: InMemoryKeyStore(data: harness.keyData))
        try store.saveIndex(CryptaIndex(videos: [harness.sampleVideo(displayName: "First", encryptedFileName: "first-blob")]))
        try store.saveIndex(CryptaIndex(videos: [harness.sampleVideo(displayName: "Second", encryptedFileName: "second-blob")]))
        try Data("corrupted".utf8).write(to: harness.locations.encryptedIndex, options: [.atomic])

        let recovered = try store.loadIndex()
        try expect(recovered.videos.map(\.displayName) == ["First"], "Corrupted index did not recover from backup.")
    }

    private static func testVideoLibraryImportsStayEncrypted() async throws {
        let harness = try StoreHarness()
        defer { harness.cleanup() }

        let plaintext = Data("casual-but-private-video".utf8)
        let source = harness.root.appendingPathComponent("Casual.mkv", isDirectory: false)
        try plaintext.write(to: source)
        let store = CryptaStore(locations: harness.locations, keyStore: InMemoryKeyStore(data: harness.keyData))

        let video = try await store.importVideo(from: source, libraryKind: .video, mediaType: .video)

        try expect(video.libraryKind == .video, "Video-section import did not keep its semantic category.")
        try expect(video.mediaType == .video, "Video import did not set video media type.")
        try expect(video.storageState == .encrypted, "Video-section import should still be encrypted by default.")
        try expect(video.plainFileName == nil, "Video-section import created a long-lived plain file.")
        guard let encryptedFileName = video.encryptedFileName else {
            throw TestFailure("Video-section import did not create an encrypted blob.")
        }

        let blob = harness.locations.moviesVault.appendingPathComponent(encryptedFileName)
        try expect(FileManager.default.fileExists(atPath: blob.path), "Encrypted blob was not written.")
        try expect(try Data(contentsOf: blob) != plaintext, "Encrypted blob contains plaintext bytes.")

        let playback = try store.preparePlaybackURL(for: video)
        defer {
            if let cleanupURL = playback.cleanupURL {
                try? FileManager.default.removeItem(at: cleanupURL)
            }
        }
        try expect(try Data(contentsOf: playback.url) == plaintext, "Temporary playback file did not restore plaintext.")
        try expect(playback.cleanupURL != nil, "Encrypted video playback did not use a cleanup directory.")
        try expect(
            !playback.url.path.hasPrefix(harness.locations.vaultPackage.path + "/"),
            "Temporary playback file was written inside the vault package."
        )
    }

    private static func testSubtitlesEmbedIntoEncryptedVideoAtRest() async throws {
        guard let ffmpegURL = ffmpegExecutableURL() else {
            print("Skipping subtitle embed test: ffmpeg not found")
            return
        }

        let harness = try StoreHarness()
        defer { harness.cleanup() }

        let source = harness.root.appendingPathComponent("Subtitle.mkv", isDirectory: false)
        try runFFmpeg(
            ffmpegURL,
            arguments: [
                "-v", "error",
                "-f", "lavfi",
                "-i", "color=c=black:size=160x90:rate=1:d=1",
                "-c:v", "libx264",
                "-pix_fmt", "yuv420p",
                source.path
            ]
        )
        let sourceData = try Data(contentsOf: source)

        let store = CryptaStore(locations: harness.locations, keyStore: InMemoryKeyStore(data: harness.keyData))
        let video = try await store.importVideo(from: source, libraryKind: .video, mediaType: .video)
        let sourceSRT = "1\n00:00:00,000 --> 00:00:01,000\nHello\n"

        let sessionDirectory = harness.root.appendingPathComponent("Session", isDirectory: true)
        try FileManager.default.createDirectory(at: sessionDirectory, withIntermediateDirectories: true)
        let mediaURL = sessionDirectory.appendingPathComponent("media.mkv", isDirectory: false)
        let srtURL = sessionDirectory.appendingPathComponent("media.srt", isDirectory: false)
        let embeddedURL = sessionDirectory.appendingPathComponent("media.embedded.mkv", isDirectory: false)
        try store.materializeMedia(video, to: mediaURL)
        try sourceSRT.write(to: srtURL, atomically: true, encoding: .utf8)
        try runFFmpeg(
            ffmpegURL,
            arguments: [
                "-y",
                "-loglevel", "error",
                "-i", mediaURL.path,
                "-i", srtURL.path,
                "-map", "0:v",
                "-map", "0:a?",
                "-map", "1",
                "-map_metadata", "0",
                "-map_chapters", "0",
                "-c", "copy",
                "-c:s", "copy",
                "-metadata:s:s:0", "title=Crypta Subtitles",
                "-metadata:s:s:0", "handler_name=Crypta Subtitles",
                "-disposition:s:0", "default",
                embeddedURL.path
            ]
        )

        let updated = try store.commitModifiedVideo(at: embeddedURL, for: video)
        try expect(updated.hasEmbeddedSubtitles, "Embedded subtitle flag was not saved.")

        guard let encryptedFileName = updated.encryptedFileName else {
            throw TestFailure("Encrypted video file name was not saved.")
        }
        let encryptedURL = harness.locations.moviesVault.appendingPathComponent(encryptedFileName)
        try expect(FileManager.default.fileExists(atPath: encryptedURL.path), "Encrypted video blob was not written.")
        let encryptedData = try Data(contentsOf: encryptedURL)
        try expect(encryptedData != sourceData, "Video was stored as plaintext.")

        let playbackDirectory = harness.root.appendingPathComponent("Playback", isDirectory: true)
        try FileManager.default.createDirectory(at: playbackDirectory, withIntermediateDirectories: true)
        let playbackURL = playbackDirectory.appendingPathComponent("playback.mkv", isDirectory: false)
        try store.materializeMedia(updated, to: playbackURL)
        try expect(subtitleStreamCount(at: playbackURL) == 1, "Embedded subtitle streams were not written into the video.")
    }

    private static func testEncryptedMediaDataSourceReadsRangesWithoutTemporaryPlaintext() async throws {
        let harness = try StoreHarness()
        defer { harness.cleanup() }

        let plaintext = patternedData(count: 4 * 1024 * 1024 + 257)
        let store = CryptaStore(locations: harness.locations, keyStore: InMemoryKeyStore(data: harness.keyData))
        let video = try await harness.importEncryptedVideo(named: "Memory.mp4", data: plaintext, store: store)

        let dataSource = try store.inMemoryMediaDataSource(for: video)
        try expect(dataSource.byteCount == Int64(plaintext.count), "Memory data source reported the wrong byte count.")
        try expect(
            try dataSource.data(offset: 0, length: 32) == plaintext.subdata(in: 0..<32),
            "Memory data source did not return the first range."
        )

        let boundaryStart = 4 * 1024 * 1024 - 16
        try expect(
            try dataSource.data(offset: Int64(boundaryStart), length: 64) == plaintext.subdata(in: boundaryStart..<(boundaryStart + 64)),
            "Memory data source did not read across an encrypted chunk boundary."
        )

        let tailStart = plaintext.count - 40
        try expect(
            try dataSource.data(offset: Int64(tailStart), length: 80) == plaintext.subdata(in: tailStart..<plaintext.count),
            "Memory data source did not clamp the final range to the media length."
        )
        try expect(
            regularFiles(under: harness.locations.cacheRoot).isEmpty,
            "Memory playback source created cache/session files."
        )
    }

    private static func testEncryptedVideoThumbnailDoesNotMaterializePlaybackFile() async throws {
        let harness = try StoreHarness()
        defer { harness.cleanup() }

        let plaintext = Data("synthetic-encrypted-video".utf8)
        let store = CryptaStore(locations: harness.locations, keyStore: InMemoryKeyStore(data: harness.keyData))
        let video = try await harness.importEncryptedVideo(named: "NoThumbnail.mp4", data: plaintext, store: store)

        let thumbnail = await VideoThumbnailLoader.thumbnail(for: video, store: store)
        try expect(thumbnail == nil, "Encrypted video without a cached thumbnail should not generate one from plaintext.")
        try expect(
            regularFiles(under: harness.locations.cacheRoot).isEmpty,
            "Encrypted video thumbnail generation materialized a playback file."
        )
    }

    private static func testInMemoryPlaybackSourceLoadsSyntheticAsset() async throws {
        guard let ffmpegURL = ffmpegExecutableURL() else {
            print("Skipping in-memory playback asset test: ffmpeg not found")
            return
        }

        let harness = try StoreHarness()
        defer { harness.cleanup() }

        let source = harness.root.appendingPathComponent("MemoryAsset.mp4", isDirectory: false)
        try runFFmpeg(
            ffmpegURL,
            arguments: [
                "-v", "error",
                "-f", "lavfi",
                "-i", "color=c=black:size=160x90:rate=1:d=1",
                "-c:v", "libx264",
                "-pix_fmt", "yuv420p",
                source.path
            ]
        )

        let store = CryptaStore(locations: harness.locations, keyStore: InMemoryKeyStore(data: harness.keyData))
        let video = try await store.importVideo(from: source, storageState: .encrypted)
        let dataSource = try store.inMemoryMediaDataSource(for: video)
        let playbackSource = InMemoryMediaPlaybackSource(dataSource: dataSource)
        let item = playbackSource.makePlayerItem(for: video)
        let duration = try await item.asset.load(.duration)
        playbackSource.invalidate()

        try expect(
            CMTimeGetSeconds(duration).isFinite && CMTimeGetSeconds(duration) > 0,
            "AVFoundation did not load duration from the in-memory playback source."
        )
        try expect(
            regularFiles(under: harness.locations.cacheRoot).isEmpty,
            "In-memory AVFoundation asset loading created cache/session files."
        )
    }

    private static func testConcurrentSubtitleCommitDoesNotLosePlaybackPosition() async throws {
        let harness = try StoreHarness()
        defer { harness.cleanup() }

        let source = harness.root.appendingPathComponent("Concurrent.mp4", isDirectory: false)
        try Data("original-private-video".utf8).write(to: source)

        let store = CryptaStore(locations: harness.locations, keyStore: InMemoryKeyStore(data: harness.keyData))
        let video = try await store.importVideo(from: source, libraryKind: .video, mediaType: .video)

        let modified = harness.root.appendingPathComponent("Concurrent.modified.mp4", isDirectory: false)
        try Data(repeating: 42, count: 32 * 1024 * 1024).write(to: modified)

        async let subtitleCommit = Task.detached(priority: .userInitiated) {
            try store.commitModifiedVideo(at: modified, for: video)
        }.value
        try? await Task.sleep(for: .milliseconds(20))
        async let playbackUpdate = Task.detached(priority: .utility) {
            try store.updatePlaybackPosition(videoID: video.id, seconds: 12)
        }.value

        _ = try await (subtitleCommit, playbackUpdate)
        guard let final = try store.loadIndex().videos.first(where: { $0.id == video.id }) else {
            throw TestFailure("Concurrent index writes removed the video.")
        }
        try expect(final.hasEmbeddedSubtitles, "Concurrent playback update lost the subtitle flag.")
        try expect(final.playbackPositionSeconds == 12, "Concurrent subtitle commit lost the playback position.")
    }

    private static func testSubtitleConfigurationTranslatesByDefaultWhenKeyExists() throws {
        let keyed = SubtitleConfiguration.load(
            contents: """
            WHISPER_MODEL_PATH="/tmp/crypta-whisper.bin"
            LLM_OPENROUTER_API_KEY=sk-test
            """
        )
        try expect(keyed.whisperModelPath == "/tmp/crypta-whisper.bin", "Whisper path should not require LLM config.")
        try expect(keyed.canUseLLM, "API key should still be parsed when present.")
        try expect(!keyed.segmentationEnabled, "LLM segmentation should require an explicit opt-in.")
        try expect(keyed.translationEnabled, "LLM translation should default on when an API key exists.")
        try expect(keyed.translationBatchCues == 40, "LLM translation batches should stay small enough for reliable long-video output.")

        let localOnly = SubtitleConfiguration.load(contents: "")
        try expect(!localOnly.canUseLLM, "Missing API key should keep generation local-only.")
        try expect(localOnly.translationEnabled, "Translation preference should still default on for future keyed configs.")

        let explicitLLM = SubtitleConfiguration.load(
            contents: """
            LLM_OPENROUTER_API_KEY=sk-test
            LLM_SEGMENTATION_ENABLED=true
            """
        )
        try expect(explicitLLM.segmentationEnabled, "Explicit segmentation opt-in was ignored.")
        try expect(explicitLLM.translationEnabled, "Default translation with an API key was ignored.")

        let disabledTranslation = SubtitleConfiguration.load(
            contents: """
            LLM_OPENROUTER_API_KEY=sk-test
            LLM_TRANSLATION_ENABLED=0
            """
        )
        try expect(!disabledTranslation.translationEnabled, "Explicit translation opt-out was ignored.")
    }

    private static func testSubtitleTranslationRepairsMissingIDs() async throws {
        let cues = (1...5).map { index in
            SubtitleCue(
                id: index,
                startMs: index * 1_000,
                endMs: index * 1_000 + 900,
                englishLines: ["Line \(index)"],
                chineseLines: []
            )
        }
        let configuration = SubtitleConfiguration.load(contents: "LLM_OPENROUTER_API_KEY=sk-test")
        var requestedTargetIDs: [[Int]] = []
        let translated = try await SubtitleBilingualTranslator.translate(
            cues,
            sourceLanguage: "en",
            configuration: configuration,
            requestJSON: { _, _, payload, _, _ in
                guard let ids = payload["target_ids"] as? [Int] else {
                    throw TestFailure("Missing target ids in translation request.")
                }
                requestedTargetIDs.append(ids)
                if requestedTargetIDs.count == 1 {
                    return [
                        "translations": ids.dropLast().map { id in
                            ["id": id, "zh": "中文 \(id)"]
                        }
                    ]
                }
                return [
                    "translations": ids.map { id in
                        ["id": id, "zh": "补译 \(id)"]
                    }
                ]
            }
        )

        try expect(requestedTargetIDs == [[1, 2, 3, 4, 5], [5]], "Missing translation ids were not retried narrowly.")
        try expect(translated[0].chineseText == "中文 1", "Existing translations should be preserved.")
        try expect(translated[4].chineseText == "补译 5", "Missing translation id was not repaired.")
    }

    private static func testSubtitleProcessCancellationReportsCancellation() async throws {
        let sleepURL = URL(fileURLWithPath: "/bin/sleep")
        guard FileManager.default.isExecutableFile(atPath: sleepURL.path) else {
            return
        }

        let task = Task {
            try await SubtitleProcessRunner.run(executable: sleepURL, arguments: ["5"])
        }
        try await Task.sleep(for: .milliseconds(100))
        task.cancel()

        do {
            try await task.value
            throw TestFailure("Cancelled subtitle process unexpectedly succeeded.")
        } catch is CancellationError {
            return
        }
    }

    @MainActor
    private static func testSubtitleGenerationSmoke(mediaURL sourceURL: URL) async throws {
        let harness = try StoreHarness()
        defer { harness.cleanup() }

        let importURL = harness.root.appendingPathComponent(sourceURL.lastPathComponent, isDirectory: false)
        try FileManager.default.copyItem(at: sourceURL, to: importURL)

        let store = CryptaStore(locations: harness.locations, keyStore: InMemoryKeyStore(data: harness.keyData))
        let video = try await store.importVideo(from: importURL, libraryKind: .video, mediaType: .video)
        let manager = DecryptedMediaSessionManager(cacheRoot: harness.locations.cacheRoot)

        let generationLease = try await manager.acquireMediaLease(for: video, store: store)
        let generator = SubtitleGenerator { _, _ in }
        try await generator.generate(from: generationLease.url, force: false)
        let updated = try store.commitModifiedVideo(at: generationLease.url, for: video)
        generationLease.release()

        let playbackLease = try await manager.acquireMediaLease(for: updated, store: store)
        try expect(
            subtitleStreamCount(at: playbackLease.url) == 1,
            "Subtitle smoke media did not get an embedded subtitle stream."
        )
        playbackLease.release()
        manager.shutdown()
    }

    private static func subtitleStreamCount(at videoURL: URL) throws -> Int {
        guard let ffprobeURL = ffprobeExecutableURL() else {
            throw TestFailure("ffprobe not found")
        }
        let process = Process()
        process.executableURL = ffprobeURL
        process.arguments = [
            "-v", "error",
            "-select_streams", "s",
            "-show_entries", "stream=index",
            "-of", "csv=p=0",
            videoURL.path
        ]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw TestFailure("ffprobe exit \(process.terminationStatus)")
        }
        let output = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        return output.split(whereSeparator: \.isNewline).filter { !$0.isEmpty }.count
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

    private static func testEncryptedImageImportsStayEncryptedAndThumbnailsAreProtected() async throws {
        let harness = try StoreHarness()
        defer { harness.cleanup() }

        let plaintext = try samplePNGData()
        let source = harness.root.appendingPathComponent("Secret.png", isDirectory: false)
        try plaintext.write(to: source)
        let store = CryptaStore(locations: harness.locations, keyStore: InMemoryKeyStore(data: harness.keyData))

        let image = try await store.importImage(from: source)

        try expect(image.mediaType == .image, "Image import did not set image media type.")
        try expect(image.storageState == .encrypted, "Image import should be encrypted by default.")
        try expect(image.plainFileName == nil, "Image import created a long-lived plain file.")
        try expect(image.durationSeconds == nil, "Image import should not store a video duration.")
        try expect(image.playbackPositionSeconds == nil, "Image import should not store playback position.")
        try expect(!FileManager.default.fileExists(atPath: source.path), "Successful image import did not remove the source file.")
        guard let encryptedFileName = image.encryptedFileName else {
            throw TestFailure("Image import did not create an encrypted blob.")
        }

        let blob = harness.locations.moviesVault.appendingPathComponent(encryptedFileName)
        try expect(FileManager.default.fileExists(atPath: blob.path), "Encrypted image blob was not written.")
        try expect(try Data(contentsOf: blob) != plaintext, "Encrypted image blob contains plaintext bytes.")

        let playback = try store.preparePlaybackURL(for: image)
        defer {
            if let cleanupURL = playback.cleanupURL {
                try? FileManager.default.removeItem(at: cleanupURL)
            }
        }
        try expect(try Data(contentsOf: playback.url) == plaintext, "Temporary image preview file did not restore plaintext.")
        try expect(playback.cleanupURL != nil, "Encrypted image preview did not use a cleanup directory.")
        try expect(
            !playback.url.path.hasPrefix(harness.locations.vaultPackage.path + "/"),
            "Temporary image preview file was written inside the vault package."
        )

        guard let thumbnail = await VideoThumbnailLoader.thumbnail(for: image, store: store) else {
            throw TestFailure("Encrypted image thumbnail was not generated.")
        }
        try expect(thumbnail.size.width > 0 && thumbnail.size.height > 0, "Encrypted image thumbnail is empty.")
        guard let decryptedThumbnail = try store.loadThumbnailData(for: image) else {
            throw TestFailure("Encrypted image thumbnail was not cached.")
        }
        let thumbnailBlob = harness.locations.thumbnailCache
            .appendingPathComponent("\(image.id.uuidString).v3.thumb", isDirectory: false)
        try expect(FileManager.default.fileExists(atPath: thumbnailBlob.path), "Encrypted thumbnail blob was not written.")
        try expect(
            try Data(contentsOf: thumbnailBlob) != decryptedThumbnail,
            "Thumbnail cache stored plaintext image data."
        )
    }

    private static func testImagePlaybackDecryptsOnlyRequestedImage() async throws {
        let harness = try StoreHarness()
        defer { harness.cleanup() }

        let firstData = try samplePNGData()
        var secondData = firstData
        secondData.append(Data("second-image".utf8))
        let firstSource = harness.root.appendingPathComponent("First.png", isDirectory: false)
        let secondSource = harness.root.appendingPathComponent("Second.png", isDirectory: false)
        try firstData.write(to: firstSource)
        try secondData.write(to: secondSource)

        let store = CryptaStore(locations: harness.locations, keyStore: InMemoryKeyStore(data: harness.keyData))
        let firstImage = try await store.importImage(from: firstSource)
        let secondImage = try await store.importImage(from: secondSource)

        let playback = try store.preparePlaybackURL(for: firstImage)
        defer {
            if let cleanupURL = playback.cleanupURL {
                try? FileManager.default.removeItem(at: cleanupURL)
            }
        }

        try expect(try Data(contentsOf: playback.url) == firstData, "Requested image was not decrypted correctly.")
        guard let cleanupURL = playback.cleanupURL else {
            throw TestFailure("Encrypted image playback did not create a cleanup directory.")
        }
        let files = try FileManager.default.contentsOfDirectory(
            at: cleanupURL,
            includingPropertiesForKeys: nil
        )
        try expect(files.count == 1, "Opening one image decrypted additional files.")
        guard let secondEncryptedFileName = secondImage.encryptedFileName else {
            throw TestFailure("Second image did not retain its encrypted blob.")
        }
        let secondBlob = harness.locations.moviesVault.appendingPathComponent(secondEncryptedFileName)
        try expect(FileManager.default.fileExists(atPath: secondBlob.path), "Second image blob was removed.")
        try expect(try Data(contentsOf: secondBlob) != secondData, "Second image was left as plaintext.")
    }

    private static func testMkvThumbnailUsesMiddleFrame() async throws {
        guard let ffmpegURL = ffmpegExecutableURL() else {
            print("Skipping mkv thumbnail middle-frame test: ffmpeg not found")
            return
        }

        let harness = try StoreHarness()
        defer { harness.cleanup() }

        let source = harness.root.appendingPathComponent("Synthetic.mkv", isDirectory: false)
        try runFFmpeg(
            ffmpegURL,
            arguments: [
                "-v", "error",
                "-f", "lavfi",
                "-i", "color=c=black:size=160x90:rate=1:d=1",
                "-f", "lavfi",
                "-i", "color=c=white:size=160x90:rate=1:d=1",
                "-filter_complex", "[0:v][1:v]concat=n=2:v=1:a=0",
                "-c:v", "libx264",
                "-pix_fmt", "yuv420p",
                source.path
            ]
        )

        guard let image = try await VideoThumbnailLoader.image(from: source) else {
            throw TestFailure("MKV thumbnail generation did not produce an image.")
        }
        try expect(image.size.width > 0 && image.size.height > 0, "MKV thumbnail generation produced an empty image.")
        try expect(try averageBrightness(of: image) > 0.8, "MKV thumbnail did not use the middle frame.")
    }

    private static func testFailedImportKeepsSourceFileUntilIndexIsSaved() async throws {
        let harness = try StoreHarness()
        defer { harness.cleanup() }

        try harness.makeIndexPathUnwritableAsDirectory()
        let source = harness.root.appendingPathComponent("source.mp4")
        try Data("company-video".utf8).write(to: source)

        let store = CryptaStore(locations: harness.locations, keyStore: InMemoryKeyStore(data: harness.keyData))
        do {
            _ = try await store.importVideo(from: source, storageState: .encrypted)
            throw TestFailure("Import should fail because the index path is a directory.")
        } catch {
            try expect(FileManager.default.fileExists(atPath: source.path), "Failed import removed the source file.")
        }
    }

    private static func testFailedDeleteKeepsBlobWhenIndexCannotBeSaved() async throws {
        let harness = try StoreHarness()
        defer { harness.cleanup() }

        let blobName = "encrypted-blob"
        let blob = harness.locations.moviesVault.appendingPathComponent(blobName)
        try FileManager.default.createDirectory(at: harness.locations.moviesVault, withIntermediateDirectories: true)
        try Data("encrypted".utf8).write(to: blob)
        try harness.makeIndexPathUnwritableAsDirectory()

        let store = CryptaStore(locations: harness.locations, keyStore: InMemoryKeyStore(data: harness.keyData))
        do {
            try store.delete(harness.sampleVideo(encryptedFileName: blobName))
            throw TestFailure("Delete should fail before removing a blob when the index cannot be loaded or saved.")
        } catch {
            try expect(FileManager.default.fileExists(atPath: blob.path), "Failed delete removed the blob.")
        }
    }

    @MainActor
    private static func testMediaLeaseOwnsTemporaryPlaintext() async throws {
        let harness = try StoreHarness()
        defer { harness.cleanup() }

        let plaintext = Data("leased-video".utf8)
        let store = CryptaStore(locations: harness.locations, keyStore: InMemoryKeyStore(data: harness.keyData))
        let video = try await harness.importEncryptedVideo(named: "Leased.mp4", data: plaintext, store: store)
        let manager = DecryptedMediaSessionManager(cacheRoot: harness.locations.cacheRoot)
        let lease = try await manager.acquireMediaLease(for: video, store: store)
        let leaseDirectory = lease.url.deletingLastPathComponent()

        try expect(try Data(contentsOf: lease.url) == plaintext, "Media lease did not expose the requested plaintext.")
        try expect(FileManager.default.fileExists(atPath: lease.url.path), "Media lease file disappeared while retained.")
        lease.release()
        try expect(!FileManager.default.fileExists(atPath: leaseDirectory.path), "Released media lease left plaintext behind.")
        manager.shutdown()
    }

    @MainActor
    private static func testImageGroupPreparationIsSharedAndLeaseSurvivesInvalidation() async throws {
        let harness = try StoreHarness()
        defer { harness.cleanup() }

        let groupID = "image-group"
        let plaintext = try samplePNGData()
        let source = harness.root.appendingPathComponent("Shared.png", isDirectory: false)
        try plaintext.write(to: source)
        let store = CryptaStore(locations: harness.locations, keyStore: InMemoryKeyStore(data: harness.keyData))
        let image = try await store.importImage(from: source, libraryKind: LibraryKind(rawValue: groupID))
        let manager = DecryptedMediaSessionManager(cacheRoot: harness.locations.cacheRoot)

        async let firstLease = manager.acquireImageLease(for: image, groupVideos: [image], store: store)
        async let secondLease = manager.acquireImageLease(for: image, groupVideos: [image], store: store)
        let (first, second) = try await (firstLease, secondLease)
        let generationDirectory = first.url.deletingLastPathComponent()

        try expect(first.url == second.url, "Concurrent image requests created competing group generations.")
        manager.invalidateImageGroup(groupID)
        try expect(
            FileManager.default.fileExists(atPath: first.url.path),
            "Invalidating an image group deleted a file still held by a player lease."
        )
        first.release()
        try expect(
            FileManager.default.fileExists(atPath: second.url.path),
            "Releasing one of multiple image leases deleted the shared file."
        )
        second.release()
        try expect(
            !FileManager.default.fileExists(atPath: generationDirectory.path),
            "The invalidated image generation remained after its final lease was released."
        )
        manager.shutdown()
    }

    @MainActor
    private static func testMissingImageGroupFileIsRebuilt() async throws {
        let harness = try StoreHarness()
        defer { harness.cleanup() }

        let groupID = "rebuild-group"
        let plaintext = try samplePNGData()
        let source = harness.root.appendingPathComponent("Rebuild.png", isDirectory: false)
        try plaintext.write(to: source)
        let store = CryptaStore(locations: harness.locations, keyStore: InMemoryKeyStore(data: harness.keyData))
        let image = try await store.importImage(from: source, libraryKind: LibraryKind(rawValue: groupID))
        let manager = DecryptedMediaSessionManager(cacheRoot: harness.locations.cacheRoot)

        let firstLease = try await manager.acquireImageLease(for: image, groupVideos: [image], store: store)
        let firstURL = firstLease.url
        firstLease.release()
        try FileManager.default.removeItem(at: firstURL)

        let rebuiltLease = try await manager.acquireImageLease(for: image, groupVideos: [image], store: store)
        try expect(
            try Data(contentsOf: rebuiltLease.url) == plaintext,
            "A missing image cache file was not rebuilt before opening."
        )
        rebuiltLease.release()
        manager.invalidateImageGroup(groupID)
        manager.shutdown()
    }

    @MainActor
    private static func testStartingAnotherSessionDoesNotDeleteLiveFiles() async throws {
        let harness = try StoreHarness()
        defer { harness.cleanup() }

        let plaintext = Data("live-session-video".utf8)
        let store = CryptaStore(locations: harness.locations, keyStore: InMemoryKeyStore(data: harness.keyData))
        let video = try await harness.importEncryptedVideo(named: "Live.mp4", data: plaintext, store: store)
        let firstManager = DecryptedMediaSessionManager(cacheRoot: harness.locations.cacheRoot)
        let lease = try await firstManager.acquireMediaLease(for: video, store: store)

        let secondManager = DecryptedMediaSessionManager(cacheRoot: harness.locations.cacheRoot)
        try secondManager.start()
        try expect(
            FileManager.default.fileExists(atPath: lease.url.path),
            "Starting another Crypta session deleted a live session's plaintext."
        )
        secondManager.shutdown()
        try expect(
            FileManager.default.fileExists(atPath: lease.url.path),
            "Stopping another Crypta session deleted a live session's plaintext."
        )

        lease.release()
        firstManager.shutdown()
    }

    @MainActor
    private static func testSessionStartupRemovesOrphanedFiles() async throws {
        let harness = try StoreHarness()
        defer { harness.cleanup() }

        let orphanDirectory = harness.locations.cacheRoot
            .appendingPathComponent("Sessions", isDirectory: true)
            .appendingPathComponent("orphan", isDirectory: true)
        try FileManager.default.createDirectory(at: orphanDirectory, withIntermediateDirectories: true)
        try Data("2147483647".utf8).write(
            to: orphanDirectory.appendingPathComponent("owner.pid", isDirectory: false)
        )
        try Data("plaintext".utf8).write(
            to: orphanDirectory.appendingPathComponent("leftover.mp4", isDirectory: false)
        )

        let manager = DecryptedMediaSessionManager(cacheRoot: harness.locations.cacheRoot)
        try manager.start()
        try expect(
            !FileManager.default.fileExists(atPath: orphanDirectory.path),
            "Session startup did not remove an orphaned plaintext directory."
        )
        manager.shutdown()
    }

    private static func testExportDecryptRemovesVideoFromVaultAfterIndexSave() async throws {
        let harness = try StoreHarness()
        defer { harness.cleanup() }

        let plaintext = Data("synthetic-video".utf8)
        let store = CryptaStore(locations: harness.locations, keyStore: InMemoryKeyStore(data: harness.keyData))
        let video = try await harness.importEncryptedVideo(named: "ExportMe.mp4", data: plaintext, store: store)
        try store.saveThumbnailData(Data("synthetic-thumbnail".utf8), for: video)
        let blob = harness.locations.moviesVault.appendingPathComponent(video.encryptedFileName ?? "")
        let outputDirectory = harness.root.appendingPathComponent("Exports", isDirectory: true)

        let output = try store.exportAndRemoveDecryptedVideo(video, to: outputDirectory)

        try expect(try Data(contentsOf: output) == plaintext, "Exported plaintext bytes were not restored.")
        try expect(!FileManager.default.fileExists(atPath: blob.path), "Encrypted blob remained after successful export.")
        try expect(try store.loadThumbnailData(for: video) == nil, "Thumbnail remained after successful export.")
        try expect(!store.loadIndex().videos.contains(where: { $0.id == video.id }), "Index entry remained after successful export.")
        try expect(
            !FileManager.default.fileExists(atPath: harness.locations.moviesVault.appendingPathComponent(output.lastPathComponent).path),
            "Plain export was written inside the vault Objects directory."
        )
    }

    private static func testExportDecryptUsesUniqueDestinationName() async throws {
        let harness = try StoreHarness()
        defer { harness.cleanup() }

        let store = CryptaStore(locations: harness.locations, keyStore: InMemoryKeyStore(data: harness.keyData))
        let video = try await harness.importEncryptedVideo(named: "Video.mp4", data: Data("synthetic".utf8), store: store)
        let outputDirectory = harness.root.appendingPathComponent("Exports", isDirectory: true)
        try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
        try Data("existing".utf8).write(to: outputDirectory.appendingPathComponent("Video.mp4"))

        let output = try store.exportAndRemoveDecryptedVideo(video, to: outputDirectory)

        try expect(output.lastPathComponent == "Video 2.mp4", "Export overwrote or failed to uniquify an existing file.")
    }

    private static func testFailedExportKeepsEncryptedBlobAndIndexEntry() async throws {
        let harness = try StoreHarness()
        defer { harness.cleanup() }

        let store = CryptaStore(locations: harness.locations, keyStore: InMemoryKeyStore(data: harness.keyData))
        let video = harness.sampleVideo(encryptedFileName: "invalid-blob")
        try store.saveIndex(CryptaIndex(videos: [video]))
        let blob = harness.locations.moviesVault.appendingPathComponent("invalid-blob")
        try FileManager.default.createDirectory(at: harness.locations.moviesVault, withIntermediateDirectories: true)
        try Data("not-a-valid-encrypted-file".utf8).write(to: blob)
        let outputDirectory = harness.root.appendingPathComponent("Exports", isDirectory: true)

        do {
            _ = try store.exportAndRemoveDecryptedVideo(video, to: outputDirectory)
            throw TestFailure("Invalid encrypted blob should not export successfully.")
        } catch {
            let outputFiles = (try? FileManager.default.contentsOfDirectory(atPath: outputDirectory.path)) ?? []
            try expect(outputFiles.isEmpty, "Failed export left a partial plaintext output.")
            try expect(FileManager.default.fileExists(atPath: blob.path), "Failed export removed the encrypted blob.")
            try expect(store.loadIndex().videos.contains(where: { $0.id == video.id }), "Failed export removed the index entry.")
        }
    }

    private static func testFailedIndexSaveAfterExportKeepsEncryptedBlobAndIndexEntry() async throws {
        let harness = try StoreHarness()
        defer { harness.cleanup() }

        let plaintext = Data("synthetic-video".utf8)
        let store = CryptaStore(locations: harness.locations, keyStore: InMemoryKeyStore(data: harness.keyData))
        let video = try await harness.importEncryptedVideo(named: "SaveFails.mp4", data: plaintext, store: store)
        _ = try store.updatePlaybackPosition(videoID: video.id, seconds: 1)
        let blob = harness.locations.moviesVault.appendingPathComponent(video.encryptedFileName ?? "")
        let outputDirectory = harness.root.appendingPathComponent("Exports", isDirectory: true)

        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: harness.locations.vaultPackage.path)
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: harness.locations.vaultPackage.path)
        }

        do {
            _ = try store.exportAndRemoveDecryptedVideo(video, to: outputDirectory)
            throw TestFailure("Export should fail when the index cannot be saved.")
        } catch {
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: harness.locations.vaultPackage.path)
            try expect(FileManager.default.fileExists(atPath: blob.path), "Index-save failure removed the encrypted blob.")
            try expect(store.loadIndex().videos.contains(where: { $0.id == video.id }), "Index-save failure removed the index entry.")
            let outputFiles = (try? FileManager.default.contentsOfDirectory(atPath: outputDirectory.path)) ?? []
            try expect(outputFiles.count == 1, "Index-save failure should leave the already exported plaintext for the user.")
        }
    }

    private static func testExportRejectsVaultInternalDestination() async throws {
        let harness = try StoreHarness()
        defer { harness.cleanup() }

        let store = CryptaStore(locations: harness.locations, keyStore: InMemoryKeyStore(data: harness.keyData))
        let video = try await harness.importEncryptedVideo(named: "NoVaultOutput.mp4", data: Data("synthetic".utf8), store: store)
        let blob = harness.locations.moviesVault.appendingPathComponent(video.encryptedFileName ?? "")

        do {
            _ = try store.exportAndRemoveDecryptedVideo(video, to: harness.locations.moviesVault)
            throw TestFailure("Exporting into the vault should be rejected.")
        } catch CryptaError.invalidExportDestination {
            try expect(FileManager.default.fileExists(atPath: blob.path), "Rejected vault export removed the encrypted blob.")
            try expect(store.loadIndex().videos.contains(where: { $0.id == video.id }), "Rejected vault export removed the index entry.")
        }
    }

    private static func expect(_ condition: Bool, _ message: String) throws {
        guard condition else {
            throw TestFailure(message)
        }
    }

    private static func ffmpegExecutableURL() -> URL? {
        let candidates = [
            "/opt/homebrew/bin/ffmpeg",
            "/usr/local/bin/ffmpeg",
            "/usr/bin/ffmpeg"
        ]
        return candidates
            .map { URL(fileURLWithPath: $0) }
            .first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }

    private static func runFFmpeg(_ ffmpegURL: URL, arguments: [String]) throws {
        let process = Process()
        process.executableURL = ffmpegURL
        process.arguments = arguments
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw TestFailure("ffmpeg fixture generation failed.")
        }
    }

    private static func averageBrightness(of image: NSImage) throws -> Double {
        guard let tiffData = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiffData) else {
            throw TestFailure("Could not read generated thumbnail pixels.")
        }

        let width = bitmap.pixelsWide
        let height = bitmap.pixelsHigh
        var total = 0.0
        for y in 0..<height {
            for x in 0..<width {
                guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else {
                    continue
                }
                total += (Double(color.redComponent) + Double(color.greenComponent) + Double(color.blueComponent)) / 3
            }
        }
        return total / Double(width * height)
    }

    private static func samplePNGData() throws -> Data {
        guard let representation = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: 4,
            pixelsHigh: 4,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ) else {
            throw TestFailure("Could not create PNG fixture.")
        }

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: representation)
        NSColor.systemRed.setFill()
        NSRect(x: 0, y: 0, width: 4, height: 4).fill()
        NSGraphicsContext.restoreGraphicsState()

        guard let data = representation.representation(using: .png, properties: [:]) else {
            throw TestFailure("Could not encode PNG fixture.")
        }
        return data
    }

    private static func patternedData(count: Int) -> Data {
        var data = Data(count: count)
        data.withUnsafeMutableBytes { buffer in
            guard let bytes = buffer.bindMemory(to: UInt8.self).baseAddress else { return }
            for index in 0..<count {
                bytes[index] = UInt8(index % 251)
            }
        }
        return data
    }

    private static func regularFiles(under root: URL) throws -> [URL] {
        guard FileManager.default.fileExists(atPath: root.path),
              let enumerator = FileManager.default.enumerator(
                at: root,
                includingPropertiesForKeys: [.isRegularFileKey],
                options: [.skipsHiddenFiles]
              ) else {
            return []
        }

        var files: [URL] = []
        for case let url as URL in enumerator {
            let values = try url.resourceValues(forKeys: [.isRegularFileKey])
            if values.isRegularFile == true {
                files.append(url)
            }
        }
        return files
    }

    private static func sampleVideo(displayName: String, importedAt: Date) -> CryptaVideo {
        CryptaVideo(
            id: UUID(),
            displayName: displayName,
            originalExtension: "mp4",
            mediaType: .video,
            storageState: .encrypted,
            plainFileName: nil,
            encryptedFileName: UUID().uuidString,
            importedAt: importedAt,
            byteCount: 12,
            durationSeconds: nil
        )
    }
}

private struct TestFailure: Error, CustomStringConvertible {
    let description: String

    init(_ description: String) {
        self.description = description
    }
}

private final class StoreHarness {
    let root: URL
    let locations: CryptaStorageLocations
    let keyData = Data(repeating: 7, count: 32)

    init() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("CryptaDataSafety-\(UUID().uuidString)", isDirectory: true)
        locations = CryptaStorageLocations(
            vaultPackage: root.appendingPathComponent("Movies/Crypta.vault", isDirectory: true),
            moviesVault: root.appendingPathComponent("Movies/Crypta.vault/Objects", isDirectory: true),
            applicationSupport: root.appendingPathComponent("Movies/Crypta.vault", isDirectory: true),
            playbackCache: root.appendingPathComponent("Caches/Crypta/Playback", isDirectory: true)
        )
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    func cleanup() {
        try? FileManager.default.removeItem(at: root)
    }

    func makeIndexPathUnwritableAsDirectory() throws {
        try FileManager.default.createDirectory(at: locations.applicationSupport, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: locations.encryptedIndex, withIntermediateDirectories: true)
    }

    func sampleVideo(displayName: String = "Video", encryptedFileName: String) -> CryptaVideo {
        CryptaVideo(
            id: UUID(),
            displayName: displayName,
            originalExtension: "mp4",
            mediaType: .video,
            storageState: .encrypted,
            plainFileName: nil,
            encryptedFileName: encryptedFileName,
            importedAt: Date(),
            byteCount: 12,
            durationSeconds: nil
        )
    }

    func importEncryptedVideo(named name: String, data: Data, store: CryptaStore) async throws -> CryptaVideo {
        let source = root.appendingPathComponent(name, isDirectory: false)
        try data.write(to: source)
        return try await store.importVideo(from: source, storageState: .encrypted)
    }
}

private final class InMemoryKeyStore: CryptaEncryptionKeyStore, @unchecked Sendable {
    private var data: Data?
    private(set) var savedKeyCount = 0

    init(data: Data?) {
        self.data = data
    }

    func readKeyData() throws -> Data? {
        data
    }

    func saveKeyData(_ data: Data) throws {
        savedKeyCount += 1
        self.data = data
    }
}
