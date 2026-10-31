import XCTest
@testable import RookieLab

final class PuzzleRegressionTests: XCTestCase {
  /// 白吃的子 JRGY3（使用者回報照答案走被判錯）：答案的每一步在棋盤上都要走得出來
  func testHangingJRGY3() throws {
    var fen = "2k5/pp5p/1p6/r5R1/6p1/2P2nP1/5PKP/4R3 w - - 5 27"
    for u in ["g5a5", "f3e1", "g2f1", "b6a5"] {
      let from = String(u.prefix(2)), to = String(u.dropFirst(2).prefix(2))
      XCTAssertTrue(FEN.targets(fen: fen, from: from).contains(to), u)
      let p = try XCTUnwrap(ChessLine.ply(fen: fen, uci: u, index: 0), u)
      XCTAssertEqual(p.uci, u)
      fen = p.fenAfter
    }
  }
}
