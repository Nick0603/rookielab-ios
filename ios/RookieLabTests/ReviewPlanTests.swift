import XCTest
@testable import RookieLab

@MainActor final class ReviewPlanTests: XCTestCase {
  /// win：每一步（index）走棋方的 (走前, 走後) 勝率；沒列的當作 0.5 → 0.5 的「不錯」（不會被當成抓到機會）
  private func model(_ pgn: String, me: Side = .white, moves: [Int: (MoveClass, Double, Double)]) throws -> ReviewModel {
    let line = try XCTUnwrap(ChessLine(pgn: pgn))
    let game = GameSummary(id: "plan-\(pgn.count)-\(moves.count)", platform: .chesscom, endedAt: Date(), color: me, opponent: "o", myRating: nil, opponentRating: nil,
                           result: .draw, timeClass: "blitz", timeControl: "180", pgn: pgn, url: nil)
    let records: [MoveRecord?] = line.plies.map { p in
      let (cls, b, a) = moves[p.index] ?? (.good, 0.5, 0.5)
      return MoveRecord(ply: p.index, san: p.san, uci: p.uci, mover: p.mover, cls: cls, winBefore: b, winAfter: a, accuracy: 80,
                        bestUci: p.uci, bestSan: p.san, altUci: nil, altSan: nil)
    }
    let evals: [[EngineLine]?] = (0...line.plies.count).map { _ in [EngineLine(cp: 0, pv: [])] }
    let analysis = AnalyzedGame(gameId: game.id, nodes: 1, evals: evals, records: records)
    let prepared = ReviewModel.Prepared(line: line, thinkTimes: Array(repeating: nil, count: line.plies.count),
                                       clockLeft: Array(repeating: nil, count: line.plies.count), analysis: analysis)
    return ReviewModel(game: game, prepared: prepared)
  }

  private let long = "1. e4 e5 2. Nf3 Nc6 3. Bc4 Bc5 4. c3 Nf6 5. d3 d6 6. O-O O-O 7. Re1 a6 8. a4 h6 9. Nbd2 Re8 10. h3 Be6 11. Bxe6 Rxe6 12. Nf1 d5 13. exd5 Nxd5 14. Ng3 Qd7 15. Bd2 Rd8 16. Qc2 Bb6 17. Rad1 f6"

  func testBothSidesStopAndDecidedPositionsDoNot() throws {
    let m = try model(long, moves: [4: (.blunder, 0.55, 0.2), 9: (.mistake, 0.6, 0.4), 15: (.blunder, 0.96, 0.92), 21: (.inaccuracy, 0.5, 0.42)])
    let plan = GameHighlight.plan(m)
    let stops = Set(plan.highlights.map(\.id)).union(plan.notices.keys)
    XCTAssertTrue(stops.contains(4), "你的嚴重失誤")
    XCTAssertTrue(stops.contains(9), "對手的失誤")
    XCTAssertFalse(stops.contains(15), "已經贏定的局面不停")
    XCTAssertFalse(stops.contains(21), "不精確、掉不到 15 個百分點不停")
    XCTAssertEqual(plan.notices[9]?.title, String(localized: "對手 \(try XCTUnwrap(m.line).plies[9].san)：\(MoveClass.mistake.zh)，你的機會來了"))
  }

  func testCapQuotaAndSkipped() throws {
    var moves: [Int: (MoveClass, Double, Double)] = [:]
    for (n, ply) in [0, 6, 12, 18, 24, 30].enumerated() { moves[ply] = (.mistake, 0.6, 0.6 - 0.16 - Double(n) * 0.01) }
    for (n, ply) in [3, 9, 15, 21, 27, 33].enumerated() { moves[ply] = (.blunder, 0.7, 0.7 - 0.4 - Double(n) * 0.01) }
    let plan = GameHighlight.plan(try model(long, moves: moves))
    let stops = Set(plan.highlights.map(\.id)).union(plan.notices.keys)
    XCTAssertEqual(stops.count, ReviewPlan.cap)
    XCTAssertGreaterThanOrEqual(stops.filter { $0 % 2 == 0 }.count, ReviewPlan.mineQuota, "至少一半給使用者")
    XCTAssertLessThanOrEqual(plan.highlights.filter(\.interactive).count, ReviewPlan.interactiveCap)
    XCTAssertEqual(plan.skipped.count, 12 - ReviewPlan.cap)
    XCTAssertTrue(Set(plan.skipped).isDisjoint(with: stops))
  }

  func testOpponentMissMergesIntoOneStop() throws {
    let m = try model(long, moves: [10: (.blunder, 0.5, 0.15), 11: (.miss, 0.85, 0.5)])
    let plan = GameHighlight.plan(m)
    let line = try XCTUnwrap(m.line)
    XCTAssertNil(plan.notices[10])
    XCTAssertEqual(plan.notices[11]?.title, String(localized: "對手 \(line.plies[11].san)：沒抓到你 \(line.plies[10].san) 的漏洞"))
    XCTAssertEqual(plan.notices[11]?.bestFrom, 11)
    XCTAssertTrue(plan.skipped.isEmpty)
  }

  func testPunishingMoveMergesWithOpponentMistake() throws {
    let m = try model(long, moves: [9: (.mistake, 0.6, 0.35), 10: (.best, 0.65, 0.65)])
    let plan = GameHighlight.plan(m)
    XCTAssertNil(plan.notices[9], "2 步內只留一個，優先使用者的步")
    let h = try XCTUnwrap(plan.highlights.first { $0.id == 10 })
    XCTAssertEqual(h.kind, .good)
  }

  func testDefendedThreatIsLowestPriorityPraise() throws {
    let m = try model(long, moves: [12: (.best, 0.5, 0.5)])
    let plan = GameHighlight.plan(m, defended: [12: "Bc5"])
    let h = try XCTUnwrap(plan.highlights.first { $0.id == 12 })
    XCTAssertFalse(h.interactive)
    XCTAssertEqual(h.studyTitle, String(localized: "你守住了：\(try XCTUnwrap(m.line).plies[12].san)"))
  }

  func testPlaybackStopsOnlyAtPlannedNoticesAndSlowsBefore() async throws {
    let m = try model("1. e4 e5 2. Nf3 Nc6 3. Bc4 Bc5", me: .black, moves: [2: (.inaccuracy, 0.5, 0.45), 3: (.blunder, 0.8, 0.2)])
    let plan = GameHighlight.plan(m)
    XCTAssertNotNil(plan.notices[3])
    let q = QuickReview(line: try XCTUnwrap(m.line), highlights: [], notices: plan.notices, skipped: plan.skipped, me: .black,
                        records: m.records, evals: m.evals, whiteWins: m.whiteWins, tags: [])
    let began = Date()
    q.start()
    for _ in 0..<60 where q.phase != .praise { try await Task.sleep(nanoseconds: 100_000_000) }
    XCTAssertEqual(q.phase, .praise)
    XCTAssertEqual(q.pos, 4)
    XCTAssertGreaterThan(Date().timeIntervalSince(began), 3 * 0.32 + 0.85, "停點前一步放慢")
    XCTAssertEqual(q.say.title, plan.notices[3]?.title)
    q.stop()
  }

  func testSmartDashesAndZeroCastlingParse() throws {
    XCTAssertEqual(ChessLine.sanTokens("1. e4 e5 2. Nf3 Nc6 3. Bc4 Nf6 4. O\u{2013}O Be7 5. d3 0-0"), ["e4", "e5", "Nf3", "Nc6", "Bc4", "Nf6", "O-O", "Be7", "d3", "O-O"])
    XCTAssertNotNil(ChessLine(pgn: "1. e4 e5 2. Nf3 Nc6 3. Bc4 Nf6 4. O\u{2014}O Be7 5. d3 0-0 1-0"))
  }

  func testPastedPGNWithoutResultIsReviewable() throws {
    let g = try XCTUnwrap(ImportedGames.parse("1. e4 e5 2. Nf3 Nc6", side: .white))
    XCTAssertEqual(g.termination, "unknown")
    let s = SingleGameHomeSummary.make(hasSources: false, games: [g], analyzed: [], indexReady: true, fresh: [], loading: false, failed: false)
    XCTAssertEqual(s.kind, .unreviewed)
  }
}
