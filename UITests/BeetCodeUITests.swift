import XCTest

@MainActor
final class BeetCodeUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    func testPrimaryComposerControlsAreAccessibleAtLaunch() {
        let app = launchApp()

        XCTAssertTrue(app.textFields["Task description"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["Attach files"].exists)
        XCTAssertTrue(app.descendants(matching: .any)["Chat only mode"].exists)
        XCTAssertTrue(app.buttons["Send"].exists)
    }

    func testComposerStartsReadyForTaskInput() {
        let app = launchApp()
        let composer = app.textFields["Task description"]

        XCTAssertTrue(composer.waitForExistence(timeout: 10))
        XCTAssertTrue(composer.isEnabled)
        XCTAssertTrue(app.descendants(matching: .any)["Chat only mode"].exists)
        XCTAssertFalse(app.descendants(matching: .any)["Agent setup"].exists)
        XCTAssertTrue(app.descendants(matching: .any)["Composer commands"].exists)
    }

    func testHistoryNavigationIsAccessible() {
        let app = launchApp()

        XCTAssertTrue(app.buttons["My chats"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["Other tools"].exists)
        XCTAssertTrue(app.textFields["Search all history"].exists)
        XCTAssertTrue(app.descendants(matching: .any)["More chat actions"].exists)
    }

    private func launchApp() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment["XCTestConfigurationFilePath"] = "ui-smoke"
        app.launch()
        return app
    }
}
