import XCTest
@testable import RookieLab

final class BoardAndTypeTests: XCTestCase {
  private func placed(_ fen: String) -> ([PlacedPiece], Int) {
    var id = 0
    return (PlacedPiece.diff([], to: FEN.pieces(fen), nextId: &id), id)
  }

  /// 入堡：王和車都是「滑過去」（id 不變），不是消失再出現
  func testCastlingKeepsIds() {
    let before = "r3k2r/8/8/8/8/8/8/R3K2R w KQkq - 0 1"
    var (old, id) = placed(before)
    let king = old.first { $0.code == "wK" }!.id, rook = old.first { $0.square == "h1" }!.id
    let after = ChessLine.ply(fen: before, uci: "e1g1", index: 0)!.fenAfter
    old = PlacedPiece.diff(old, to: FEN.pieces(after), nextId: &id)
    XCTAssertEqual(old.first { $0.square == "g1" }?.id, king)
    XCTAssertEqual(old.first { $0.square == "f1" }?.id, rook)
    XCTAssertEqual(id, 6, "沒有新出現的子")
  }

  /// 吃子：吃的那顆滑過去，被吃的消失；升變：兵變成后但還是同一顆
  func testCaptureAndPromotion() {
    let before = "8/1P6/7k/8/8/3q4/8/3RK3 w - - 0 1"
    var (old, id) = placed(before)
    let pawn = old.first { $0.code == "wP" }!.id
    let promo = ChessLine.ply(fen: before, uci: "b7b8q", index: 0)!
    old = PlacedPiece.diff(old, to: FEN.pieces(promo.fenAfter), nextId: &id)
    XCTAssertEqual(old.first { $0.square == "b8" }?.id, pawn)
    XCTAssertEqual(old.first { $0.square == "b8" }?.code, "wQ")
    let n = old.count
    let cap = ChessLine.ply(fen: promo.fenAfter, uci: "d3d1", index: 0)!
    let queen = old.first { $0.code == "bQ" }!.id
    old = PlacedPiece.diff(old, to: FEN.pieces(cap.fenAfter), nextId: &id)
    XCTAssertEqual(old.count, n - 1)
    XCTAssertEqual(old.first { $0.square == "d1" }?.id, queen)
  }

  /// 時間類型的名稱跟網站一樣
  func testGameTypeLabels() {
    XCTAssertEqual(GameType.label("rapid:600+0"), "10 分鐘快棋")
    XCTAssertEqual(GameType.label("blitz:180+2"), "3+2 閃電棋")
    XCTAssertEqual(GameType.label("blitz:180+0"), "3 分鐘閃電棋")
    XCTAssertEqual(GameType.label("bullet:30+0"), "30 秒子彈棋")
    XCTAssertEqual(GameType.short("blitz:180+2"), "3+2")
    XCTAssertEqual(GameType.label("daily"), "每日棋")
  }

  func testOpeningNames() {
    XCTAssertEqual(Openings.family("Sicilian Defense Najdorf Variation"), "西西里防禦")
    XCTAssertTrue(Openings.name("Italian Game Two Knights Defense").contains("義大利"))
  }
}
