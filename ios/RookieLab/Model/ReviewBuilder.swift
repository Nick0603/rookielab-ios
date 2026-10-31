import Foundation

/// 被逆轉的局：曾經大優（勝率 75% 以上）卻沒贏，找出優勢掉最多的那一步，看是怎麼掉的
struct Reversal: Identifiable {
  enum Reason: String, CaseIterable {
    case endgame, timePressure, timeout, middlegame
    var zh: String {
      switch self {
      case .endgame: "殘局下錯"
      case .timePressure: "時間快不夠時下錯"
      case .timeout: "大優時超時"
      case .middlegame: "中局失誤"
      }
    }
    var tip: String {
      switch self {
      case .endgame: "殘局子少，一步錯就收不回來：先算對手的反擊，再推兵"
      case .timePressure: "領先時走簡單的步、換子，別把時間花光"
      case .timeout: "大優還輸，是時間沒分配好：領先之後每步給自己時間上限"
      case .middlegame: "優勢還沒收下來就鬆懈：每一步先看對手的威脅"
      }
    }
  }

  let game: GameSummary
  let record: MoveRecord
  let reason: Reason
  /// 最高曾經到多少（我方）
  let peak: Double
  /// 那一步時剩幾秒
  let clock: Double?
  var id: String { "\(game.id)-\(record.ply)" }
}

enum ReviewBuilder {
  /// 每一手走完剩幾秒（棋譜的 [%clk]）
  static func clocks(_ g: GameSummary) -> [Double?] { ChessLine.moveTokens(g.pgn).map(\.clock) }

  static func baseSeconds(_ g: GameSummary) -> Double? {
    g.timeControl.contains("/") ? nil : g.timeControl.split(separator: "+").first.flatMap { Double($0) }
  }

  /// 這一步是不是在時間快不夠的時候走的（剩不到起始時間的 10%，或不到 15 秒）
  static func lowTime(_ g: GameSummary, ply: Int, clocks: [Double?]) -> Bool {
    guard let base = baseSeconds(g), ply >= 2, let left = clocks[safe: ply - 2] ?? nil else { return false }
    return left < max(15, base * 0.1)
  }

  static func reversal(_ d: GameDigest) -> Reversal? {
    let g = d.game
    guard g.result != .win else { return nil }
    let mine = d.analysis.records.compactMap { $0 }.filter { $0.mover == g.color }
    guard let peak = mine.map(\.winAfter).max(), peak >= 0.75, let peakAt = mine.firstIndex(where: { $0.winAfter == peak }) else { return nil }
    let after = mine.dropFirst(peakAt + 1)
    let cl = clocks(g)
    guard let worst = after.max(by: { ($0.winBefore - $0.winAfter) < ($1.winBefore - $1.winAfter) }) else {
      // 大優之後沒有走壞的步：是超時或對手翻盤，看結束方式
      guard g.lostOnTime, let last = mine.last else { return nil }
      return Reversal(game: g, record: last, reason: .timeout, peak: peak, clock: nil)
    }
    let p = d.line.plies[worst.ply]
    let reason: Reversal.Reason =
      g.lostOnTime && worst.winBefore - worst.winAfter < 0.2 ? .timeout
      : Grading.phase(moveNumber: p.moveNumber, fen: p.fenBefore) == .endgame ? .endgame
      : lowTime(g, ply: worst.ply, clocks: cl) ? .timePressure
      : .middlegame
    return Reversal(game: g, record: worst, reason: reason, peak: peak, clock: cl[safe: worst.ply - 2] ?? nil)
  }

  /// 每局最多收幾題（一局失誤很多時只留最值得練的）
  static let perGame = 2

  /// 適合當練習題的「錯失的機會」：當時有勝勢（最佳步走下去勝率 60% 以上）、你走的讓勝率掉了 15% 以上、
  /// 而且最佳步明顯比第二好的步好（只有一個答案，才像一道題）。已經輸定的局面、到處都差不多的局面不收
  static func isOpportunity(_ r: MoveRecord, before: [EngineLine]) -> Bool {
    guard r.cls.isBad, r.winBefore >= 0.6, r.winBefore - r.winAfter >= 0.15 else { return false }
    return before.count < 2 || Difficulty.winGap(before, index: 1) >= 10
  }

  /// 一局裡我錯失的機會 → 複習卡（每局最多 perGame 題，掉最多的先）
  @MainActor static func cards(_ d: GameDigest) -> [ReviewCard] {
    let g = d.game
    let cl = clocks(g)
    let rev = reversal(d)?.record.ply
    let today = Day.number()
    let picked = d.analysis.records.compactMap { $0 }.filter { r in
      guard r.mover == g.color, let before = d.analysis.evals[safe: r.ply] ?? nil else { return false }
      return isOpportunity(r, before: before)
    }
    .sorted { ($0.winBefore - $0.winAfter) > ($1.winBefore - $1.winAfter) }.prefix(perGame)
    return picked.compactMap { r in
      guard let p = d.line.plies[safe: r.ply], let before = d.analysis.evals[r.ply] ?? nil, let best = before.first?.best else { return nil }
      let after = d.analysis.evals[safe: r.ply + 1] ?? nil
      let e = ExplainJS.explain(key: "\(g.id)-\(r.ply)", record: r, ply: p, before: before, after: after)
      var kinds: [ReviewCard.Kind] = []
      if Grading.phase(moveNumber: p.moveNumber, fen: p.fenBefore) == .endgame { kinds.append(.endgame) }
      if lowTime(g, ply: r.ply, clocks: cl) { kinds.append(.time) }
      if rev == r.ply { kinds.append(.reversal) }
      if let m = e?.motif, ["tactic", "hanging", "allowed_mate", "missed_mate", "missed_free", "missed_tactic", "missed_material", "ignored_threat", "bad_exchange"].contains(m) { kinds.append(.tactic) }
      if kinds.isEmpty { kinds.append(.other) }
      let accept = before.indices.filter { Difficulty.winGap(before, index: $0) <= 3 }.compactMap { before[$0].best }
      return ReviewCard(id: "\(g.platform.rawValue):\(g.id):\(r.ply)", gameId: g.id, platform: g.platform, opponent: g.opponent, date: g.endedAt,
                        ply: r.ply, moveNumber: p.moveNumber, fen: p.fenBefore, played: p.san, moves: [best], accept: accept,
                        kinds: kinds, headline: e?.headline ?? r.cls.zh,
                        why: e.map { ex in ex.lines.map { "\($0.title)：\($0.plainOutcome)" } + ex.plainReasons.prefix(1) }, due: today, v: 2)
    }
  }
}
