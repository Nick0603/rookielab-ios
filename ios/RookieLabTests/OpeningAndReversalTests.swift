import XCTest
@testable import RookieLab

final class OpeningAndReversalTests: XCTestCase {
  private func game(_ id: String, _ color: Side, _ result: GameResult, opening: String?, termination: String? = nil) -> GameSummary {
    let header = opening.map { "[ECOUrl \"https://www.chess.com/openings/\($0)\"]\n\n" } ?? ""
    return GameSummary(id: id, platform: .chesscom, endedAt: Date(), color: color, opponent: "o", myRating: nil, opponentRating: nil,
                       result: result, timeClass: "blitz", timeControl: "180", pgn: header + "1. e4 e5", url: nil, termination: termination)
  }

  func testOpeningRecordCountsSameFamilyAndColorExcludingCurrentGame() {
    let current = game("now", .white, .loss, opening: "Italian-Game-Two-Knights-Defense")
    let history = [
      current,
      game("a", .white, .win, opening: "Italian-Game-Two-Knights-Defense-Modern-Bishops-Opening"),
      game("b", .white, .draw, opening: "Italian-Game-Two-Knights-Defense"),
      game("c", .white, .loss, opening: "Italian-Game-Two-Knights-Defense"),
      game("d", .black, .win, opening: "Italian-Game-Two-Knights-Defense"),
      game("e", .white, .win, opening: "Ruy-Lopez-Opening"),
      game("f", .white, .win, opening: "Italian-Game-Two-Knights-Defense", termination: "unfinished"),
      game("g", .white, .win, opening: nil),
    ]
    let r = OpeningRecord.compute(for: current, raw: current.openingRaw, in: history)
    XCTAssertEqual(r, OpeningRecord(family: Openings.family(current.openingRaw), color: .white, games: 3, wins: 1, draws: 1, losses: 1))
    XCTAssertEqual(r.winRate, 33)
    XCTAssertTrue(r.summary.contains("33"))
    let first = OpeningRecord.compute(for: current, raw: current.openingRaw, in: [current])
    XCTAssertEqual(first.games, 0)
    XCTAssertEqual(first.summary, String(localized: "最近的對局裡，這是你第一次執白下「\(Openings.family(current.openingRaw))」。"))
  }

  func testFamilyGroupsVariationsInEveryLanguage() {
    XCTAssertEqual(Openings.family("Sicilian Defense Najdorf Variation"), Openings.family("Sicilian Defense"))
    XCTAssertEqual(Openings.family("Sicilian Defense: Najdorf Variation"), Openings.family("Sicilian Defense"))
    XCTAssertEqual(Openings.family("Italian Game Two Knights Defense"), Openings.family("Italian Game"))
    XCTAssertNotEqual(Openings.family("Ruy Lopez Opening"), Openings.family("Italian Game"))
  }

  func testReversalNeedsAClearSwingInEitherDirection() {
    let w: [Double?] = [0.5, 0.7, 0.2, 0.25, nil, 0.3, 0.8, 0.5]
    XCTAssertEqual(Swing.plies(whiteWins: w, me: .white), [1, 5])
    XCTAssertEqual(Swing.plies(whiteWins: w, me: .black), [1, 5])
    XCTAssertEqual(Swing.plies(whiteWins: [0.6, 0.3, 0.64, 0.36], me: .white), [])
    XCTAssertEqual(Swing.percent(0.72, me: .black), 28)
  }

  @MainActor func testOpeningStopTextUsesHistoryOnlyWhenAvailable() throws {
    let current = game("now", .black, .win, opening: "Sicilian-Defense")
    let stop = try XCTUnwrap(ReviewContent.openingStop(current, theory: [0: "x", 3: "Sicilian Defense"],
                                                    history: [game("a", .black, .win, opening: "Sicilian-Defense-Najdorf-Variation")]))
    XCTAssertEqual(stop.title, String(localized: "開局：\(Openings.name(current.openingRaw))"))
    let detail = try XCTUnwrap(stop.detail)
    XCTAssertTrue(detail.contains(String(localized: "到第 \(2) 手都是已收錄的理論走法。")))
    XCTAssertTrue(detail.contains(OpeningRecord(family: Openings.family(current.openingRaw), color: .black, games: 1, wins: 1, draws: 0, losses: 0).summary))
    let imported = game("pgn", .white, .draw, opening: nil)
    XCTAssertNil(ReviewContent.openingStop(imported, theory: [:], history: nil))
    let bookOnly = try XCTUnwrap(ReviewContent.openingStop(imported, theory: [4: "French Defense"], history: nil))
    XCTAssertEqual(bookOnly.detail, String(localized: "到第 \(3) 手都是已收錄的理論走法。"))
  }

  @MainActor private func model(_ pgn: String, cls: (Int) -> MoveClass = { _ in .best }, cp: (Int) -> Int = { _ in 0 }) throws -> (ReviewModel, [MoveRecord?], [[EngineLine]?]) {
    let line = try XCTUnwrap(ChessLine(pgn: pgn))
    let g = game("m", .white, .draw, opening: nil)
    let records: [MoveRecord?] = line.plies.map { p in
      MoveRecord(ply: p.index, san: p.san, uci: p.uci, mover: p.mover, cls: cls(p.index), winBefore: 0.5, winAfter: 0.5, accuracy: 100,
                 bestUci: p.uci, bestSan: p.san, altUci: nil, altSan: nil)
    }
    let evals: [[EngineLine]?] = (0...line.plies.count).map { [EngineLine(cp: cp($0), pv: [])] }
    let analysis = AnalyzedGame(gameId: g.id, nodes: 1, evals: evals, records: records)
    let prepared = ReviewModel.Prepared(line: line, thinkTimes: Array(repeating: nil, count: line.plies.count),
                                       clockLeft: Array(repeating: nil, count: line.plies.count), analysis: analysis)
    return (ReviewModel(game: g, prepared: prepared), records, evals)
  }

  @MainActor func testOpeningStopIsAddedAtTheLastBookMove() throws {
    let (m, _, _) = try model("1. e4 e5 2. Nf3 Nc6 3. Bc4 Bc5 4. c3 Nf6")
    let hs = GameHighlight.build(m, theory: [0: "a", 1: "b", 4: "Italian Game"], opening: (title: "開局：Italian", detail: "d"))
    let stop = try XCTUnwrap(hs.first { $0.studyTitle == "開局：Italian" })
    XCTAssertEqual(stop.id, 4)
    XCTAssertFalse(stop.interactive)
    XCTAssertEqual(stop.studyDetail, "d")
    XCTAssertFalse(hs.contains { $0.studyTitle == String(localized: "這局的開局理論") })
    // 沒有理論資料：停在第 4 手黑方走完（第 7 個半回合）
    XCTAssertEqual(GameHighlight.build(m, opening: (title: "t", detail: nil)).first { $0.studyTitle == "t" }?.id, 7)
  }

  @MainActor func testReversalStopsPlaybackAndShowsTheSwing() async throws {
    // index 3（黑方 2...Nc6）讓局勢從白方大優翻成黑方大優；使用者執黑
    let (m, records, evals) = try model("1. e4 e5 2. Nf3 Nc6 3. Bc4 Bc5")
    let w: [Double?] = [0.5, 0.5, 0.5, 0.8, 0.2, 0.2, 0.2]
    let notices = [3: ReviewNotice(ply: 3, title: String(localized: "你 \("Nc6")：局勢逆轉"), detail: String(localized: "你的勝率 \(20)% → \(80)%"), mood: "happy", bestFrom: nil)]
    let q = QuickReview(line: try XCTUnwrap(m.line), highlights: [], notices: notices, me: .black, records: records, evals: evals, whiteWins: w, tags: [])
    XCTAssertEqual(q.reversals, [3])
    q.start()
    for _ in 0..<60 where q.phase != .praise { try await Task.sleep(nanoseconds: 100_000_000) }
    XCTAssertEqual(q.phase, .praise)
    XCTAssertEqual(q.pos, 4)
    let say = q.say
    XCTAssertEqual(say.title, String(localized: "你 \("Nc6")：局勢逆轉"))
    XCTAssertTrue(say.detail?.contains(String(localized: "你的勝率 \(20)% → \(80)%")) ?? false)
    q.stop()
  }
}
