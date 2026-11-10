import XCTest

final class AdMobFlowTests: XCTestCase {
  @MainActor func testGoogleTestBannerLoadsOnHome() throws {
    let app = XCUIApplication()
    app.launchArguments = ["-tab", "games", "-AppleLanguages", "(zh-Hant)", "-AppleLocale", "zh_TW"]
    app.launch()
    XCTAssertTrue(app.descendants(matching: .any)["single-game-ad"].firstMatch.waitForExistence(timeout: 75), "Google test Banner should load through the real SDK")
    let shot = XCTAttachment(screenshot: app.screenshot()); shot.name = "AdMob official test Banner"; shot.lifetime = .keepAlways; add(shot)
  }
}
