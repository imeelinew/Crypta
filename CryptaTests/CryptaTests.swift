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

    @Test func vaultLivesInMoviesFolder() async throws {
        let expectedVault = FileManager.default.urls(for: .moviesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Crypta", isDirectory: true)

        #expect(CryptaPaths.moviesVault == expectedVault)
        #expect(CryptaPaths.thumbnailCache == CryptaPaths.moviesVault.appendingPathComponent("Thumbnails", isDirectory: true))
        #expect(CryptaPaths.moviesVault.path.hasSuffix("/Movies/Crypta"))
    }

    @Test func encryptedIndexUsesNewAppIdentity() async throws {
        #expect(CryptaPaths.applicationSupport.path.hasSuffix("/Application Support/com.eli.Crypta"))
        #expect(CryptaPaths.encryptedIndex == CryptaPaths.applicationSupport.appendingPathComponent("library.index", isDirectory: false))
        #expect(!CryptaPaths.encryptedIndex.path.hasSuffix("/Application Support/Crypta/library.index"))
    }

}
