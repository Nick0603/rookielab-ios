import XCTest

final class OpeningCourseFlowTests: XCTestCase {
  @MainActor private func launch(_ args: [String]) -> XCUIApplication {
    let app = XCUIApplication(); app.launchArguments = args + ["-AppleLanguages", "(zh-Hant)", "-AppleLocale", "zh_TW"]; app.launch(); return app
  }
  @MainActor private func ready(_ app: XCUIApplication) {
    XCTAssertFalse(app.buttons["看前情"].exists)
    let hint = app.buttons["提示"]
    XCTAssertTrue(hint.waitForExistence(timeout: 10))
    expectation(for: NSPredicate(format: "enabled == true"), evaluatedWith: hint)
    waitForExpectations(timeout: 12)
  }
  @MainActor private func play(_ from: String, _ to: String, app: XCUIApplication, black: Bool = false) {
    ready(app)
    let board = app.descendants(matching: .any)["opening-quiz-board"].firstMatch
    XCTAssertGreaterThan(board.frame.width, 200)
    func tap(_ square: String) {
      let chars = Array(square.utf8), file = Int(chars[0]) - 97, rank = Int(chars[1]) - 49
      let x = black ? 7 - file : file, y = black ? rank : 7 - rank
      board.coordinate(withNormalizedOffset: CGVector(dx: (Double(x) + 0.5) / 8, dy: (Double(y) + 0.5) / 8)).tap()
    }
    tap(from); tap(to)
  }
  @MainActor
  func testCatalogHasIntegratedLevelsAndAutomaticallyCompletesSixPositions() {
    let app = launch(["-courseCatalog"])
    let card = app.buttons["course-card-italian-white"]
    XCTAssertTrue(card.waitForExistence(timeout: 15)); card.tap()
    let enroll = app.buttons["開始這個開局"]
    if enroll.waitForExistence(timeout: 2) { enroll.tap() }
    let stage = app.buttons["course-stage-intro"]
    XCTAssertTrue(stage.waitForExistence(timeout: 5)); stage.tap()
    for (from, to) in [("e2","e4"),("g1","f3"),("f1","c4"),("e2","e4"),("g1","f3"),("f1","c4")] {
      play(from,to,app:app)
      XCTAssertFalse(app.buttons["下一個局面"].exists)
    }
    XCTAssertTrue(app.buttons["回到關卡路徑"].waitForExistence(timeout: 8))
    XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "共作答 6 題")).firstMatch.exists)
    let screenshot = XCTAttachment(screenshot: app.screenshot()); screenshot.name = "Integrated level completed"; screenshot.lifetime = .keepAlways; add(screenshot)
    app.buttons["回到關卡路徑"].tap()
    XCTAssertFalse(app.buttons["course-stage-recall-intro"].exists)
    XCTAssertTrue(app.buttons["course-stage-main-part-2"].isEnabled)
    app.buttons["course-stage-main-part-2"].tap()
    // XCTest can wait for all board animations before tap() returns.
    // Model tests cover intermediate frames; here verify automatic readiness.
    ready(app)
    app.buttons["暫停"].tap()
    XCTAssertTrue(app.staticTexts["已暫停"].exists)
    app.buttons["繼續"].tap()
    ready(app)
  }
  @MainActor
  func testWrongAnswerAutoCorrectsAndReturnsLaterWithoutHint() {
    let app = launch(["-course","italian-white","-courseLesson"])
    play("a2","a3",app:app)
    // No next button: the opponent's reply is already in the next position.
    play("g1","f3",app:app)
    play("f1","c4",app:app)
    play("e2","e4",app:app)
    play("g1","f3",app:app)
    play("f1","c4",app:app)
    XCTAssertTrue(app.buttons["回到關卡路徑"].waitForExistence(timeout: 8))
    XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "共作答 6 題")).firstMatch.exists)
    XCTAssertFalse(app.buttons["下一個局面"].exists)
  }
  @MainActor
  func testBlackPositionsAndPauseResume() {
    let app = launch(["-course","caro-kann-black","-courseLesson"])
    ready(app)
    app.buttons["暫停"].tap()
    XCTAssertFalse(app.buttons["提示"].isEnabled)
    app.buttons["繼續"].tap()
    for (from,to) in [("c7","c6"),("d7","d5"),("d5","e4"),("c7","c6"),("d7","d5"),("d5","e4")] {
      play(from,to,app:app,black:true)
    }
    XCTAssertTrue(app.buttons["回到關卡路徑"].waitForExistence(timeout: 8))
  }
}
