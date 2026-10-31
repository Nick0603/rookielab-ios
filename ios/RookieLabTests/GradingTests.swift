import XCTest
@testable import RookieLab

/// 評級規則要跟網站（src/lib/analysis/classification.ts）一致
final class GradingTests: XCTestCase {
  func testWinProbability() {
    XCTAssertEqual(Grading.winProb(cp: 0, mate: nil), 0.5, accuracy: 0.0001)
    XCTAssertGreaterThan(Grading.winProb(cp: 300, mate: nil), 0.74)
    XCTAssertEqual(Grading.winProb(cp: nil, mate: 3), 1)
    XCTAssertEqual(Grading.winProb(cp: nil, mate: -2), 0)
  }

  func testThresholds() {
    func cls(_ drop: Double) -> MoveClass { Grading.classify(winBefore: 0.6, winAfter: 0.6 - drop, isBest: false, hadWinningChance: false, isSacrifice: false) }
    XCTAssertEqual(cls(0.01), .excellent)
    XCTAssertEqual(cls(0.04), .good)
    XCTAssertEqual(cls(0.08), .inaccuracy)
    XCTAssertEqual(cls(0.15), .mistake)
    XCTAssertEqual(cls(0.30), .blunder)
    XCTAssertEqual(Grading.classify(winBefore: 0.9, winAfter: 0.6, isBest: false, hadWinningChance: true, isSacrifice: false), .miss)
    XCTAssertEqual(Grading.classify(winBefore: 0.45, winAfter: 0.55, isBest: true, hadWinningChance: false, isSacrifice: false), .great)
    XCTAssertEqual(Grading.classify(winBefore: 0.6, winAfter: 0.6, isBest: true, hadWinningChance: false, isSacrifice: true), .brilliant)
  }

  func testSecondChoice() {
    let close = [EngineLine(cp: 40, mate: nil, pv: ["e2e4"]), EngineLine(cp: 30, mate: nil, pv: ["d2d4"])]
    XCTAssertEqual(Grading.secondChoice(close)?.best, "d2d4")
    let far = [EngineLine(cp: 300, mate: nil, pv: ["e2e4"]), EngineLine(cp: -50, mate: nil, pv: ["a2a3"])]
    XCTAssertNil(Grading.secondChoice(far))
    let mate = [EngineLine(cp: nil, mate: 2, pv: ["h5f7"]), EngineLine(cp: 900, mate: nil, pv: ["d1d2"])]
    XCTAssertNil(Grading.secondChoice(mate), "最佳步是將殺時，不能殺的第二步不算也可以")
  }

  func testAccuracy() {
    XCTAssertEqual(Grading.moveAccuracy(winDrop: 0), 100, accuracy: 0.01)
    XCTAssertLessThan(Grading.moveAccuracy(winDrop: 0.3), 30)
    XCTAssertEqual(Grading.gameAccuracy([]), 100)
  }

  func testPgnParsing() throws {
    let pgn = """
    [Event "Live Chess"]
    [White "a"]
    [Black "b"]
    [Result "1-0"]

    1. e4 {[%clk 0:09:58]} e5 {[%clk 0:09:57]} 2. Bc4 Nc6 3. Qh5 Nf6 4. Qxf7# 1-0
    """
    let line = try XCTUnwrap(ChessLine(pgn: pgn))
    XCTAssertEqual(line.plies.count, 7)
    XCTAssertEqual(line.plies[0].uci, "e2e4")
    XCTAssertEqual(line.plies[6].san, "Qxf7#")
    XCTAssertTrue(line.plies[6].isCheckmate)
    XCTAssertEqual(line.plies[6].captured, "p")
    XCTAssertEqual(FEN.san(fen: line.startFen, uci: "g1f3"), "Nf3")
  }

  /// 有標明起點的走法要動對的那顆子（ChessKit 內建解析器會挑錯）
  func testDisambiguation() throws {
    let pgn = "1. e3 e5 2. d4 exd4 3. Qxd4 Nc6 4. Qe4+ Qe7 5. Qxe7+ Ngxe7 6. Nf3 *"
    let line = try XCTUnwrap(ChessLine(pgn: pgn))
    XCTAssertNil(line.failedAt)
    XCTAssertEqual(line.plies[9].from, "g8")
    XCTAssertEqual(line.plies.count, 11)
  }

  /// 引擎速度：印出不同節點數各要多久（看要用多少節點）
  func testEngineSpeed() async throws {
    let fen = "r1bqkb1r/pppp1ppp/2n2n2/4p3/2B1P3/5N2/PPPP1PPP/RNBQK2R w KQkq - 4 4"
    _ = await StockfishService.shared.analyse(fen: "rnbqkbnr/pppppppp/8/8/4P3/8/PPPP1PPP/RNBQKBNR b KQkq - 0 1", nodes: 1000)
    var report = ""
    defer {
      let out = ProcessInfo.processInfo.environment["SPEED_REPORT"] ?? NSTemporaryDirectory() + "engine-speed.txt"
      try? report.write(toFile: out, atomically: true, encoding: .utf8)
    }
    for n in [100_000, 300_000, 1_000_000] {
      let t = Date()
      let r = await StockfishService.shared.analyse(fen: fen, nodes: n)
      report += "nodes=\(n) \(String(format: "%.2f", Date().timeIntervalSince(t)))s best=\(r.first?.best ?? "-")\n"
    }
  }

  /// 每一手想了幾秒：同一方上一手剩的時間 − 這一手剩的 + 加秒
  func testThinkTimes() {
    let pgn = "1. b3 {[%clk 0:03:00.8]} 1... e5 {[%clk 0:02:59.9]} 2. Bb2 {[%clk 0:03:02.1]} 2... Nc6 {[%clk 0:03:00]} 3. e4 {[%clk 0:03:03.3]} 3... Nf6 {[%clk 0:02:51.5]} *"
    let t = ChessLine.thinkTimes(pgn: pgn, timeControl: "180+2").map { $0 ?? -1 }
    XCTAssertEqual(t.count, 6)
    XCTAssertEqual(t[0], 1.2, accuracy: 0.01)
    XCTAssertEqual(t[1], 2.1, accuracy: 0.01)
    XCTAssertEqual(t[2], 0.7, accuracy: 0.01)
    XCTAssertEqual(t[5], 10.5, accuracy: 0.01)
    XCTAssertTrue(ChessLine.thinkTimes(pgn: pgn, timeControl: "1/86400").allSatisfy { $0 == nil }, "每日棋不算")
    XCTAssertEqual(ChessLine.sanTokens(pgn), ["b3", "e5", "Bb2", "Nc6", "e4", "Nf6"])
  }
}
