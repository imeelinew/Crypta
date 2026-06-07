//
//  CryptaTests.swift
//  CryptaTests
//
//  Created by Eli New on 2026-06-04.
//

import Foundation
import Testing
@testable import Crypta

struct CryptaTests {

    @MainActor
    @Test func libraryOpensOnVideoSection() {
        let library = CryptaLibrary()

        #expect(library.selectedSection == .video)
    }

    @Test func encryptedImageSectionRequiresAuthentication() {
        #expect(LibrarySection.encryptedImage.requiresAuthentication)
        #expect(LibrarySection.encryptedImage.libraryKind == .encryptedImage)
    }

    @Test func vaultLivesInMoviesFolder() async throws {
        let expectedPackage = FileManager.default.urls(for: .moviesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Crypta.vault", isDirectory: true)
        let expectedObjects = expectedPackage.appendingPathComponent("Objects", isDirectory: true)

        #expect(CryptaPaths.vaultPackage == expectedPackage)
        #expect(CryptaPaths.moviesVault == expectedObjects)
        #expect(CryptaPaths.thumbnailCache == expectedPackage.appendingPathComponent("Thumbnails", isDirectory: true))
        #expect(CryptaPaths.vaultPackage.path.hasSuffix("/Movies/Crypta.vault"))
    }

    @Test func encryptedIndexUsesNewAppIdentity() async throws {
        #expect(CryptaPaths.applicationSupport == CryptaPaths.vaultPackage)
        #expect(CryptaPaths.encryptedIndex == CryptaPaths.vaultPackage.appendingPathComponent("library.index", isDirectory: false))
        #expect(!CryptaPaths.encryptedIndex.path.hasSuffix("/Application Support/Crypta/library.index"))
    }

}
