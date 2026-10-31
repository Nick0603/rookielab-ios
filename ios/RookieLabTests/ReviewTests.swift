import XCTest
@testable import RookieLab

@MainActor
final class ReviewTests: XCTestCase {
  private func card(_ id: String) -> ReviewCard {
    ReviewCard(id: id, gameId: "g", platform: .chesscom, opponent: "x", date: Date(), ply: 10, moveNumber: 6,
               fen: "4k3/8/8/3q4/8/8/8/3QK3 w - - 0 1", played: "Ke2", moves: ["d1d5"], accept: nil, kinds: [.tactic], headline: "漏吃", due: Day.number())
  }

  /// 跟網站 review.ts 一樣：答對 1 天 → 3 天 → 乘上 2.5；答錯隔天再出、係數降 0.2；連續 3 次算學會
  func testSchedule() {
    let s = ReviewStore(persist: false)
    s.add([card("a")])
    s.answer("a", ok: true)
    XCTAssertEqual(s.cards[0].interval, 1)
    s.answer("a", ok: true)
    XCTAssertEqual(s.cards[0].interval, 3)
    s.answer("a", ok: true)
    XCTAssertEqual(s.cards[0].interval, 8)
    XCTAssertTrue(s.cards[0].mastered)
    s.answer("a", ok: false)
    XCTAssertEqual(s.cards[0].interval, 1)
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
