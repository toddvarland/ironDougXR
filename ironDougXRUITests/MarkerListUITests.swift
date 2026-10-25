import XCTest

final class MarkerListUITests: XCTestCase {

    var app: XCUIApplication!

    override func setUp() {
        super.setUp()
        continueAfterFailure = false
        app = XCUIApplication()
        app.launch()
    }

    override func tearDown() {
        app.terminate()
        super.tearDown()
    }

    func test_saveButton_existsInUI() {
        let saveButton = app.buttons["saveButton"]
        XCTAssertTrue(saveButton.waitForExistence(timeout: 5))
    }

    func test_markerListButton_existsInUI() {
        let listButton = app.buttons["markerListButton"]
        XCTAssertTrue(listButton.waitForExistence(timeout: 5))
    }

    func test_markerListSheet_opensAndCloses() {
        let listButton = app.buttons["markerListButton"]
        XCTAssertTrue(listButton.waitForExistence(timeout: 5))
        listButton.tap()
        XCTAssertTrue(app.navigationBars["Markers (0)"].waitForExistence(timeout: 3))
        app.buttons["Done"].tap()
        XCTAssertFalse(app.navigationBars["Markers (0)"].exists)
    }

    func test_recalibrationAlert_isDismissable() {
        app.terminate()
        app.launchArguments = ["--forceRecalibrationPrompt"]
        app.launch()
        let alert = app.alerts["Environment Calibration Needed"]
        XCTAssertTrue(alert.waitForExistence(timeout: 5))
        alert.buttons["Dismiss"].tap()
        XCTAssertFalse(alert.exists)
    }

    func test_recalibrationAlert_clearAllDismissesAlert() {
        app.terminate()
        app.launchArguments = ["--forceRecalibrationPrompt"]
        app.launch()
        let alert = app.alerts["Environment Calibration Needed"]
        XCTAssertTrue(alert.waitForExistence(timeout: 5))
        alert.buttons["Clear & Start Fresh"].tap()
        XCTAssertFalse(alert.exists)
    }

    func test_saveErrorAlert_isShownAndDismissable() {
        app.terminate()
        app.launchArguments = ["--forceSaveError"]
        app.launch()
        let alert = app.alerts["Save Failed"]
        XCTAssertTrue(alert.waitForExistence(timeout: 5))
        alert.buttons["OK"].tap()
        XCTAssertFalse(alert.exists)
    }

    func test_renameMarker_updatesList() {
        app.terminate()
        app.launchArguments = ["--seedMarkers"]
        app.launch()
        app.buttons["markerListButton"].tap()
        XCTAssertTrue(app.navigationBars["Markers (1)"].waitForExistence(timeout: 3))

        // Row labels combine name and date, e.g. "Mark 1, Oct 24, 2026"
        func row(_ name: String) -> XCUIElement {
            app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", name)).firstMatch
        }
        row("Mark 1").tap()
        let alert = app.alerts["Rename Marker"]
        XCTAssertTrue(alert.waitForExistence(timeout: 3))
        let field = alert.textFields.firstMatch
        field.tap()
        field.clearAndType("Front Door")
        alert.buttons["Save"].tap()

        XCTAssertTrue(row("Front Door").waitForExistence(timeout: 3))
        XCTAssertFalse(row("Mark 1").exists)
    }

    func test_statusBanner_isVisibleOnLaunch() {
        let banner = app.staticTexts.matching(identifier: "statusBanner").firstMatch
        XCTAssertTrue(banner.waitForExistence(timeout: 5))
    }
}

private extension XCUIElement {
    func clearAndType(_ text: String) {
        if let current = value as? String, !current.isEmpty {
            typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: current.count))
        }
        typeText(text)
    }
}
