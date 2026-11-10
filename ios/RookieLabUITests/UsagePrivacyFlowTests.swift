import XCTest

final class UsagePrivacyFlowTests: XCTestCase {
  @MainActor func testAccountSharingStartsOffAndUsageOptOutDisablesIt() {
    let app = XCUIApplication()
    app.launchArguments = ["-tab", "me", "-usagePrivacyUITest",
                           "-AppleLanguages", "(zh-Hant)", "-AppleLocale", "zh_TW"]
    app.launch()
    let entry = app.buttons["使用統計與隱私"]
    XCTAssertTrue(entry.waitForExistence(timeout: 15)); entry.tap()
    let accounts = app.switches["分享我輸入的棋站帳號"]
    XCTAssertTrue(accounts.waitForExistence(timeout: 5))
    XCTAssertEqual(accounts.value as? String, "0")
    let usage = app.switches["使用統計與診斷"]
    usage.coordinate(withNormalizedOffset: CGVector(dx: 0.93, dy: 0.5)).tap()
    let off = NSPredicate(format: "value == '0'")
    XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: off, object: usage)], timeout: 5), .completed)
    XCTAssertEqual(usage.value as? String, "0")
    XCTAssertFalse(accounts.isEnabled)
    let shot = XCTAttachment(screenshot: app.screenshot()); shot.name = "Usage privacy and account linking"; shot.lifetime = .keepAlways; add(shot)
  }
}

/// Deliberate Firebase DebugView probe. Sends only a synthetic game workflow with dev flags.
final class FirebasePilotFlowTests: XCTestCase {
  @MainActor func testSyntheticAnalysisSendsDebugEvents() throws {
    try XCTSkipUnless(ProcessInfo.processInfo.environment["ROOKIELAB_FIREBASE_PILOT"] == "1")
    let app = XCUIApplication()
    app.launchArguments = ["-tab", "games", "-FIRAnalyticsDebugEnabled", "-telemetryInSimulator", "YES",
                           "-telemetry.usage.enabled", "YES", "-telemetry.accountLink.enabled", "NO",
                           "-AppleLanguages", "(zh-Hant)", "-AppleLocale", "zh_TW"]
    app.launch()
    let importButton = app.buttons["single-game-import"]
    XCTAssertTrue(importButton.waitForExistence(timeout: 15)); importButton.tap()
    let editor = app.textViews.firstMatch
    XCTAssertTrue(editor.waitForExistence(timeout: 5)); editor.tap()
    editor.typeText("1. d4 e5 2. dxe5 Nc6 3. Nf3 f6 {fixture \(UUID().uuidString.prefix(8))} *")
    app.navigationBars.buttons["匯入"].tap()
    XCTAssertTrue(app.descendants(matching: .any)["single-game-review-board"].firstMatch.waitForExistence(timeout: 60))
    XCUIDevice.shared.press(.home)
  }
}
