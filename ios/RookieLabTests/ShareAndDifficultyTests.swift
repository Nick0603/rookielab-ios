import XCTest
@testable import RookieLab

final class ShareAndDifficultyTests: XCTestCase {
  func testLinkPatterns() {
    XCTAssertEqual(GameLink.find(in: "看看我這局 https://www.chess.com/game/live/185904656512?move=10 好難"), "https://www.chess.com/game/live/185904656512?move=10")
    XCTAssertNotNil(GameLink.find(in: "https://www.chess.com/game/daily/123456"))
    XCTAssertNotNil(GameLink.find(in: "https://www.chess.com/analysis/game/live/185904656512"))
    XCTAssertEqual(GameLink.find(in: "https://lichess.org/q7ZvsdUF/black"), "https://lichess.org/q7ZvsdUF/black")
    XCTAssertNil(GameLink.find(in: "https://www.chess.com/home"))
    XCTAssertEqual(GameLink.find(in: "https://lichess.org/game/GAzHz3N6/black"), "https://lichess.org/game/GAzHz3N6/black")
    XCTAssertNotNil(GameLink.find(in: "https://lichess.org/GAzHz3N6abcd"))
    XCTAssertNil(GameLink.find(in: "https://lichess.org/training/daily"))
    XCTAssertNil(GameLink.find(in: "https://lichess.org/analysis"))
  }

  /// 第一步就吃到沒人保護的后：一眼就有
  func testDifficultyGlance() {
    let fen = "4k3/8/8/3q4/8/8/8/3QK3 w - - 0 1"
    XCTAssertEqual(Difficulty.level(fen: fen, pv: ["d1d5"]), .glance)
    XCTAssertEqual(Difficulty.level(fen: "4k3/8/8/8/8/8/8/4K3 w - - 0 1", pv: ["e1e2", "e8e7"]), .positional)
  }

  /// 真的分享一局 chess.com 的連結：認得出雙方，能用 rookielab-io 的角度拿到這局（要連網路）
  func testSharedChesscomGame() async throws {
    let s = try await GameSources.shared("https://www.chess.com/game/live/185904656512")
    XCTAssertEqual(s.platform, .chesscom)
    XCTAssertTrue([s.white, s.black].map { $0.lowercased() }.contains("rookielab-io"))
    let g = try await s.fetch("rookielab-io")
    XCTAssertTrue(g.url?.absoluteString.hasSuffix("185904656512") ?? false)
    XCTAssertNotNil(ChessLine(pgn: g.pgn))
  }

  /// 用戶回報的連結：/game/ 格式，帶 /black，要認出黑方是分享的人
  func testSharedLichessGameWithColor() async throws {
    let s = try await GameSources.shared("https://lichess.org/game/GAzHz3N6/black")
    XCTAssertEqual(s.hint, .black)
    XCTAssertEqual(s.black.lowercased(), "nick_chen_030")
    let g = try await s.fetch(s.black)
    XCTAssertEqual(g.color, .black)
    XCTAssertEqual(g.opponent, s.white)
  }

  func testSharedLichessGame() async throws {
    let s = try await GameSources.shared("https://lichess.org/q7ZvsdUF/black")
    XCTAssertEqual(s.platform, .lichess)
    let g = try await s.fetch(s.black)
    XCTAssertEqual(g.color, .black)
    XCTAssertNotNil(ChessLine(pgn: g.pgn))
  }
}
