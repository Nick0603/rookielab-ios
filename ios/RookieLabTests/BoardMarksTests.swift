import XCTest
@testable import RookieLab

@MainActor final class BoardMarksTests: XCTestCase {
  func testRelationsFindThePinFromJavaScript() async throws {
    let line = try XCTUnwrap(ChessLine(pgn: "1. d4 Nf6 2. c4 e6 3. Nc3 Bb4"))
    let boards = await ExplainJS.boards([line.plies[5]])
    let r = try XCTUnwrap(boards[5])
    XCTAssertTrue(r.pins.contains(BoardRelations.Pin(from: "b4", pinned: "c3", behind: "e1")), "\(r.pins)")
  }

  private func quick(_ notices: [Int: ReviewNotice], relations: [Int: BoardRelations]) throws -> QuickReview {
    let line = try XCTUnwrap(ChessLine(pgn: "1. d4 Nf6 2. c4 e6 3. Nc3 Bb4"))
    let evals: [[EngineLine]?] = (0...line.plies.count).map { _ in [EngineLine(cp: 0, pv: ["e2e3"])] }
    let records: [MoveRecord?] = line.plies.map { p in
      MoveRecord(ply: p.index, san: p.san, uci: p.uci, mover: p.mover, cls: p.index == 5 ? .mistake : .good, winBefore: 0.5, winAfter: p.index == 5 ? 0.2 : 0.5,
                 accuracy: 80, bestUci: nil, bestSan: nil, altUci: nil, altSan: nil)
    }
    return QuickReview(line: line, highlights: [], notices: notices, relations: relations, me: .white, records: records, evals: evals,
                       whiteWins: Array(repeating: 0.5, count: line.plies.count + 1), tags: [])
  }

  func testNoticeDrawsPlayedBestAndPinWithHangingSquare() async throws {
    var r = BoardRelations()
    r.pins = [.init(from: "b4", pinned: "c3", behind: "e1")]
    r.hanging = ["c4"]
    let q = try quick([5: ReviewNotice(ply: 5, title: "t", detail: nil, mood: "point", bestFrom: 6)], relations: [5: r])
    q.start()
    for _ in 0..<60 where q.phase != .praise { try await Task.sleep(nanoseconds: 100_000_000) }
    XCTAssertEqual(q.phase, .praise)
    let arrows = q.arrows
    XCTAssertLessThanOrEqual(arrows.count, 3)
    XCTAssertEqual(arrows.first, Arrow(from: "f8", to: "b4", color: QuickReview.played))
    XCTAssertTrue(arrows.contains(Arrow(from: "e2", to: "e3", color: Brand.bestArrow)), "你的機會：綠色最佳步")
    XCTAssertTrue(arrows.contains(Arrow(from: "b4", to: "e1", color: QuickReview.threat)), "牽制畫整條")
    XCTAssertEqual(q.marks, [SquareMark(square: "c4", color: QuickReview.threat)])
    q.stop()
  }

  func testNothingIsDrawnBeforeAnInteractiveAnswer() throws {
    let q = try quick([:], relations: [5: BoardRelations(hanging: ["c4"])])
    XCTAssertTrue(q.arrows.isEmpty)
    XCTAssertTrue(q.marks.isEmpty)
  }
}

@MainActor final class OpeningObservationTests: XCTestCase {
  func testBlockingACheckIsNotAnOpeningMistake() async throws {
    let trap = try XCTUnwrap(ChessLine(pgn: "1. e4 e5 2. Nf3 Nc6 3. Bc4 Nd4 4. Nxe5 Qg5 5. Nxf7 Qxg2 6. Rf1 Qxe4+ 7. Be2 Nf3#"))
    let note = await ExplainJS.openingObservation(trap, me: .white)
    XCTAssertFalse(note?.contains("e2") ?? false, note ?? "nil")
  }

  func testEarlyQueenNeedsToBeChasedAndFallsBackToOpponent() async throws {
    // 白方第 2 手就出后，之後被 Nf6、Nd4 趕了兩次 → 有證據
    let chased = try XCTUnwrap(ChessLine(pgn: "1. e4 e5 2. Qh5 Nc6 3. Bc4 g6 4. Qf3 Nf6 5. Ne2 Nd4 6. Qd3"))
    let mine = await ExplainJS.openingObservation(chased, me: .white)
    XCTAssertNotNil(mine)
    let own = await ExplainJS.openingObservation(chased, me: .black)
    XCTAssertEqual(own?.hasPrefix(String(localized: "對手 · \("")")), false, "黑方自己有同子兩動，先講自己的")
    // 黑方正常出子、入堡；白方早出后又被趕 → 改講對手
    let clean = try XCTUnwrap(ChessLine(pgn: "1. e4 e5 2. Qh5 Nc6 3. Bc4 Nf6 4. Qf3 Bc5 5. Qg3 O-O"))
    let theirs = await ExplainJS.openingObservation(clean, me: .black)
    XCTAssertEqual(theirs?.hasPrefix(String(localized: "對手 · \("")")), true, theirs ?? "nil")
  }
}
