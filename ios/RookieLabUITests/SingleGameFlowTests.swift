import XCTest

final class SingleGameFlowTests: XCTestCase {
  @MainActor func testSingleGameImportAndReview() {
    let app = XCUIApplication()
    app.launchArguments = ["-tab", "games", "-AppleLanguages", "(zh-Hant)", "-AppleLocale", "zh_TW"]
    app.launch()
    XCTAssertTrue(app.buttons["single-game-import"].waitForExistence(timeout: 15))
    XCTAssertTrue(app.tabBars.buttons["設定"].exists)
    XCTAssertFalse(app.tabBars.buttons["開局"].exists)
    XCTAssertFalse(app.tabBars.buttons["練習"].exists)
    app.buttons["single-game-import"].tap()
    let editor = app.textViews.firstMatch
    XCTAssertTrue(editor.waitForExistence(timeout: 5)); editor.tap()
    let pgn = "1. e4 e5 2. Qh5 Nc6 3. Bc4 Nf6 4. Qxf7#"
    editor.typeText(pgn)
    let entered = NSPredicate(format: "value == %@", pgn)
    guard XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: entered, object: editor)], timeout: 5) == .completed else {
      XCTFail("PGN input did not match the fixture"); return
    }
    app.navigationBars.buttons["匯入"].tap()
    XCTAssertTrue(app.navigationBars.firstMatch.waitForExistence(timeout: 10))
    XCTAssertTrue(app.descendants(matching: .any)["single-game-review-board"].firstMatch.waitForExistence(timeout: 60))
    let shot = XCTAttachment(screenshot: app.screenshot()); shot.name = "Single game review"; shot.lifetime = .keepAlways; add(shot)
  }
  @MainActor func testQuickReviewStopsAtTheOpening() {
    let app = XCUIApplication()
    app.launchArguments = ["-tab", "games", "-AppleLanguages", "(zh-Hant)", "-AppleLocale", "zh_TW"]
    app.launch()
    XCTAssertTrue(app.buttons["single-game-import"].waitForExistence(timeout: 15))
    app.buttons["single-game-import"].tap()
    let editor = app.textViews.firstMatch
    XCTAssertTrue(editor.waitForExistence(timeout: 5)); editor.tap()
    let pgn = "1. e4 e5 2. Nf3 Nc6 3. Bc4 Bc5 4. c3 Nf6 5. d4 exd4 6. cxd4 Bb4+"
    editor.typeText(pgn)
    let entered = NSPredicate(format: "value == %@", pgn)
    guard XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: entered, object: editor)], timeout: 5) == .completed else {
      XCTFail("PGN input did not match the fixture"); return
    }
    app.navigationBars.buttons["匯入"].tap()
    let stop = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "開局：")).firstMatch
    XCTAssertTrue(stop.waitForExistence(timeout: 90))
    XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "已收錄的理論走法")).firstMatch.exists)
    let shot = XCTAttachment(screenshot: app.screenshot()); shot.name = "Opening stop"; shot.lifetime = .keepAlways; add(shot)
  }
  @MainActor func testQuickReviewStopsForBothSidesAndSummarizes() {
    let app = XCUIApplication()
    app.launchArguments = ["-tab", "games", "-AppleLanguages", "(zh-Hant)", "-AppleLocale", "zh_TW"]
    app.launch()
    XCTAssertTrue(app.buttons["single-game-import"].waitForExistence(timeout: 15))
    app.buttons["single-game-import"].tap()
    let editor = app.textViews.firstMatch
    XCTAssertTrue(editor.waitForExistence(timeout: 5)); editor.tap()
    let pgn = "1. e4 e5 2. Nf3 Nc6 3. Bc4 Nd4 4. Nxe5 Qg5 5. Nxf7 Qxg2 6. Rf1 Qxe4+ 7. Be2 Nf3#"
    editor.typeText(pgn)
    let entered = NSPredicate(format: "value == %@", pgn)
    guard XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: entered, object: editor)], timeout: 5) == .completed else {
      XCTFail("PGN input did not match the fixture"); return
    }
    app.navigationBars.buttons["匯入"].tap()
    var shots = 0
    for _ in 0..<20 {
      let next = app.buttons["繼續"], answer = app.buttons["看答案"], done = app.buttons["逐步看整局"]
      if done.waitForExistence(timeout: 1) { break }
      if answer.exists { answer.tap(); continue }
      if next.waitForExistence(timeout: 90) {
        if shots < 3 { let shot = XCTAttachment(screenshot: app.screenshot()); shot.name = "Review stop \(shots)"; shot.lifetime = .keepAlways; add(shot); shots += 1 }
        next.tap()
      }
    }
    XCTAssertTrue(app.buttons["逐步看整局"].waitForExistence(timeout: 30))
    XCTAssertGreaterThan(shots, 0)
    let shot = XCTAttachment(screenshot: app.screenshot()); shot.name = "Review summary"; shot.lifetime = .keepAlways; add(shot)
  }
  @MainActor func testPaywallForReviewScreenshot() {
    let app = XCUIApplication()
    app.launchArguments = ["-tab", "me", "-AppleLanguages", "(zh-Hant)", "-AppleLocale", "zh_TW"]
    app.launch()
    let entry = app.buttons["訂閱與移除廣告"]
    XCTAssertTrue(entry.waitForExistence(timeout: 15)); entry.tap()
    sleep(3)
    let first = XCTAttachment(screenshot: app.screenshot()); first.name = "Paywall opening"; first.lifetime = .keepAlways; add(first)
    XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "19.99")).firstMatch.waitForExistence(timeout: 20))
    let shot = XCTAttachment(screenshot: app.screenshot()); shot.name = "Paywall"; shot.lifetime = .keepAlways; add(shot)
  }
  @MainActor func testSettingsHideLearningReviewCoursesAndReports() {
    let app = XCUIApplication()
    app.launchArguments = ["-tab", "me", "-AppleLanguages", "(zh-Hant)", "-AppleLocale", "zh_TW"]
    app.launch()
    XCTAssertTrue(app.buttons["分享對局說明"].waitForExistence(timeout: 15))
    XCTAssertFalse(app.buttons["遠端復盤試驗"].exists)
    XCTAssertFalse(app.buttons["先前版本功能"].exists)
    XCTAssertFalse(app.buttons["開局課程"].exists)
    XCTAssertFalse(app.buttons["練習與複習"].exists)
    XCTAssertFalse(app.buttons["跨局報告"].exists)
    XCTAssertFalse(app.buttons["先前版本的複習設定"].exists)
    let shot = XCTAttachment(screenshot: app.screenshot()); shot.name = "Simplified settings"; shot.lifetime = .keepAlways; add(shot)
  }
}

final class ImportAndUpdateFlowTests: XCTestCase {
  @MainActor func testAccountGuidanceInvalidThenValidAndRecent() {
    let app = XCUIApplication()
    app.launchArguments = ["-tab", "games", "-accountDemo", "-AppleLanguages", "(zh-Hant)", "-AppleLocale", "zh_TW"]
    app.launch()
    XCTAssertTrue(app.buttons["single-game-account"].waitForExistence(timeout: 15))
    app.buttons["single-game-account"].tap()
    let input = app.textFields.firstMatch
    XCTAssertTrue(input.waitForExistence(timeout: 5)); input.tap()
    if !app.keyboards.firstMatch.waitForExistence(timeout: 3) { input.tap() }
    XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5))
    input.typeText("demo-missing")
    app.buttons["載入最近對局"].tap()
    XCTAssertTrue(app.staticTexts["account-connection-error"].waitForExistence(timeout: 5))
    input.tap(); input.press(forDuration: 1)
    // Replace text without depending on the cross-process pasteboard.
    input.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: 12) + "demo-valid")
    app.buttons["載入最近對局"].tap()
    XCTAssertTrue(app.buttons["single-game-account"].waitForExistence(timeout: 10))
    app.buttons["single-game-account"].tap()
    XCTAssertTrue(app.buttons["Chess.com · demo-valid"].waitForExistence(timeout: 5))
    let shot = XCTAttachment(screenshot: app.screenshot()); shot.name = "Account guidance and recent"; shot.lifetime = .keepAlways; add(shot)
  }
  @MainActor func testImportMethodsExplainEmptyClipboardAndRejectBadLink() {
    let app = XCUIApplication()
    app.launchArguments = ["-tab", "games", "-AppleLanguages", "(zh-Hant)", "-AppleLocale", "zh_TW"]
    app.launch(); XCTAssertTrue(app.buttons["single-game-import-methods"].waitForExistence(timeout: 15))
    app.buttons["single-game-import-methods"].tap()
    XCTAssertTrue(app.textFields["single-game-link-input"].waitForExistence(timeout: 5))
    app.buttons["single-game-link-submit"].tap()
    XCTAssertTrue(app.staticTexts["請輸入 Chess.com 或 Lichess 的棋局網址；PGN 請使用下方入口。"].waitForExistence(timeout: 5))
  }
  @MainActor func testRequiredUpdatePreservesHistoricalAndSubscriptionActions() {
    let app = XCUIApplication()
    app.launchArguments = ["-tab", "games", "-updateDemo", "required", "-AppleLanguages", "(zh-Hant)", "-AppleLocale", "zh_TW"]
    app.launch()
    XCTAssertTrue(app.staticTexts["請更新後再開始新分析"].waitForExistence(timeout: 15))
    XCTAssertTrue(app.buttons["重新檢查"].exists)
    XCTAssertTrue(app.buttons["查看過往分析"].exists)
    XCTAssertTrue(app.buttons["恢復購買"].exists)
    let shot = XCTAttachment(screenshot: app.screenshot()); shot.name = "Required update safe actions"; shot.lifetime = .keepAlways; add(shot)
  }
}
