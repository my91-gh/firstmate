---
name: ios-simulator-ui-driving
description: Drive and screenshot a running iOS app in the Simulator from the command line, especially when no interactive tap tool is available and you must drive the UI yourself. Use this whenever you need to tap through an app flow, verify a feature end to end on a simulator, capture screenshots of real app screens, grant a runtime permission (Reminders, Health, Photos, Contacts, Location), reset an app to a fresh install, or jump straight to a screen with a launch argument. Reach for it on any "run it in the simulator and check / screenshot X" task, even when the request only says "show me the screen" or "confirm it works on device" - the reliable path is an XCUITest, not hand-tapping.
---

# Driving an iOS app in the Simulator

This skill captures a reliable, command-line-only recipe for interacting with a running iOS app and capturing what you see.
It exists because the obvious approach - "tap the button, take a screenshot" - usually is not available headless.

## The core obstacle, and the strategy

Most command-line simulator setups can **build, launch, and screenshot**, and can read the accessibility hierarchy, but they **cannot reliably perform an interactive tap**.
The interactive `tap` of an MCP/automation bridge is frequently disabled, and `idb`, `cliclick`, and AppleScript GUI control are often unavailable or blocked.
`simctl` cannot tap either.

So the dependable way to *drive* the UI is from inside the app's own test host: a short, throwaway **XCUITest** that taps through the flow and captures `XCTAttachment` screenshots.
The test runs real touches against the real app and the screenshots survive in the `.xcresult` bundle, which you then export to image files.

There is one insight that trips people up: `xcodebuild test` runs on an **ephemeral cloned simulator** ("Clone 1 of iPhone 16 Pro"), created for the run and torn down after.
The base simulator you booted is not the one the test drives.
That has two consequences you must design around:

- **Do all the work inside one test method on the clone.** You cannot prepare state on the base device, run the test, and then inspect the base device for the result - the test ran somewhere else and that somewhere is gone.
- **A `simctl privacy grant` on the base device does not reliably reach the clone.** Grant permission from inside the test (accept the system alert), or pre-seed it on the clone, not the base device.

## Recipe

### 1. Orient

Identify the scheme, the UI-test target, the app bundle id, and any launch arguments the app honours.
Read the relevant view code to learn how a screen is reached and what accessibility identifiers or labels its controls have.
If the app already exposes a launch argument to jump to a screen (for example `-aScreen value`), prefer it - it removes whole stretches of navigation from the test.

### 2. Decide how you will drive

Try the interactive tap first if you have one; it is simpler when it works.
If it is unavailable or flaky, switch to the XCUITest path below and do not keep fighting the bridge.

### 3. Write a scratch XCUITest

Add one test method to the app's UI-test target.
See `references/xcuitest-template.swift` for a complete, copyable template.
The shape is:

- `let app = XCUIApplication()`, set `app.launchArguments` to jump to the target screen, `app.launch()`.
- Drive with real queries: `app.buttons["..."].tap()`, `app.staticTexts["..."]`, `app.textFields["..."].typeText("...")`.
- After each meaningful state, capture a screenshot as an attachment with `keepAlways` so it lands in the `.xcresult`:

```swift
func snapshot(_ name: String) {
    let shot = XCUIScreen.main.screenshot()
    let att = XCTAttachment(screenshot: shot)
    att.name = name
    att.lifetime = .keepAlways
    add(att)
}
```

- If the flow crosses into a **system app** (Settings, Reminders, Health), launch it by bundle id with a second `XCUIApplication(bundleIdentifier:)` and `springboard`-style queries; you can screenshot those too.

This test is scratch.
It is a means to drive and capture, not a shipped test - keep it out of the committed suite (delete it, or clearly mark it) when you are done.

### 4. Run the test with a known result-bundle path

Pass `-resultBundlePath` so you know exactly where the `.xcresult` lands instead of hunting through DerivedData:

```bash
xcodebuild test \
  -scheme <Scheme> \
  -destination 'platform=iOS Simulator,name=iPhone 16 Pro' \
  -only-testing:<UITestTarget>/<TestClass>/<testMethod> \
  -resultBundlePath /tmp/uidrive.xcresult
```

### 5. Export the screenshots

The attachments live inside the `.xcresult`; export them to real files with the bundled script:

```bash
scripts/export-attachments.sh /tmp/uidrive.xcresult ./screenshots
```

It wraps `xcrun xcresulttool export attachments` and renames the output to the `XCTAttachment.name` values you set, so `01-home`, `02-detail`, and so on come out as named PNGs.
Save them where they need to live; if a supervising process expects them in a specific directory, write them straight there, because the working copy may be discarded.

## Simulator state and permissions

- **Fresh install for first-run / empty-state shots.** Persistent stores (Core Data, UserDefaults, the Health/Reminders databases) survive between runs and leak state into screenshots. Reset with `xcrun simctl uninstall <booted|udid> <bundle-id>` (or `simctl erase` for the whole device) before a run that must show a clean slate.
- **Runtime permissions.** For a permission-gated feature you can pre-grant on the device with `xcrun simctl privacy <udid> grant <service> <bundle-id>` (services: `reminders`, `calendar`, `contacts`, `photos`, `location`, `microphone`, `camera`, and more) - but remember the ephemeral-clone caveat: when driving through `xcodebuild test`, accept the live permission alert inside the test instead, or the clone will not have the grant.
- **Reminders / Calendar need a default list first.** On a brand-new simulator, `EKEventStore.defaultCalendarForNewReminders()` returns nil until the Reminders app has been opened once and its welcome completed - so a write silently no-ops even with permission granted. Open Reminders once (it creates the default list) before exercising any reminder-writing feature. This is a simulator-only artifact; real devices always have a default list.
- **Jump to a screen with launch arguments.** `app.launchArguments = ["-someState", "value"]` (or `simctl launch <udid> <bundle-id> -someState value`) lands you on a deep screen without tapping through everything before it.

## Locating elements

- Read the **accessibility hierarchy** (a read-only `snapshot_ui` / `XCUIElement.debugDescription`) to find the exact query for a control before you tap it; guessing labels wastes runs.
- **Editable text shows up as a `TextField` whose `value` is the text, not as a `staticText`.** A field that plainly reads "Call your mother." will fail `app.staticTexts["Call your mother."]`; match it with a value predicate instead:

```swift
app.textFields.matching(NSPredicate(format: "value CONTAINS[c] %@", "Call your mother")).firstMatch
```

## Cleanup

The test, any seed code, and the working copy are scratch.
Remove the throwaway test and any debug instrumentation before you finish, so nothing scratch rides into a commit; the exported screenshots and your written findings are the only things worth keeping.

## Quick gotcha list

- No interactive tap -> drive with an XCUITest, do not fight the bridge.
- `xcodebuild test` uses an ephemeral clone -> do everything in one test method; grant permissions inside the test.
- Persistent state leaks into shots -> `simctl uninstall` for a clean slate.
- Reminders/Calendar write no-ops on a fresh sim -> open Reminders once to create the default list.
- Text content is a `TextField.value`, not a `staticText` -> match with a value predicate.
- Pass `-resultBundlePath` so you can find the `.xcresult` to export from.
