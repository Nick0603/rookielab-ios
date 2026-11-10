import XCTest
@testable import RookieLab

/// 每一步的名稱（快速復盤播放時講的）
final class MoveTagsTests: XCTestCase {
  private func tag(_ fen: String, _ uci: String) throws -> String {
    MoveTags.tag(try XCTUnwrap(ChessLine.ply(fen: fen, uci: uci, index: 0)), explanation: nil)
  }

  func testBasics() throws {
    XCTAssertEqual(try tag("r3k2r/8/8/8/8/8/8/R3K2R w KQkq - 0 1", "e1g1"), String(localized: "入堡（短）"))
    // 吃到沒人保護的后
    XCTAssertEqual(try tag("4k3/8/8/3q4/8/8/8/3QK3 w - - 0 1", "d1d5"), String(localized: "得子：吃\(Explain.pieceName("q"))"))
    // 后換后（對方吃得回來）
    XCTAssertEqual(try tag("3rk3/8/8/3q4/8/8/8/3QK3 w - - 0 1", "d1d5"), String(localized: "兌子"))
    // 馬被兵攻擊，走開
    XCTAssertEqual(try tag("4k3/8/8/8/2p5/3N4/8/4K3 w - - 0 1", "d3f4"), String(localized: "躲開攻擊：\(Explain.pieceName("n"))走開"))
    XCTAssertEqual(try tag("rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1", "g1f3"), String(localized: "出子"))
    XCTAssertEqual(try tag("4k3/8/8/8/8/8/8/R3K3 w - - 0 1", "a1a8"), String(localized: "將軍"))
  }

  @MainActor func testLongThinkIsOptionalAndAcceptsThePlayedMove() async throws {
    let pgn = "1. e4 e5 2. Nf3 Nc6 3. Bb5 a6 4. Ba4 Nf6 5. O-O Be7"
    let line = try XCTUnwrap(ChessLine(pgn: pgn))
    let game = GameSummary(id: "study-test", platform: .chesscom, endedAt: Date(), color: .white,
                           opponent: "Test", myRating: nil, opponentRating: nil, result: .draw,
                           timeClass: "rapid", timeControl: "600", pgn: pgn, url: nil)
    let records: [MoveRecord?] = line.plies.map { ply in
      MoveRecord(ply: ply.index, san: ply.san, uci: ply.uci, mover: ply.mover, cls: .best,
                 winBefore: 0.5, winAfter: 0.5, accuracy: 100, bestUci: ply.uci, bestSan: ply.san,
                 altUci: nil, altSan: nil)
    }
    let evals: [[EngineLine]?] = line.plies.map { [EngineLine(cp: 0, pv: [$0.uci])] } + [nil]
    let analysis = AnalyzedGame(gameId: game.id, nodes: 1, evals: evals, records: records)
    var times = Array<Double?>(repeating: 4, count: line.plies.count)
    times[6] = 38
    let prepared = ReviewModel.Prepared(line: line, thinkTimes: times,
                                       clockLeft: Array(repeating: nil, count: times.count), analysis: analysis)
    let model = ReviewModel(game: game, prepared: prepared)
    let highlights = GameHighlight.build(model)
    let study = try XCTUnwrap(highlights.first)
    XCTAssertEqual(study.id, 6)
    XCTAssertTrue(study.interactive)
    XCTAssertTrue(study.accept.contains(line.plies[6].uci))
    let quick = QuickReview(line: line, highlights: highlights, me: .white, records: records,
                            evals: evals, whiteWins: model.whiteWins, tags: [])
    quick.skipAhead()
    await Task.yield()
    XCTAssertEqual(quick.phase, .preview)
    XCTAssertTrue(quick.tried.isEmpty)
    quick.beginStudy()
    XCTAssertTrue(quick.canMove)
    quick.stop()
  }

  func testTheoryFollowsTheResultingPosition() throws {
    let main = try XCTUnwrap(ChessLine(pgn: "1. Nf3 d5 2. d4"))
    let transposed = try XCTUnwrap(ChessLine(pgn: "1. d4 d5 2. Nf3"))
    let a = try XCTUnwrap(main.plies.last)
    let b = try XCTUnwrap(transposed.plies.last)
    XCTAssertEqual(OpeningBook.key(a.fenAfter), OpeningBook.key(b.fenAfter))
    let italian = try XCTUnwrap(ChessLine(pgn: "1. e4 e5 2. Nf3 Nc6 3. Bc4"))
    XCTAssertNotNil(OpeningBook.shared.position(italian.fen(at: 5)))
  }

  /// 對手投降：chess.com 看棋譜的 Termination，Lichess 看 opponentEnd
  func testOpponentResigned() {
    func g(_ r: GameResult, _ pgn: String, end: String? = nil) -> GameSummary {
      GameSummary(id: "x", platform: .chesscom, endedAt: Date(), color: .white, opponent: "o", myRating: nil, opponentRating: nil, result: r,
                  timeClass: "blitz", timeControl: "180", pgn: pgn, url: nil, opponentEnd: end)
    }
    XCTAssertTrue(g(.win, "[Termination \"me won by resignation\"]\n1. e4 *").opponentResigned)
    XCTAssertFalse(g(.win, "[Termination \"me won by checkmate\"]\n1. e4 *").opponentResigned)
    XCTAssertTrue(g(.win, "1. e4 *", end: "resigned").opponentResigned)
    XCTAssertFalse(g(.loss, "[Termination \"o won by resignation\"]\n1. e4 *").opponentResigned)
  }
}

/// 熟悉度：有幫忙也算完成，但間隔拉長得慢、不會直接學會
@MainActor
final class RecallTests: XCTestCase {
  func testHelpedGrowsSlower() {
    let s = ReviewStore(persist: false)
    func c(_ id: String) -> ReviewCard {
      ReviewCard(id: id, gameId: "g", platform: .chesscom, opponent: "x", date: Date(), ply: 10, moveNumber: 6,
                 fen: "4k3/8/8/3q4/8/8/8/3QK3 w - - 0 1", played: "Ke2", moves: ["d1d5"], accept: nil, kinds: [.tactic], headline: "漏吃", due: Day.number())
    }
    s.add([c("a"), c("b")])
    for _ in 0..<3 { s.answer("a", recall: .clean); s.answer("b", recall: .helped) }
    let a = s.cards.first { $0.id == "a" }!, b = s.cards.first { $0.id == "b" }!
    XCTAssertTrue(a.mastered)
    XCTAssertFalse(b.mastered)
    XCTAssertLessThan(b.interval, a.interval)
  }
}
