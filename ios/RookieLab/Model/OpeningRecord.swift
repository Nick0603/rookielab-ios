import Foundation

/// 快速復盤開局停點：這局的開局名稱，以及使用者最近用同一色下同一開局家族的戰績
struct OpeningRecord: Equatable {
  let family: String
  let color: Side
  let games: Int
  let wins: Int
  let draws: Int
  let losses: Int
  var winRate: Int { games == 0 ? 0 : Int((Double(wins) / Double(games) * 100).rounded()) }

  /// 不含這一局本身；未完成的對局不算
  static func compute(for game: GameSummary, raw: String?, in history: [GameSummary]) -> OpeningRecord {
    let family = Openings.family(raw)
    let same = history.filter {
      $0.id != game.id && $0.color == game.color && $0.termination != "unfinished" && $0.termination != "unknown" && $0.openingRaw != nil && Openings.family($0.openingRaw) == family
    }
    return OpeningRecord(family: family, color: game.color, games: same.count,
                         wins: same.filter { $0.result == .win }.count,
                         draws: same.filter { $0.result == .draw }.count,
                         losses: same.filter { $0.result == .loss }.count)
  }

  /// 這局所屬棋站帳號的最近對局（匯入的 PGN 沒有帳號，回傳 nil）
  static func history(for game: GameSummary) -> [GameSummary]? {
    for a in AccountStore.all() where a.platform == game.platform {
      if let games = GameCache.load(a), games.contains(where: { $0.id == game.id }) { return games }
    }
    return nil
  }

  var summary: String {
    if games == 0 {
      return color == .white ? String(localized: "最近的對局裡，這是你第一次執白下「\(family)」。")
        : String(localized: "最近的對局裡，這是你第一次執黑下「\(family)」。")
    }
    return color == .white
      ? String(localized: "你最近執白下「\(family)」\(games) 局：\(wins) 勝 \(draws) 和 \(losses) 負，勝率 \(winRate)%。")
      : String(localized: "你最近執黑下「\(family)」\(games) 局：\(wins) 勝 \(draws) 和 \(losses) 負，勝率 \(winRate)%。")
  }
}

/// 局勢逆轉：一步棋讓你的勝率從明顯優勢翻成明顯劣勢（或反過來）
enum Swing {
  static let high = 0.65, low = 0.35

  /// whiteWins[k] 是第 k 個局面（走完 k 步）白方的勝率；回傳造成逆轉的那一步（ply index）
  static func plies(whiteWins: [Double?], me: Side) -> Set<Int> {
    var out: Set<Int> = []
    guard whiteWins.count > 1 else { return out }
    for i in 0..<(whiteWins.count - 1) {
      guard let b = whiteWins[i], let a = whiteWins[i + 1] else { continue }
      let before = me == .white ? b : 1 - b, after = me == .white ? a : 1 - a
      if (before >= high && after <= low) || (before <= low && after >= high) { out.insert(i) }
    }
    return out
  }

  static func percent(_ whiteWin: Double, me: Side) -> Int { Int(((me == .white ? whiteWin : 1 - whiteWin) * 100).rounded()) }
}
