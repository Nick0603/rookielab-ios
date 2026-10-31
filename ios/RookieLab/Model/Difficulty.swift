import Foundation

/// 一步棋好不好找，規則與網站 src/lib/analysis/{findability,difficulty}.ts 一致：
/// 照引擎的變化走，看第幾步才真的得子／將殺（好找度），再看是不是吃子將軍、有幾步一樣好、是不是唯一一步
enum Difficulty {
  enum Level: Int { case glance = 1, combo, deep, positional
    var zh: String {
      switch self {
      case .glance: "一眼就有"
      case .combo: "兩步組合"
      case .deep: "要連算三步以上"
      case .positional: "局面判斷"
      }
    }
  }

  enum Grade {
    case easy, fit, hard, veryHard
    var zh: String {
      switch self {
      case .easy: "簡單"
      case .fit: "剛好"
      case .hard: "有點難"
      case .veryHard: "很難"
      }
    }
  }

  struct Result {
    let level: Level
    /// 0–100，越高越好找
    let score: Int
    /// 大約幾分（rapid）的玩家找得到
    var needRating: Int { Int(((2200 - Double(score) * 18) / 50).rounded()) * 50 }

    /// 跟使用者的分數比：低 150 以上簡單、高 100 內剛好、高 350 內有點難、再上去很難；沒有分數就看參考分數
    func grade(for rating: Int?) -> Grade {
      guard let rating else { return score >= 70 ? .easy : score >= 50 ? .fit : score >= 30 ? .hard : .veryHard }
      let d = needRating - rating
      return d <= -150 ? .easy : d <= 100 ? .fit : d <= 350 ? .hard : .veryHard
    }
  }

  /// 好找度：照 pv 走，我方淨得 2 分以上（對手吃不回來）或將殺時，是我方的第幾步
  static func level(fen: String, pv: [String]) -> Level {
    guard let first = fen.split(separator: " ").dropFirst().first else { return .positional }
    let me: Side = first == "w" ? .white : .black
    var f = fen
    var net = 0, mine = 0
    for u in pv.prefix(10) {
      guard let p = ChessLine.ply(fen: f, uci: u, index: 0) else { break }
      let gain = (p.captured.map { FEN.pieceValue[$0] ?? 0 } ?? 0) + (u.count == 5 ? (FEN.pieceValue[String(u.last!)] ?? 0) - 1 : 0)
      f = p.fenAfter
      if p.mover == me {
        mine += 1
        net += gain
        if p.isCheckmate { return Level(rawValue: min(mine, 3))! }
        if net >= 2, p.captured != nil, !attacked(f, square: p.to) { return Level(rawValue: min(mine, 3))! }
      } else {
        net -= gain
        if net >= 2 { return Level(rawValue: min(mine, 3))! }
      }
    }
    return .positional
  }

  /// 輪到走的一方能不能吃到這一格
  private static func attacked(_ fen: String, square: String) -> Bool {
    let side = FEN.sideToMove(fen)
    for (sq, code) in FEN.pieces(fen) where (code.first == "w") == (side == .white) {
      if FEN.targets(fen: fen, from: sq).contains(square) { return true }
    }
    return false
  }

  /// lines：這個局面引擎的前幾名（走棋方視角，第一名是最佳）；index 是要評的那一條
  static func of(fen: String, lines: [EngineLine], index: Int = 0) -> Result? {
    guard index < lines.count, let move = lines[index].best else { return nil }
    let lv = level(fen: fen, pv: lines[index].pv)
    let base: [Level: Int] = [.glance: 85, .combo: 65, .deep: 40, .positional: 55]
    var s = base[lv]!
    // 吃子、將軍這種一眼看得到的步比較好找
    if let p = ChessLine.ply(fen: fen, uci: move, index: 0), p.captured != nil || p.san.contains("+") { s += 10 }
    let cp = { (l: EngineLine) -> Int in l.mate.map { $0 > 0 ? 10_000 - $0 : -10_000 - $0 } ?? l.cp ?? 0 }
    let top = cp(lines[0])
    let good = lines.filter { top - cp($0) <= 50 }.count
    if good >= 3 { s += 15 } else if good == 2 { s += 5 }
    if lines.count >= 2, top - cp(lines[1]) >= 150 { s -= 20 }
    return Result(level: lv, score: max(5, min(95, s)))
  }

  /// 跟最佳步比，這一條讓勝率少多少（百分點，走棋方視角，0 表示一樣好）
  static func winGap(_ lines: [EngineLine], index: Int) -> Int {
    guard index < lines.count, let top = lines.first else { return 0 }
    return Int(((Grading.winProb(top) - Grading.winProb(lines[index])) * 100).rounded())
  }
}

extension MoveRecord {
  /// 這一步讓勝率變了多少（百分點，走的那一方視角）：期望值的變化，比「53% → 35%」好讀
  var winDelta: Int { Int(((winAfter - winBefore) * 100).rounded()) }
  var winDeltaText: String { winDelta == 0 ? "勝率不變" : "勝率 \(winDelta > 0 ? "+" : "−")\(abs(winDelta))%" }
}
