import XCTest
@testable import RookieLab

@MainActor
final class OpeningLabTests: XCTestCase {
  private func route(side: Side = .white, account: String = "chesscom:test", moves: [String] = ["e2e4", "e7e5", "g1f3", "b8c6", "f1c4", "f8c5"]) -> OpeningRoute {
    .init(account: account, name: "Italian Game", side: side, moves: moves)
  }
  func testBundledBookMatchesWebsiteAndOffersLegalCandidates() {
    XCTAssertTrue(OpeningBook.shared.available)
    // 此值由網站 bookKey.mjs 產生，確保 Swift 的 FNV 與 JS 同一套。
    XCTAssertEqual(OpeningBook.key(AnalysisModel.standard), "s9umv7")
    let options = OpeningBook.shared.candidates(AnalysisModel.standard)
    XCTAssertTrue(options.contains { $0.uci == "e2e4" })
    XCTAssertTrue(options.contains { $0.uci == "d2d4" })
    for option in options {
      let ply = ChessLine.ply(fen: AnalysisModel.standard, uci: option.uci, index: 0)
      XCTAssertNotNil(ply)
      XCTAssertNotNil(ply.flatMap { OpeningBook.shared.position($0.fenAfter) })
    }
  }
  func testPracticeAutoplaysOnlyOpponentAndCompletesWholeRoute() {
    let white = OpeningExercise(route: route())
    XCTAssertEqual(white.cursor, 0)
    white.move("e2e4")
    XCTAssertEqual(white.cursor, 2)
    XCTAssertEqual(white.expected?.uci, "g1f3")
    white.move("g1f3"); white.move("f1c4")
    XCTAssertTrue(white.finished)
    XCTAssertEqual(white.completed, 3)
    XCTAssertTrue(white.clean)
    let black = OpeningExercise(route: route(side: .black))
    XCTAssertEqual(black.cursor, 1)
    black.move("e7e5"); black.move("b8c6"); black.move("f8c5")
    XCTAssertTrue(black.finished)
  }
  func testAlternativeAndHintDoNotPassSelectedRoute() {
    let exercise = OpeningExercise(route: route())
    exercise.move("d2d4")
    XCTAssertEqual(exercise.cursor, 0)
    XCTAssertFalse(exercise.clean)
    XCTAssertNotNil(exercise.feedback)
    XCTAssertFalse(exercise.hint, "不能自動洩漏答案")
    exercise.showHint()
    XCTAssertTrue(exercise.hint)
    exercise.move("e2e4")
    XCTAssertFalse(exercise.hint)
    XCTAssertFalse(exercise.clean)
  }
  func testDedupAccountIsolationCooldownAndHelpedRecall() {
    let store = OpeningReviewStore(defaults: nil, sync: false)
    let r = route()
    XCTAssertTrue(store.add(r, today: 100))
    XCTAssertFalse(store.add(r, today: 100))
    XCTAssertEqual(store.due(account: r.account, today: 100).count, 1)
    XCTAssertTrue(store.due(account: "another", today: 100).isEmpty)
    store.answer(r.id, clean: true, today: 100)
    XCTAssertEqual(store.cards.first?.streak, 1)
    XCTAssertEqual(store.cards.first?.due, 103)
    store.answer(r.id, clean: true, today: 101)
    XCTAssertEqual(store.cards.first?.reps, 1, "提前練不推進記憶")
    XCTAssertFalse(store.add(r, today: 101))
    XCTAssertEqual(store.cards.first?.due, 103, "再次加入不重設排程")
    store.answer(r.id, clean: false, today: 103)
    XCTAssertEqual(store.cards.first?.streak, 0)
    XCTAssertEqual(store.cards.first?.due, 106)
    store.remove(r.id)
    XCTAssertTrue(store.active(account: r.account).isEmpty)
    XCTAssertTrue(store.add(r, today: 104))
    XCTAssertEqual(store.cards.count, 1)
  }
  func testRejectsInvalidOrUnrecordedRoutes() {
    let store = OpeningReviewStore(defaults: nil, sync: false)
    XCTAssertFalse(store.add(route(moves: [])))
    XCTAssertFalse(store.add(route(moves: ["e2e5"])))
    XCTAssertFalse(store.add(route(side: .black, moves: ["e2e4"])))
    XCTAssertTrue(route().valid)
  }
  func testProgressPersists() {
    let suite = "opening-tests-" + UUID().uuidString
    let defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite) }
    let store = OpeningReviewStore(defaults: defaults, sync: false)
    store.add(route(), today: 200); store.answer(route().id, clean: true, today: 200)
    let reloaded = OpeningReviewStore(defaults: defaults, sync: false)
    XCTAssertEqual(reloaded.cards.first?.due, 203)
    XCTAssertEqual(reloaded.cards.first?.streak, 1)
  }
  func testProfileDoesNotTreatOpponentDepartureOrLowWinRateAsUnfamiliar() {
    func game(_ id: String, _ pgn: String, _ side: Side = .white) -> GameSummary {
      .init(id: id, platform: .chesscom, endedAt: Date(), color: side, opponent: "opponent", myRating: nil, opponentRating: nil,
        result: .loss, timeClass: "rapid", timeControl: "600", pgn: "[Opening \"Italian Game\"]\n" + pgn, url: nil)
    }
    let opponent = OpeningProfile.build(games: (1...3).map { game(String($0), "1. e4 e5 2. Nf3 a6") })[0]
    XCTAssertEqual(opponent.leftByMe, 0)
    XCTAssertEqual(opponent.leftByOpponent, 3)
    XCTAssertTrue(opponent.departures.isEmpty)
    let mine = OpeningProfile.build(games: (1...3).map { game(String($0), "1. e4 e5 2. Nf3 Nc6 3. a4") })[0]
    XCTAssertEqual(mine.leftByMe, 3)
    XCTAssertEqual(mine.departures.first?.played.san, "a4")
    XCTAssertEqual(mine.departures.first?.line.count, 4, "探索應停在偏離之前")
    let mixed = OpeningProfile.build(games: [game("white", "1. e4 e5 2. Nf3 Nc6"), game("black", "1. e4 e5 2. Nf3 Nc6", .black)])
    XCTAssertEqual(mixed.count, 2, "同一開局的黑白分開")
  }

}
