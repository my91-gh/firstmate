// Scratch XCUITest template for driving an iOS app's UI and capturing screenshots
// from the command line. Drop this into the app's UI-test target, adjust the
// queries to your app, run one method with `xcodebuild test -only-testing:...`,
// then export the screenshots from the .xcresult with scripts/export-attachments.sh.
//
// This is throwaway driving code, not a shipped test - remove it when done.

import XCTest

final class UIDriveTemplate: XCTestCase {

    // Capture the current screen as a named attachment that survives in the .xcresult.
    private func snapshot(_ name: String) {
        let shot = XCUIScreen.main.screenshot()
        let att = XCTAttachment(screenshot: shot)
        att.name = name                 // becomes the exported file name, e.g. 01-home.png
        att.lifetime = .keepAlways      // .keepAlways so a passing run still keeps it
        add(att)
    }

    func testDriveAndCapture() {
        let app = XCUIApplication()

        // Jump straight to the target screen if the app honours a launch argument;
        // otherwise drive the navigation with taps below.
        app.launchArguments = ["-someState", "value"]
        app.launch()

        // 1. Capture the entry point.
        snapshot("01-entry")

        // 2. Drive a real interaction. Prefer accessibility identifiers; fall back to labels.
        let openButton = app.buttons["openEditor"]
        XCTAssertTrue(openButton.waitForExistence(timeout: 5))
        openButton.tap()
        snapshot("02-editor")

        // 3. Type into a field. Editable content is a TextField whose `value` is the text.
        let titleField = app.textFields["titleField"]
        titleField.tap()
        titleField.typeText("Call my mother")
        snapshot("03-filled")

        // 4. If a system alert appears (e.g. a permission prompt), accept it inside the
        //    test, because the ephemeral clone simulator will not carry a prior grant.
        addUIInterruptionMonitor(withDescription: "permission") { alert in
            for label in ["Allow", "Allow Full Access", "OK"] {
                if alert.buttons[label].exists { alert.buttons[label].tap(); return true }
            }
            return false
        }
        app.buttons["save"].tap()
        app.tap() // nudge the interruption monitor to fire
        snapshot("04-saved")

        // 5. Verify content. Text shows as a TextField value, not a staticText - match by value.
        let saved = app.textFields
            .matching(NSPredicate(format: "value CONTAINS[c] %@", "Call my mother"))
            .firstMatch
        XCTAssertTrue(saved.waitForExistence(timeout: 5))

        // 6. To inspect a system app (Reminders, Settings, Health), drive it by bundle id.
        let reminders = XCUIApplication(bundleIdentifier: "com.apple.reminders")
        reminders.launch()
        snapshot("05-reminders")
    }
}
