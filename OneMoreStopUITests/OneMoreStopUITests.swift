import XCTest

@MainActor
final class OneMoreStopUITests: XCTestCase {
    func testExploreSavedAndSettings() throws {
        let app = XCUIApplication()
        app.launchArguments += ["-hasSeenIntroduction", "YES"]
        app.launch()
        XCTAssertTrue(app.staticTexts["A little time. A better drive."].waitForExistence(timeout: 15))
        app.buttons["Settings"].tap()
        XCTAssertTrue(app.staticTexts["Driving"].waitForExistence(timeout: 5))
        app.buttons["Done"].tap()
        app.buttons["Saved"].firstMatch.tap()
        XCTAssertTrue(app.staticTexts["Collections"].waitForExistence(timeout: 5))
    }

    func testMalaysiaRouteCanBeSearched() throws {
        let app = XCUIApplication()
        app.launchArguments += ["-hasSeenIntroduction", "YES"]
        app.launch()
        try choose("Cyberjaya", from: app.buttons["Choose starting place"].firstMatch, in: app)
        try choose("Melaka", from: app.buttons["Where are you going?"].firstMatch, in: app)
        let journey = app.staticTexts["Find your one more stop"]
        if !journey.waitForExistence(timeout: 60) {
            throw XCTSkip("MapKit search or driving directions were unavailable in this simulator run.")
        }
        XCTAssertTrue(app.staticTexts["I can spare"].exists)
        let result = app.buttons["Add stop"].firstMatch
        if result.waitForExistence(timeout: 90) {
            result.tap()
            XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "Your journey")).firstMatch
                .waitForExistence(timeout: 20))
            let openMaps = app.buttons["Open in Apple Maps"]
            XCTAssertTrue(openMaps.exists)
            openMaps.tap()
            app.activate()
            XCTAssertTrue(app.buttons["Continue to next stop"].waitForExistence(timeout: 20))
        }
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.lifetime = .keepAlways
        add(screenshot)
    }

    func testRouteOutsideMalaysia() throws {
        let app = XCUIApplication()
        app.launchArguments += ["-hasSeenIntroduction", "YES"]
        app.launch()
        try choose("Mountain View California", matching: "Mountain View", from: app.buttons["Choose starting place"].firstMatch, in: app)
        try choose("Santa Cruz California", matching: "Santa Cruz", from: app.buttons["Where are you going?"].firstMatch, in: app)
        if !app.staticTexts["Find your one more stop"].waitForExistence(timeout: 60) {
            throw XCTSkip("MapKit driving directions outside Malaysia were unavailable in this simulator run.")
        }
        XCTAssertTrue(app.staticTexts["I can spare"].exists)
    }

    func testDeniedLocationStillOffersManualStart() throws {
        let app = XCUIApplication()
        app.resetAuthorizationStatus(for: .location)
        app.launchArguments += ["-hasSeenIntroduction", "YES"]
        app.launch()
        app.buttons["Choose starting place"].firstMatch.tap()
        app.buttons["Current Location"].tap()
        app.alerts["Use your location?"].buttons["Continue"].tap()
        let systemAlert = XCUIApplication(bundleIdentifier: "com.apple.springboard").alerts.firstMatch
        if systemAlert.waitForExistence(timeout: 8) {
            XCTAssertGreaterThan(systemAlert.buttons.count, 0)
            systemAlert.buttons.element(boundBy: systemAlert.buttons.count - 1).tap()
        }
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS[c] %@", "Location is off"))
            .firstMatch.waitForExistence(timeout: 15))
        XCTAssertTrue(app.buttons["Choose starting place"].firstMatch.exists)
    }

    func testUnroutableDriveOffersRetry() throws {
        let app = XCUIApplication()
        app.launchArguments += ["-hasSeenIntroduction", "YES"]
        app.launch()
        try choose("Cyberjaya", from: app.buttons["Choose starting place"].firstMatch, in: app)
        try choose("Central Park New York", matching: "Central Park", from: app.buttons["Where are you going?"].firstMatch, in: app)
        if !app.buttons["Try route again"].waitForExistence(timeout: 45) {
            throw XCTSkip("MapKit did not return a definitive no-route error in this simulator run.")
        }
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS[c] %@", "Couldn’t find a driving route"))
            .firstMatch.exists)
    }

    private func choose(_ query: String, matching label: String? = nil, from button: XCUIElement, in app: XCUIApplication) throws {
        XCTAssertTrue(button.waitForExistence(timeout: 10))
        button.tap()
        let field = app.searchFields.firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 10))
        field.tap()
        field.typeText(query)
        let result = app.buttons.matching(NSPredicate(format: "label CONTAINS[c] %@", label ?? query)).firstMatch
        if !result.waitForExistence(timeout: 25) {
            throw XCTSkip("MapKit autocomplete did not return \(query).")
        }
        result.tap()
    }
}
