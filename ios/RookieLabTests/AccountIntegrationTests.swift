import XCTest
@testable import RookieLab

/// 用真實帳號跑一遍：抓得到最近對局、每一局都解析得出走法、引擎算得出這一局第一個局面。
/// 要連網路。帳號用環境變數 TEST_ACCOUNT（例如 chesscom:rookielab-io），沒設就用 rookielab-io。
final class AccountIntegrationTests: XCTestCase {
  private var account: Account {
    let raw = ProcessInfo.processInfo.environment["TEST_ACCOUNT"] ?? "chesscom:rookielab-io"
    let parts = raw.split(separator: ":")
    return Account(platform: Platform(rawValue: String(parts.first ?? "chesscom")) ?? .chesscom, username: String(parts.last ?? "rookielab-io"))
  }

  func testRecentGamesParse() async throws {
    let games = try await GameSources.recentGames(account, limit: 20)
    XCTAssertFalse(games.isEmpty, "\(account.username) 抓不到對局")
    var bad: [String] = []
    for g in games {
      guard let line = ChessLine(pgn: g.pgn) else { bad.append("\(g.id)：整局解析不出"); continue }
      if let f = line.failedAt { bad.append("\(g.id)：第 \(line.plies.count + 1) 步 \(f) 解析不出") }
    }
    XCTAssertTrue(bad.isEmpty, "解析不出走法的對局：\(bad)")
    print("[test] \(account.username)：\(games.count) 局，最近一局 vs \(games[0].opponent)（\(games[0].result)）")
  }

  func testEngineOnFirstGame() async throws {
    let games = try await GameSources.recentGames(account, limit: 1)
    let line = try XCTUnwrap(ChessLine(pgn: games[0].pgn))
    let lines = await StockfishService.shared.analyse(fen: line.fen(at: 1))
    XCTAssertFalse(lines.isEmpty, "引擎沒有回結果")
    XCTAssertNotNil(lines.first?.best)
  }

  func testLichessThroughSiteProxy() async throws {
    let games = try await GameSources.recentGames(Account(platform: .lichess, username: "thibault"), limit: 3)
    XCTAssertFalse(games.isEmpty)
  }
}
