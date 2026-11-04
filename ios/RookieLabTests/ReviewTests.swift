import XCTest
@testable import RookieLab

@MainActor
final class ReviewTests: XCTestCase {
  private func card(_ id: String) -> ReviewCard {
    ReviewCard(id: id, gameId: "g", platform: .chesscom, opponent: "x", date: Date(), ply: 10, moveNumber: 6,
               fen: "4k3/8/8/3q4/8/8/8/3QK3 w - - 0 1", played: "Ke2", moves: ["d1d5"], accept: nil, kinds: [.tactic], headline: "漏吃", due: Day.number())
  }

  /// iCloud 合併：同一張卡留練得多的那份、兩邊各自有的都留；每天題數取大的
  func testCloudMerge() {
    var a = card("a"); a.reps = 1
    var aRemote = card("a"); aRemote.reps = 3; aRemote.lastDay = 10
    let b = card("b")
    let m = CloudSync.merged(local: .init(cards: [a], days: [5: 2, 6: 1]), remote: .init(cards: [aRemote, b], days: [5: 4]))
    XCTAssertEqual(m.cards.count, 2)
    XCTAssertEqual(m.cards.first { $0.id == "a" }?.reps, 3)
    XCTAssertEqual(m.days, [5: 4, 6: 1])
  }

  /// 答對 3 天 → 7 天 → 乘上 2.5；答錯 3 天後再出、係數降 0.2；連續 3 次算學會
  func testSchedule() {
    let s = ReviewStore(persist: false)
    s.add([card("a")])
    s.answer("a", ok: true)
    XCTAssertEqual(s.cards[0].interval, 3)
    s.answer("a", ok: true)
    XCTAssertEqual(s.cards[0].interval, 7)
    s.answer("a", ok: true)
    XCTAssertEqual(s.cards[0].interval, 18)
    XCTAssertTrue(s.cards[0].mastered)
    s.answer("a", ok: false)
    XCTAssertEqual(s.cards[0].interval, 3)
    XCTAssertEqual(s.cards[0].ease, 2.3, accuracy: 0.001)
    XCTAssertFalse(s.cards[0].mastered)
    XCTAssertEqual(s.add([card("a")]), 0, "不重複加")
  }

  /// 連續天數：今天還沒練不算斷
  func testStreak() {
    let s = ReviewStore(persist: false)
    let today = Day.number()
    s.markPracticed(on: today - 1)
    s.markPracticed(on: today - 2)
    XCTAssertEqual(s.streak, 2)
    s.markPracticed(on: today)
    XCTAssertEqual(s.streak, 3)
    s.markPracticed(on: today - 4)
    XCTAssertEqual(s.streak, 3, "中間斷一天就重新算")
  }

  /// 一次加很多題：今天只出 5 題新題
  func testNewPerDay() {
    let s = ReviewStore(persist: false)
    s.add((0..<12).map { card("n\($0)") })
    XCTAssertEqual(s.dueCards.count, 5)
    s.answer(s.session()[0].id, ok: true)
    XCTAssertEqual(s.dueCards.count, 4, "做完一題新題，額度少一題")
  }

  func testCooldownForEveryRecallAndLegacySchedule() {
    for recall: ReviewStore.Recall in [.clean, .helped, .shown] {
      let s = ReviewStore(persist: false)
      s.add([card("a")])
      s.answer("a", recall: recall)
      XCTAssertEqual(s.cards[0].due, Day.number() + 3)
      XCTAssertTrue(s.session().isEmpty)
      XCTAssertTrue(s.session(kind: .tactic).isEmpty)
    }
    let s = ReviewStore(persist: false)
    var recent = card("recent")
    recent.reps = 1; recent.lastDay = Day.number() - 1; recent.due = Day.number()
    var ready = card("ready")
    ready.reps = 1; ready.lastDay = Day.number() - 3
    s.add([recent, ready])
    XCTAssertEqual(s.session().map(\.id), ["ready"], "舊的一天排程也要遵守冷卻")
  }

  func testThemePickingKeepsFreshWhenLessThanAFullSet() {
    let seen = ["today": 100, "yesterday": 99, "due": 97, "oldest": 90]
    let ids = ["today", "due", "new", "yesterday", "oldest"]
    XCTAssertEqual(PuzzleBank.pickIDs(ids, seen: seen, today: 100, n: 10), ["new", "oldest", "due"])
    XCTAssertTrue(PuzzleBank.pickIDs(["today", "yesterday"], seen: seen, today: 100, n: 5).isEmpty)
    XCTAssertTrue(PuzzleBank.pickIDs(["fork:same"], seen: ["hanging:same": 100], today: 100, n: 5).isEmpty, "跨主題也不能立即重複")
  }

  func testWinningGameCanProducePracticeCards() throws {
    let pgn = "1. e4 e5 2. Nf3 1-0"
    let line = try XCTUnwrap(ChessLine(pgn: pgn))
    let g = GameSummary(id: "won", platform: .chesscom, endedAt: Date(), color: .white, opponent: "x",
                        myRating: 1000, opponentRating: 1000, result: .win, timeClass: "rapid", timeControl: "600", pgn: pgn, url: nil)
    let r = MoveRecord(ply: 2, san: "Nf3", uci: "g1f3", mover: .white, cls: .mistake,
                       winBefore: 0.85, winAfter: 0.45, accuracy: 50, bestUci: "b1c3", bestSan: "Nc3", altUci: nil, altSan: nil)
    let before = [EngineLine(cp: 400, mate: nil, pv: ["b1c3"]), EngineLine(cp: 0, mate: nil, pv: ["g1f3"])]
    let a = AnalyzedGame(gameId: g.id, nodes: 1, evals: [nil, nil, before, nil], records: [nil, nil, r])
    let digest = try XCTUnwrap(GameDigest(game: g, line: line, analysis: a))
    XCTAssertEqual(ReviewBuilder.cards(digest).map(\.gameId), [g.id])
    XCTAssertEqual(ReviewBuilder.requests(digest).count, 1)
  }

  private func rec(_ before: Double, _ after: Double, _ cls: MoveClass = .mistake) -> MoveRecord {
    MoveRecord(ply: 20, san: "Qd2", uci: "d1d2", mover: .white, cls: cls, winBefore: before, winAfter: after, accuracy: 50, bestUci: nil, bestSan: nil, altUci: nil, altSan: nil)
  }

  /// 只收錯失的機會：當時有勝勢、掉得夠多、而且只有一個明顯的好步
  func testOpportunityPicking() {
    let unique = [EngineLine(cp: 400, mate: nil, pv: ["a2a4"]), EngineLine(cp: 0, mate: nil, pv: ["b2b4"])]
    let many = [EngineLine(cp: 400, mate: nil, pv: ["a2a4"]), EngineLine(cp: 380, mate: nil, pv: ["b2b4"])]
    XCTAssertTrue(ReviewBuilder.isOpportunity(rec(0.85, 0.45), before: unique))
    XCTAssertFalse(ReviewBuilder.isOpportunity(rec(0.4, 0.1), before: unique), "已經落後的局面不收")
    XCTAssertFalse(ReviewBuilder.isOpportunity(rec(0.85, 0.75, .inaccuracy), before: unique), "掉得不多不收")
    XCTAssertFalse(ReviewBuilder.isOpportunity(rec(0.85, 0.45), before: many), "好幾步都差不多好，不像一道題")
  }

  /// 沒走到的題會出現在「剛剛沒走到」，答對後移到「等待複習」
  func testPoolGroups() {
    let s = ReviewStore(persist: false)
    s.add([card("a"), card("b")])
    s.answer("a", ok: false)
    s.answer("b", ok: true)
    XCTAssertEqual(s.relearning.map(\.id), ["a"])
    XCTAssertEqual(s.waiting.map(\.id), ["b"])
    s.answer("a", ok: true)
    XCTAssertTrue(s.relearning.isEmpty)
  }
}
