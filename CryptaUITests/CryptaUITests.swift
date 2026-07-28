//
//  CryptaUITests.swift
//  CryptaUITests
//
//  Created by Eli New on 2026-06-04.
//

import XCTest

final class CryptaUITests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func testLaunchPerformance() throws {
        // This measures how long it takes to launch your application.
        measure(metrics: [XCTApplicationLaunchMetric()]) {
            let app = XCUIApplication()
            app.launchEnvironment["CRYPTA_UI_TESTING"] = "1"
            app.launch()
        }
    }
}
