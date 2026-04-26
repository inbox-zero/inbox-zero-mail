import AppKit
import XCTest

final class InboxZeroMailUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func testUnifiedTabsAndThreadFocusFlow() throws {
        let app = launchApp()

        let allTab = app.buttons["split-inbox-tab-builtin.all"]
        let unreadTab = app.buttons["split-inbox-tab-builtin.unread"]
        let starredTab = app.buttons["split-inbox-tab-builtin.starred"]
        let snoozedTab = app.buttons["split-inbox-tab-builtin.snoozed"]

        XCTAssertTrue(unreadTab.waitForExistence(timeout: 5))
        XCTAssertTrue(starredTab.exists)
        XCTAssertTrue(snoozedTab.exists)
        XCTAssertTrue(findFirstElement(in: app, identifierPrefix: "thread-row-").waitForExistence(timeout: 5))

        snoozedTab.click()
        XCTAssertTrue(findFirstElement(in: app, identifierPrefix: "thread-row-").waitForExistence(timeout: 5))

        unreadTab.click()
        XCTAssertTrue(findFirstElement(in: app, identifierPrefix: "thread-row-").waitForExistence(timeout: 5))

        starredTab.click()
        XCTAssertTrue(findFirstElement(in: app, identifierPrefix: "thread-row-").waitForExistence(timeout: 5))

        allTab.click()
        XCTAssertTrue(findFirstElement(in: app, identifierPrefix: "thread-row-").waitForExistence(timeout: 5))
    }

    @MainActor
    func testComposeSheetUsesDemoAccounts() throws {
        let app = launchApp()

        let composeButton = app.buttons.matching(identifier: "toolbar-compose").firstMatch
        XCTAssertTrue(composeButton.waitForExistence(timeout: 5))
        composeButton.click()

        XCTAssertTrue(app.textFields["compose-to"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.textFields["compose-subject"].exists)
        XCTAssertTrue(app.textViews["compose-body"].exists)
        XCTAssertTrue(app.buttons["compose-send"].exists)
        XCTAssertTrue(app.buttons["compose-cancel"].exists)

        app.buttons["compose-cancel"].click()
        XCTAssertFalse(app.textFields["compose-to"].exists)
    }

    @MainActor
    func testStarringThreadDoesNotOpenDetailView() throws {
        let app = launchApp()

        let starButton = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "thread-row-star-")).firstMatch
        XCTAssertTrue(starButton.waitForExistence(timeout: 5))

        starButton.click()

        XCTAssertFalse(findElement(in: app, identifier: "thread-detail").waitForExistence(timeout: 1))
        XCTAssertFalse(findElement(in: app, identifier: "thread-detail-loading").exists)
        XCTAssertTrue(app.buttons["toolbar-compose"].exists)
    }

    @MainActor
    func testBackButtonGapIsClickable() throws {
        let app = launchApp()

        let firstThread = findFirstElement(in: app, identifierPrefix: "thread-row-")
        XCTAssertTrue(firstThread.waitForExistence(timeout: 5))
        firstThread.click()

        let threadDetail = findElement(in: app, identifier: "thread-detail")
        XCTAssertTrue(threadDetail.waitForExistence(timeout: 5))

        let backButton = app.buttons["thread-detail-back"]
        XCTAssertTrue(backButton.waitForExistence(timeout: 5))

        backButton.coordinate(withNormalizedOffset: CGVector(dx: 0.35, dy: 0.5)).click()

        XCTAssertFalse(threadDetail.waitForExistence(timeout: 1))
        XCTAssertTrue(app.buttons["toolbar-compose"].waitForExistence(timeout: 5))
    }

    private func makeApp() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = [
            "--seed-demo-data",
            "--ui-testing",
            "-ApplePersistenceIgnoreState", "YES",
            "-NSQuitAlwaysKeepsWindows", "NO",
        ]
        app.launchEnvironment["ApplePersistenceIgnoreState"] = "YES"
        app.launchEnvironment["INBOX_ZERO_UI_TESTING"] = "1"
        return app
    }

    private func launchApp() -> XCUIApplication {
        let app = makeApp()
        yieldActivationToInboxZero()
        app.activate()
        addTeardownBlock {
            if app.state != .notRunning {
                app.terminate()
            }
        }
        ensureMainWindowExists(in: app)
        return app
    }

    private func ensureMainWindowExists(in app: XCUIApplication) {
        let composeButton = app.buttons["toolbar-compose"]
        let splitInboxTab = app.buttons["split-inbox-tab-builtin.unread"]

        if composeButton.waitForExistence(timeout: 2) || splitInboxTab.waitForExistence(timeout: 2) {
            return
        }

        app.typeKey("n", modifierFlags: .command)
        XCTAssertTrue(
            composeButton.waitForExistence(timeout: 5) || splitInboxTab.waitForExistence(timeout: 5),
            "Expected a main window after opening a new window."
        )
    }

    private func yieldActivationToInboxZero() {
        if #available(macOS 14.0, *) {
            _ = NSRunningApplication.current.activate(options: [.activateIgnoringOtherApps])
            RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.1))
            NSApplication.shared.yieldActivation(toApplicationWithBundleIdentifier: "com.getinboxzero.InboxZeroMail")
        }
    }

    private func findElement(in app: XCUIApplication, identifier: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: identifier).firstMatch
    }

    private func findFirstElement(in app: XCUIApplication, identifierPrefix: String) -> XCUIElement {
        app.groups
            .matching(NSPredicate(format: "identifier BEGINSWITH %@", identifierPrefix))
            .firstMatch
    }
}
