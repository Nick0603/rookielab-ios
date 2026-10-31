import Foundation

/// 關鍵步的說明：從引擎的線看出「為什麼」，而不是只說該走哪一步
enum Explain {
  static let pieceZh = ["p": "兵", "n": "馬", "b": "象", "r": "車", "q": "后", "k": "王"]

  private static func pieceOn(_ fen: String, _ sq: String) -> (side: Side, kind: String)? {
    guard let code = FEN.pieces(fen)[sq] else { return nil }
    return (code.first == "w" ? .white : .black, String(code.last!).lowercased())
  }

  private static func line(_ fen: String, _ pv: [String], _ n: Int) -> String {
    FEN.sanLine(fen: fen, pv: pv, max: n).joined(separator: " ")
  }

  static func text(_ r: MoveRecord, ply p: Ply, before: [EngineLine]?, after: [EngineLine]?) -> String? {
    let drop = -r.winDelta
    switch r.cls {
    case .brilliant:
      return "這步是棄子：看起來送掉了子，算下去卻是最好的一步。"
    case .great:
      return "這步把局面從劣勢救回來，而且是唯一的好棋。"
    case .inaccuracy, .mistake, .miss, .blunder:
      break
    default:
      return nil
    }
    let best = r.bestSan ?? "—"
    // 1. 走完之後對手有殺棋
    if let a = after?.first, let m = a.mate, m > 0 {
      return "走完之後，對手有 \(m) 步殺：\(line(p.fenAfter, a.pv, m * 2 - 1))。該走 \(best)。"
    }
    // 2. 本來有殺棋沒走
    if let b = before?.first, let m = b.mate, m > 0 {
      return "這裡有 \(m) 步殺：\(line(p.fenBefore, b.pv, m * 2 - 1))。"
    }
    // 3. 走完之後，對手可以吃掉你的子
    if let reply = after?.first?.best, reply.count >= 4,
       let target = pieceOn(p.fenAfter, String(reply.dropFirst(2).prefix(2))), target.side == p.mover {
      let lost = FEN.pieceValue[target.kind] ?? 0
      let gained = p.captured.map { FEN.pieceValue[$0] ?? 0 } ?? 0
      if lost >= 1, lost - gained >= 1, drop >= 8, let san = FEN.san(fen: p.fenAfter, uci: reply) {
        return "走完之後，對手可以 \(san) 吃掉你的\(pieceZh[target.kind] ?? "子")。該走 \(best)。"
      }
    }
    // 4. 有子可以吃沒吃
    if let b = before?.first?.best, b.count >= 4, b.prefix(4) != p.uci.prefix(4),
       let target = pieceOn(p.fenBefore, String(b.dropFirst(2).prefix(2))), target.side != p.mover,
       (FEN.pieceValue[target.kind] ?? 0) >= 3 {
      return "這裡可以 \(best) 吃掉對手的\(pieceZh[target.kind] ?? "子")。"
    }
    if r.cls == .miss {
      let follow = FEN.sanLine(fen: p.fenBefore, pv: before?.first?.pv ?? [], max: 5).dropFirst().joined(separator: " ")
      return "這裡有機會拉開優勢：該走 \(best)\(follow.isEmpty ? "" : "，接著 \(follow)")。"
    }
    let follow = FEN.sanLine(fen: p.fenBefore, pv: before?.first?.pv ?? [], max: 5).dropFirst().joined(separator: " ")
    return "這步讓局面變差了。該走 \(best)\(follow.isEmpty ? "" : "，接著大概是 \(follow)")。"
  }
}

/// 一條延伸棋局：從某個局面開始的幾步
struct LineOption: Identifiable, Hashable {
  enum Source: Hashable { case engine, database(games: Int, share: Int), manual }
  let id: String
  let title: String
  let source: Source
  let startFen: String
  /// 這條線從對局的第幾個局面開始（回到對局時用）
  let base: Int
  let plies: [Ply]
  var evalText: String?
  /// 每一步的白話說明（網站解說的變化才有）
  var captions: [String]? = nil
  /// 這條路走完的結論，例：「你丟了象，淨少 3 分」
  var outcome: String? = nil

  var preview: String { plies.prefix(6).map(\.san).joined(separator: " ") + (plies.count > 6 ? " …" : "") }
}

/// 延伸棋局：引擎的線 + 資料庫裡真人最常的接法（不全是最佳步，比較像真的會發生的）
enum Continuations {
  /// 引擎的線不到 n 步就接著算下去補長（每步用少量節點，夠看出走向就好）
  private static func engineLine(_ fen: String, pv: [String], length n: Int = 10, priority: StockfishService.Priority = .interactive) async -> [Ply] {
    var out = plies(fen, uci: Array(pv.prefix(n)))
    while out.count < n {
      let f = out.last?.fenAfter ?? fen
      if out.last?.isCheckmate == true { break }
      guard let next = await StockfishService.shared.analyse(fen: f, nodes: 40_000, priority: priority).first?.best,
            let p = ChessLine.ply(fen: f, uci: next, index: out.count) else { break }
      out.append(p)
    }
    return out
  }

  private static func plies(_ fen: String, uci: [String]) -> [Ply] {
    var out: [Ply] = []
    var f = fen
    for u in uci {
      guard let p = ChessLine.ply(fen: f, uci: u, index: out.count) else { break }
      out.append(p)
      f = p.fenAfter
    }
    return out
  }

  /// 從 fen 開始，先走 first，之後每一步都走資料庫裡最多人走的，直到局數太少
  private static func humanLine(_ fen: String, first: String, maxPlies: Int = 10, minGames: Int = 8) async -> [Ply] {
    guard var p = ChessLine.ply(fen: fen, uci: first, index: 0) else { return [] }
    var out = [p]
    while out.count < maxPlies {
      guard let r = await Explorer.fetch(fen: p.fenAfter, band: "all"), r.total >= minGames, let top = r.moves.first,
            let next = ChessLine.ply(fen: p.fenAfter, uci: top.uci, index: out.count) else { break }
      out.append(next)
      p = next
    }
    return out
  }

  @MainActor private static var cache: [String: [LineOption]] = [:]

  /// 算過的直接回（點開關鍵步不用再等）；key 用「對局 id-第幾手」
  @MainActor static func cached(_ key: String) -> [LineOption]? { cache[key] }

  @MainActor static func get(_ key: String, _ r: MoveRecord, ply p: Ply, before: [EngineLine]?, after: [EngineLine]?,
                             priority: StockfishService.Priority = .interactive) async -> [LineOption] {
    if let hit = cache[key] { return hit }
    let out = await build(r, ply: p, before: before, after: after, priority: priority)
    cache[key] = out
    return out
  }

  static func build(_ r: MoveRecord, ply p: Ply, before: [EngineLine]?, after: [EngineLine]?, priority: StockfishService.Priority = .interactive) async -> [LineOption] {
    var out: [LineOption] = []
    let k = p.index
    if let b = before?.first, let bs = r.bestSan, b.best?.prefix(4) != p.uci.prefix(4) {
      out.append(LineOption(id: "best", title: "如果走 \(bs)（該走的）", source: .engine, startFen: p.fenBefore, base: k, plies: await engineLine(p.fenBefore, pv: b.pv, priority: priority)))
    }
    if let before, let alt = Grading.secondChoice(before), let a = alt.best, a.prefix(4) != p.uci.prefix(4), let s = r.altSan {
      out.append(LineOption(id: "alt", title: "如果走 \(s)（也可以）", source: .engine, startFen: p.fenBefore, base: k, plies: await engineLine(p.fenBefore, pv: alt.pv, priority: priority)))
    }
    if let a = after?.first, !a.pv.isEmpty {
      out.append(LineOption(id: "punish", title: "你走 \(p.san) 之後：對手最好的應法", source: .engine, startFen: p.fenAfter, base: k + 1, plies: await engineLine(p.fenAfter, pv: a.pv, priority: priority)))
    }
    // 資料庫：這個局面之後，真人最常怎麼接
    if let db = await Explorer.fetch(fen: p.fenAfter, band: "all"), db.total >= 8 {
      let tops = Array(db.moves.prefix(3))
      let lines = await withTaskGroup(of: (Int, [Ply]).self) { g in
        for (i, m) in tops.enumerated() { g.addTask { (i, await humanLine(p.fenAfter, first: m.uci)) } }
        var res: [(Int, [Ply])] = []
        for await x in g { res.append(x) }
        return res.sorted { $0.0 < $1.0 }
      }
      for (i, line) in lines where !line.isEmpty {
        let m = tops[i]
        let share = m.games * 100 / max(db.total, 1)
        out.append(LineOption(id: "db\(i)", title: "大家常這樣接：\(m.san)", source: .database(games: m.games, share: share), startFen: p.fenAfter, base: k + 1, plies: line))
      }
    }
    // 該走的那步之後，真人常見的下法
    if let b = before?.first?.best, b.prefix(4) != p.uci.prefix(4), let bp = ChessLine.ply(fen: p.fenBefore, uci: b, index: 0),
       let db = await Explorer.fetch(fen: bp.fenAfter, band: "all"), db.total >= 8, let top = db.moves.first {
      let line = await humanLine(bp.fenAfter, first: top.uci, maxPlies: 9)
      if !line.isEmpty {
        out.append(LineOption(id: "dbBest", title: "走 \(bp.san) 之後，大家常見的下法", source: .database(games: db.total, share: top.games * 100 / max(db.total, 1)),
                              startFen: p.fenBefore, base: k, plies: [bp] + line.enumerated().map { i, x in x.reindexed(i + 1) }))
      }
    }
    // 每條線走完的局面評分（白方視角），讓使用者看出可能的結果
    for i in out.indices {
      let end = out[i].plies.last?.fenAfter ?? out[i].startFen
      let e = await StockfishService.shared.analyse(fen: end, nodes: 80_000, priority: priority)
      if let top = e.first {
        let s = FEN.sideToMove(end) == .white ? 1 : -1
        out[i].evalText = Grading.evalText(cp: top.cp.map { $0 * s }, mate: top.mate.map { $0 * s })
      }
    }
    return out
  }
}

extension LineOption {
  /// 網站解說的變化（你走的／該走的）→ 可以在棋盤上播的一條線，每一步帶說明
  init?(_ l: ExplainJS.Line, base: Int) {
    var plies: [Ply] = []
    var f = l.startFen
    for st in l.steps {
      let promo = st.san.range(of: "=[QRBN]", options: .regularExpression).map { String(st.san[$0].dropFirst()).lowercased() } ?? ""
      guard let p = ChessLine.ply(fen: f, uci: st.from + st.to + promo, index: plies.count) else { break }
      plies.append(p)
      f = p.fenAfter
    }
    guard !plies.isEmpty else { return nil }
    self.init(id: "js-\(l.kind)", title: l.title, source: .engine, startFen: l.startFen, base: base, plies: plies,
              captions: l.steps.prefix(plies.count).map { ExplainJS.plain($0.caption) }, outcome: l.plainOutcome)
  }
}

extension Ply {
  func reindexed(_ i: Int) -> Ply {
    Ply(index: i, san: san, uci: uci, from: from, to: to, mover: mover, moveNumber: moveNumber, fenBefore: fenBefore, fenAfter: fenAfter, captured: captured, isCheckmate: isCheckmate)
  }
}
