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
    @Test func libraryOpensWithoutSelectedGroup() {
        let library = CryptaLibrary()

        #expect(library.selectedGroupID == nil)
    }

    @Test func encryptedGroupRequiresAuthentication() {
        let standardGroup = LibraryGroup(name: "标准", encryptionLevel: .standard, mediaType: .video)
        let extendedGroup = LibraryGroup(name: "扩展", encryptionLevel: .extended, mediaType: .video)
        #expect(!standardGroup.requiresAuthentication)
        #expect(extendedGroup.requiresAuthentication)
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
