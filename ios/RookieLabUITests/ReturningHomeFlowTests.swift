import XCTest

final class ReturningHomeFlowTests: XCTestCase {
  @MainActor func launch(_ state: String) -> XCUIApplication {
    let app = XCUIApplication()
    app.launchArguments = ["-tab", "games", "-homeDemo", state, "-AppleLanguages", "(zh-Hant)", "-AppleLocale", "zh_TW"]
    app.launch(); return app
  }
  @MainActor func testFirstUseShowsGuidance() {
    let app = launch("first")
    XCTAssertTrue(app.descendants(matching: .any)["single-game-first-use"].firstMatch.waitForExistence(timeout: 15))
    XCTAssertFalse(app.buttons["single-game-analyze-latest"].exists)
    XCTAssertTrue(app.buttons["single-game-account"].exists)
  }
  @MainActor func testNewGamePrimaryActionOpensReviewWithoutImport() {
    let app = launch("new")
    XCTAssertTrue(app.buttons["single-game-analyze-latest"].waitForExistence(timeout: 15))
    XCTAssertTrue(app.staticTexts["偵測到新對局"].exists)
    XCTAssertFalse(app.descendants(matching: .any)["single-game-first-use"].firstMatch.exists)
    let shot = XCTAttachment(screenshot: app.screenshot()); shot.name = "Returning home new game"; shot.lifetime = .keepAlways; add(shot)
    app.buttons["single-game-analyze-latest"].tap()
    XCTAssertTrue(app.descendants(matching: .any)["single-game-review-board"].firstMatch.waitForExistence(timeout: 60))
    XCTAssertTrue(app.descendants(matching: .any)["guided-quick-review"].firstMatch.waitForExistence(timeout: 15))
    // Reopen the saved result: cached analysis must still enter the guided review.
    app.navigationBars.buttons.firstMatch.tap()
    XCTAssertTrue(app.buttons["single-game-analyze-latest"].waitForExistence(timeout: 10))
    app.buttons["single-game-analyze-latest"].tap()
    XCTAssertTrue(app.descendants(matching: .any)["guided-quick-review"].firstMatch.waitForExistence(timeout: 15))
    app.buttons["結束快速復盤"].tap()
    XCTAssertTrue(app.buttons["開始復盤"].waitForExistence(timeout: 5) || app.buttons["快速復盤"].exists)
    XCTAssertFalse(app.descendants(matching: .any)["guided-quick-review"].firstMatch.exists)

  }
  @MainActor func testGameWithoutHighlightsStillOpensGuidedQuickReview() {
    let app = launch("no-highlights")
    let analyze = app.buttons["single-game-analyze-latest"]
    XCTAssertTrue(analyze.waitForExistence(timeout: 15))
    analyze.tap()
    XCTAssertTrue(app.descendants(matching: .any)["guided-quick-review"].firstMatch.waitForExistence(timeout: 60))
  }

  @MainActor func testReviewedHomeOffersExistingReview() {
    let app = launch("reviewed")
    XCTAssertTrue(app.buttons["single-game-view-latest"].waitForExistence(timeout: 15))
    XCTAssertFalse(app.buttons["single-game-analyze-latest"].exists)
    XCTAssertTrue(app.staticTexts["最近的對局都已分析"].exists)
    let shot = XCTAttachment(screenshot: app.screenshot()); shot.name = "Returning home already reviewed"; shot.lifetime = .keepAlways; add(shot)
  }
}
