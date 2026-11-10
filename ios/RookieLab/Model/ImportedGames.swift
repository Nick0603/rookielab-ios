import Foundation

enum ImportedGames {
  private static let key = "imported-games.v1"
  static func load() -> [GameSummary] {
    guard let data = UserDefaults.standard.data(forKey: key) else { return [] }
    return (try? JSONDecoder().decode([GameSummary].self, from: data)) ?? []
  }
  static func save(_ games: [GameSummary]) { if let data = try? JSONEncoder().encode(games) { UserDefaults.standard.set(data, forKey: key) } }
  static func parse(_ text: String, side: Side) -> GameSummary? {
    guard let line = ChessLine(pgn: text), line.failedAt == nil, !line.plies.isEmpty else { return nil }
    func tag(_ name: String) -> String? {
      guard let range = text.range(of: "[\(name) \""), let end = text[range.upperBound...].firstIndex(of: "\"") else { return nil }
      return String(text[range.upperBound..<end])
    }
    var hash: UInt64 = 14695981039346656037
    for byte in (text.trimmingCharacters(in: .whitespacesAndNewlines) + side.rawValue).utf8 { hash = (hash ^ UInt64(byte)) &* 1099511628211 }
    let result = tag("Result") ?? "*"
    let won = result == (side == .white ? "1-0" : "0-1")
    let lost = result == (side == .white ? "0-1" : "1-0")
    return GameSummary(id: "pgn-" + String(hash, radix: 36), platform: .chesscom, endedAt: Date(), color: side,
      opponent: tag(side == .white ? "Black" : "White") ?? String(localized: "匯入對局"), myRating: nil, opponentRating: nil,
      result: won ? .win : lost ? .loss : .draw, timeClass: "imported", timeControl: tag("TimeControl") ?? "?", pgn: text, url: nil,
      // 貼上的棋譜常沒寫勝負：結果未知，但仍是要復盤的對局（不同於棋站上進行中的 unfinished）
      termination: ["1-0", "0-1", "1/2-1/2"].contains(result) ? nil : "unknown")
  }
}
