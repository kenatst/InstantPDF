import XCTest

/// Real-device-contract UI tests: drive the SHIPPING app by touch.
/// These prove the Settings gear is reachable and opens Settings —
/// independent of any hidden navigation toolbar.
final class PDFItUITests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    private func launchApp() -> XCUIApplication {
        let app = XCUIApplication()
        // Onboarding/one-time-offer flags are pre-written into the app's
        // standard defaults domain on this simulator (see run instructions),
        // so every launch lands directly on Home.
        app.launch()
        return app
    }

    func testHomeHeaderShowsBrandAndSettingsGearOpensSettings() throws {
        let app = launchApp()

        // Language-independent identifier set on the header gear.
        let gear = app.buttons["home_settings_gear"]
        XCTAssertTrue(gear.waitForExistence(timeout: 20),
                      "Settings gear must exist in the visible Home header")
        XCTAssertTrue(gear.isHittable,
                      "Settings gear must be tappable — not covered by overlays")

        gear.tap()

        // SettingsView renders its first section "PDF IT PRO" regardless of
        // device language (identifier-based), and a nav bar exists. Retry
        // once: a tap during launch animation can be swallowed.
        var settingsVisible = false
        for _ in 0..<2 {
            let proSection = app.otherElements["pdf_settings_pro_header"]
            let proHeaderFallback = app.staticTexts["pdf_settings_pro_header"]
            let navBar = app.navigationBars.firstMatch
            settingsVisible = proSection.waitForExistence(timeout: 8)
                || proHeaderFallback.waitForExistence(timeout: 1)
                || navBar.waitForExistence(timeout: 3)
            if settingsVisible { break }
            if gear.isHittable { gear.tap() }
        }
        XCTAssertTrue(settingsVisible, "Tapping the gear must open SettingsView")
    }

    func testLibraryTabOpensFromBottomBar() throws {
        let app = launchApp()
        let libraryTab = app.tabBars.buttons.element(boundBy: 1)
        XCTAssertTrue(libraryTab.waitForExistence(timeout: 20))
        libraryTab.tap()
        // Library root shows its toolbar Select action (stable identifier).
        XCTAssertTrue(app.buttons["library_select"].waitForExistence(timeout: 8))
    }
}
