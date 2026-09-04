import XCTest

final class RootNavigationUITests: XCTestCase {
    @MainActor
    func testSwitchesBetweenTheTwoRootTabs() {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing-empty"]
        app.launch()

        XCTAssertTrue(app.staticTexts["Seal"].waitForExistence(timeout: 10))
        let appsTab = tabButton(identifier: "root-tab-apps", title: "应用", in: app)
        let settingsTab = tabButton(identifier: "root-tab-settings", title: "我的", in: app)
        XCTAssertTrue(appsTab.waitForExistence(timeout: 10))
        XCTAssertTrue(settingsTab.waitForExistence(timeout: 10))

        settingsTab.tap()
        XCTAssertTrue(app.navigationBars["我的"].waitForExistence(timeout: 5))

        appsTab.tap()
        XCTAssertTrue(app.staticTexts["Seal"].waitForExistence(timeout: 5))

        let screenshot = XCUIScreen.main.screenshot()
        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.name = "Seal Root Navigation"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    @MainActor
    private func tabButton(identifier: String, title: String, in app: XCUIApplication) -> XCUIElement {
        let identified = app.buttons[identifier]
        if identified.waitForExistence(timeout: 2) {
            return identified
        }
        return app.tabBars.buttons[title]
    }
}
