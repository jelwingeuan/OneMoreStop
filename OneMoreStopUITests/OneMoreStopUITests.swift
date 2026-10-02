import XCTest

@MainActor
final class OneMoreStopUITests: XCTestCase {
    func testExploreSavedAndSettings() throws {
        let app = XCUIApplication()
        app.launchArguments += ["-hasSeenIntroduction", "YES"]
        app.launch()
        XCTAssertTrue(app.staticTexts["A little time. A better drive."].waitForExistence(timeout: 15))
        app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Profile,")).firstMatch.tap()
        XCTAssertTrue(app.navigationBars["Profile"].waitForExistence(timeout: 5))
        app.buttons["Settings"].tap()
        XCTAssertTrue(app.staticTexts["Driving"].waitForExistence(timeout: 5))
        app.buttons["Done"].tap()
        app.buttons["Saved"].firstMatch.tap()
        XCTAssertTrue(app.staticTexts["Collections"].waitForExistence(timeout: 5))
    }

    func testProfileEditAndSavedShortcuts() throws {
        let app = XCUIApplication()
        app.launchArguments += ["-hasSeenIntroduction", "YES"]
        app.launch()
        app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Profile,")).firstMatch.tap()
        app.buttons["Edit profile"].tap()
        XCTAssertTrue(app.navigationBars["Edit profile"].waitForExistence(timeout: 5))
        let name = app.textFields["Display name"]
        name.tap()
        name.typeText(" Nur")
        let savedName = try XCTUnwrap(name.value as? String)
        app.buttons["Save"].tap()
        XCTAssertTrue(app.staticTexts[savedName].waitForExistence(timeout: 5))
        app.buttons["Collections"].tap()
        XCTAssertTrue(app.navigationBars["Saved"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["New collection"].exists)
    }

    func testAvatarLongPressKeepsQuickActionsAccessible() throws {
        let app = XCUIApplication()
        app.launchArguments += ["-hasSeenIntroduction", "YES"]
        app.launch()
        app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Profile,")).firstMatch
            .press(forDuration: 0.8)
        XCTAssertTrue(app.buttons["Travel preferences"].waitForExistence(timeout: 5))
        app.buttons["Travel preferences"].tap()
        XCTAssertTrue(app.navigationBars["Settings"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Driving"].exists)
    }

    func testProfilePhotoCanBeChosenReplacedAndRemoved() throws {
        let app = XCUIApplication()
        app.launchArguments += ["-hasSeenIntroduction", "YES"]
        app.launch()
        app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Profile,")).firstMatch.tap()
        app.buttons["Edit profile"].tap()
        let firstAction = app.buttons["Choose photo"].exists ? "Choose photo" : "Replace photo"
        app.buttons[firstAction].tap()
        try requireAvailablePhotoPicker(in: app)
        let photoCells = app.collectionViews.cells
        let firstPhoto = photoCells.element(boundBy: max(0, photoCells.count - 1))
        XCTAssertTrue(firstPhoto.waitForExistence(timeout: 10))
        firstPhoto.tap()
        XCTAssertTrue(app.buttons["Replace photo"].waitForExistence(timeout: 20))
        app.buttons["Replace photo"].tap()
        try requireAvailablePhotoPicker(in: app)
        XCTAssertTrue(firstPhoto.waitForExistence(timeout: 10))
        firstPhoto.tap()
        XCTAssertTrue(app.buttons["Remove photo"].waitForExistence(timeout: 20))
        app.buttons["Remove photo"].tap()
        XCTAssertTrue(app.buttons["Choose photo"].waitForExistence(timeout: 10))
    }

    private func requireAvailablePhotoPicker(in app: XCUIApplication) throws {
        let unavailable = app.navigationBars["PUPickerUnavailableView"]
        guard unavailable.exists else { return }
        let ready = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: unavailable)
        if XCTWaiter.wait(for: [ready], timeout: 15) != .completed {
            throw XCTSkip("The simulator’s system PhotosPicker stayed on its unavailable loading screen.")
        }
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
        XCTAssertTrue(app.buttons["I can spare"].exists)
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
            app.buttons["Start active journey"].tap()
            XCTAssertTrue(app.navigationBars["Active journey"].waitForExistence(timeout: 10))
            app.buttons["Complete journey"].tap()
            XCTAssertTrue(app.navigationBars["Journey recap"].waitForExistence(timeout: 10))
            app.buttons["Done"].tap()
            XCTAssertTrue(app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Profile,")).firstMatch
                .waitForExistence(timeout: 10))
        }
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.lifetime = .keepAlways
        add(screenshot)
    }

    func testV4JourneyControlsAndPassengerSurface() throws {
        let app = XCUIApplication()
        app.launchArguments += ["-hasSeenIntroduction", "YES"]
        app.launch()
        try choose("Cyberjaya", from: app.buttons["Choose starting place"].firstMatch, in: app)
        try choose("Melaka", from: app.buttons["Where are you going?"].firstMatch, in: app)
        guard app.staticTexts["Find your one more stop"].waitForExistence(timeout: 60) else {
            throw XCTSkip("MapKit route was unavailable in this simulator run.")
        }
        XCTAssertTrue(app.buttons["One More Stop"].exists)
        XCTAssertTrue(app.staticTexts["Time Machine"].exists)
        XCTAssertTrue(app.staticTexts["Mission"].exists)
        app.buttons["One More Stop"].tap()
        app.buttons["15"].firstMatch.tap()
        XCTAssertTrue(app.buttons["Use 15 min budget"].exists)
        app.buttons["Use 15 min budget"].tap()
        let start = app.buttons["Start active journey"]
        if !start.isHittable { app.scrollViews.firstMatch.swipeUp() }
        XCTAssertTrue(start.waitForExistence(timeout: 10))
        start.tap()
        XCTAssertTrue(app.navigationBars["Active journey"].waitForExistence(timeout: 10))
        app.segmentedControls.buttons["Passenger"].tap()
        XCTAssertTrue(app.staticTexts["Upcoming opportunities"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["What Was That?"].exists)
        XCTAssertTrue(app.staticTexts["Detour Roulette"].exists)
        XCTAssertTrue(app.buttons["Meet on the way"].exists)
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
        XCTAssertTrue(app.buttons["I can spare"].exists)
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

    func testDriveUntilAndEscapeControlsWithoutRoute() throws {
        let app = XCUIApplication()
        app.launchArguments += ["-hasSeenIntroduction", "YES"]
        app.launch()
        app.buttons["Drive Until"].tap()
        XCTAssertTrue(app.navigationBars["Explore by time"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.switches["Return to start"].exists)
        app.segmentedControls.buttons["Escape Mode"].tap()
        XCTAssertTrue(app.staticTexts["Escape Mode includes the drive back to your start."].exists)
        XCTAssertTrue(app.buttons["Find routed outings"].exists)
    }

    func testLocalGroupIsClearlySingleDevice() throws {
        let app = XCUIApplication()
        app.launchArguments += ["-hasSeenIntroduction", "YES"]
        app.launch()
        app.buttons["Local group"].tap()
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "Votes are saved on this device"))
            .firstMatch.waitForExistence(timeout: 5))
        if app.buttons["Create group"].exists { app.buttons["Create group"].tap() }
        XCTAssertTrue(app.staticTexts["Participants"].waitForExistence(timeout: 5))
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
