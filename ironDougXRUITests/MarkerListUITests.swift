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

    func test_statusBanner_isVisibleOnLaunch() {
        let banner = app.staticTexts.matching(identifier: "statusBanner").firstMatch
        XCTAssertTrue(banner.waitForExistence(timeout: 5))
    }
}
