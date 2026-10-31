import Foundation

/// 勝率、準確率、評級：數字與網站 src/lib/analysis/{winprob,accuracy,classification}.ts 一致
enum Grading {
  /// Lichess 公開的實證擬合公式：cp → 勝率
  static let k = 0.00368208

  static func winProb(cp: Int?, mate: Int?) -> Double {
    if let mate { return mate > 0 ? 1 : 0 }
    guard let cp else { return 0.5 }
    return 1 / (1 + exp(-k * Double(cp)))
  }

  static func winProb(_ line: EngineLine?) -> Double { winProb(cp: line?.cp, mate: line?.mate) }

  /// 單步準確率（Lichess 的公式）
  static func moveAccuracy(winDrop: Double) -> Double {
    let delta = max(0, winDrop) * 100
    return min(100, max(0, 103.1668 * exp(-0.04354 * delta) - 3.1669))
  }

  /// 整局準確率：算術平均與調和平均的折衷
  static func gameAccuracy(_ values: [Double]) -> Double {
    guard !values.isEmpty else { return 100 }
    let arithmetic = values.reduce(0, +) / Double(values.count)
    let harmonic = Double(values.count) / values.reduce(0) { $0 + 1 / max($1, 1) }
    return ((arithmetic + harmonic) / 2 * 10).rounded() / 10
  }

  private static let thresholds: [(Double, MoveClass)] = [
    (0.02, .excellent), (0.05, .good), (0.10, .inaccuracy), (0.20, .mistake),
  ]

  static func classify(winBefore: Double, winAfter: Double, isBest: Bool, hadWinningChance: Bool, isSacrifice: Bool) -> MoveClass {
    let loss = max(0, winBefore - winAfter)
    // 傑出：正確的棄子，棄完之後站得住，事前不能已經是勝勢
    if isSacrifice && isBest && winAfter >= 0.55 && winBefore < 0.7 { return .brilliant }
    // 好棋：把局面從劣勢救回來
    if isBest && loss <= 0.02 && winBefore < 0.5 && winAfter >= 0.5 { return .great }
    // 錯失良機：有機會取得勝勢卻沒抓住
    if hadWinningChance && loss > 0.10 { return .miss }
    if isBest { return .best }
    for (limit, cls) in thresholds where loss < limit { return cls }
    return .blunder
  }

  /// 也不錯的第二選擇：勝率比最佳步低不到 6 個百分點（最佳步是將殺時，第二步也要能將殺）
  static let altGap = 0.06
  static func secondChoice(_ lines: [EngineLine]) -> EngineLine? {
    guard lines.count >= 2, let b = lines[1].best else { return nil }
    let a = lines[0]
    if let m = a.mate, m > 0, !((lines[1].mate ?? 0) > 0) { return nil }
    return winProb(a) - winProb(lines[1]) <= altGap && b != a.best ? lines[1] : nil
  }

  /// 引擎評分的文字（白方視角）：+1.3、-0.4、M3
  static func evalText(cp: Int?, mate: Int?) -> String {
    if let mate { return mate < 0 ? "-M\(-mate)" : "M\(mate)" }
    let v = Double(cp ?? 0) / 100
    let s = abs(v) >= 10 ? String(format: "%.0f", abs(v)) : String(format: "%.1f", abs(v))
    return s == "0.0" ? "0.0" : "\(v > 0 ? "+" : "-")\(s)"
  }

  /// 一手棋的完整評級（單局復盤與跨局報告共用）：before／after 是走之前、走之後局面的引擎前兩名
  static func record(_ p: Ply, before: [EngineLine], after: [EngineLine]) -> MoveRecord? {
    guard let top = before.first else { return nil }
    let winBefore = winProb(top)
    let winAfter: Double = p.isCheckmate ? 1 : after.first.map { 1 - winProb($0) } ?? 0.5
    let isBest = top.best.map { $0.prefix(4) == p.uci.prefix(4) } ?? false
    let hadChance = winBefore >= 0.8 || (top.mate ?? 0) > 0
    // 棄子：走完之後，對手最好的那一步吃到的子比我這步吃到的多至少 3 分
    var sacrifice = false
    if let punish = after.first?.best, punish.count >= 4 {
      let target = FEN.pieces(p.fenAfter)[String(punish.dropFirst(2).prefix(2))]
      let lost = target.map { FEN.pieceValue[String($0.last!).lowercased()] ?? 0 } ?? 0
      let gained = p.captured.map { FEN.pieceValue[$0] ?? 0 } ?? 0
      // 對手吃了、我下一步在同一格吃回來：只是換子，不是棄子
      let recapture = after.first.map { $0.pv.count >= 2 && $0.pv[1].dropFirst(2).prefix(2) == punish.dropFirst(2).prefix(2) } ?? false
      // 還要是唯一的好步：第二名差 10% 以上
      let only = before.count < 2 || winProb(before[0]) - winProb(before[1]) >= 0.10
      sacrifice = lost - gained >= 3 && !recapture && only
    }
    let cls = p.isCheckmate ? MoveClass.best : classify(winBefore: winBefore, winAfter: winAfter, isBest: isBest, hadWinningChance: hadChance, isSacrifice: sacrifice)
    let alt = secondChoice(before)
    return MoveRecord(
      ply: p.index, san: p.san, uci: p.uci, mover: p.mover, cls: cls, winBefore: winBefore, winAfter: winAfter,
      accuracy: moveAccuracy(winDrop: winBefore - winAfter),
      bestUci: top.best, bestSan: top.best.flatMap { FEN.san(fen: p.fenBefore, uci: $0) },
      altUci: alt?.best, altSan: alt?.best.flatMap { FEN.san(fen: p.fenBefore, uci: $0) })
  }

  enum Phase: String, CaseIterable, Codable {
    case opening, middlegame, endgame
    var zh: String { self == .opening ? "開局" : self == .middlegame ? "中局" : "殘局" }
  }

  /// 跟網站 phaseOf 一樣：非兵子力 ≤ 16 是殘局，前 10 手是開局，其他是中局
  static func phase(moveNumber: Int, fen: String) -> Phase {
    let material = FEN.pieces(fen).values.reduce(0) { sum, code in
      let k = String(code.last!).lowercased()
      return k == "p" || k == "k" ? sum : sum + (FEN.pieceValue[k] ?? 0)
    }
    if material <= 16 { return .endgame }
    return moveNumber <= 10 ? .opening : .middlegame
  }
}
