import XCTest

/// 商店截圖原圖（6.9 吋模擬器）：xcodebuild test … -only-testing:RookieLabUITests/StoreScreenshotTests，再用 ios/store/frame.py 加標題
final class StoreScreenshotTests: XCTestCase {
  private let pgn = "1. e4 e5 2. Nf3 Nc6 3. Bc4 Nf6 4. d3 Bc5 5. O-O d6 6. c3 O-O 7. Bg5 h6 8. Bh4 g5 9. Nxg5 hxg5 10. Bxg5 Kg7 11. Qf3 Be6 12. Nd2 Bxc4 13. Nxc4 Rh8 14. Bxf6+ Qxf6 15. Qxf6+ Kxf6 16. Ne3 Ke6"

  @MainActor func testZhHant() { capture(["-AppleLanguages", "(zh-Hant)", "-AppleLocale", "zh_TW"], next: "繼續", answer: "看答案", done: "逐步看整局", importLabel: "匯入", opening: "開局：") }
  @MainActor func testEnglish() { capture(["-AppleLanguages", "(en)", "-AppleLocale", "en_US"], next: "Continue", answer: "Show answer", done: "Step through the whole game", importLabel: "Import", opening: "Opening:") }

  @MainActor private func capture(_ lang: [String], next: String, answer: String, done: String, importLabel: String, opening: String) {
    let app = XCUIApplication()
    app.launchArguments = ["-tab", "games", "-storeScreenshots", "-prefillPGN", pgn] + lang
    app.launch()
    func shot(_ name: String) { let s = XCTAttachment(screenshot: app.screenshot()); s.name = name; s.lifetime = .keepAlways; add(s) }
    XCTAssertTrue(app.buttons["single-game-import"].waitForExistence(timeout: 15))
    app.buttons["single-game-import"].tap()
    XCTAssertTrue(app.textViews.firstMatch.waitForExistence(timeout: 5))
    app.navigationBars.buttons[importLabel].tap()
    // PGN 讀不進去時匯入畫面不會關：直接失敗，不要空等
    guard !app.navigationBars.buttons[importLabel].waitForExistence(timeout: 3) else { XCTFail("PGN was rejected"); return }
    var have = Set<String>()
    for _ in 0..<30 {
      if app.buttons[done].waitForExistence(timeout: 1) { break }
      if app.buttons[answer].exists {
        if !have.contains("4-find") { shot("4-find"); have.insert("4-find") }
        app.buttons[answer].tap(); continue
      }
      // 等到「繼續」「看答案」或結尾任一個出現（找步的停點沒有「繼續」）
      let progressed = NSPredicate { _, _ in app.buttons[next].exists || app.buttons[answer].exists || app.buttons[done].exists }
      guard XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: progressed, object: nil)], timeout: 90) == .completed else { break }
      guard app.buttons[next].exists else { continue }
      let isOpening = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", opening)).firstMatch.exists
      let key = isOpening ? "2-opening" : "3-stop"
      if !have.contains(key) { sleep(1); shot(key); have.insert(key) }
      app.buttons[next].tap()
    }
    XCTAssertTrue(app.buttons[done].waitForExistence(timeout: 60))
    shot("5-summary")
    app.navigationBars.buttons.element(boundBy: 0).tap()
    sleep(2)
    shot("1-home")
  }
}
