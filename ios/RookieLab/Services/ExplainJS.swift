import Foundation
import JavaScriptCore

/// 關鍵步解說：直接跑網站的 explainMove（src/lib/lesson/explain.ts 打包成 Resources/explain.js），
/// 兩邊的說法一致（捉雙、牽制、串打、送子、漏看威脅…），網站改了 App 重新打包就跟上
@MainActor
enum ExplainJS {
  struct Step: Decodable, Hashable {
    let san: String
    let from: String
    let to: String
    let fen: String
    let mine: Bool
    let caption: String
  }

  struct Line: Decodable, Hashable {
    let kind: String
    let title: String
    let startFen: String
    let steps: [Step]
    let outcome: String
    let note: String?
    let net: Int
    var plainOutcome: String { ExplainJS.plain(outcome) + (note.map { String(localized: "（\(ExplainJS.plain($0))）") } ?? "") }
  }

  struct Explanation: Decodable {
    let motif: String
    let headline: String
    let reasons: [String]
    let lines: [Line]
    /// 給使用者看的理由：拿掉「評分 +2.7 → -4.4」這行，其他句子裡的評分換成「均勢、小優」這種說法
    var plainReasons: [String] { reasons.filter { !$0.hasPrefix("評分") && !$0.hasPrefix("Score ") }.map(ExplainJS.plain) }
  }

  /// 「評分從 -0.4 掉到 -1.6」→「局面從均勢變成小劣」。網站解說裡的評分是走這步那一方的視角
  /// 中文走中文句型；其他語言目前 JS 回英文，走英文句型（es、pt 的解說上線後，找不到句型就保持原句）
  nonisolated static func plain(_ text: String) -> String {
    func word(_ v: String) -> String {
      if v.contains("M") { return AppLang.isZh ? (v.hasPrefix("-") ? "被將殺" : "可以將殺") : (v.hasPrefix("-") ? "getting mated" : "mate in sight") }
      guard let x = Double(v) else { return v }
      let win = Grading.winProb(cp: Int(x * 100), mate: nil)
      return AppLang.isZh ? Grading.standing(win) : Grading.standingEnglish(win)
    }
    let num = #"([+-]?M?\d*(?:\.\d+)?)"#
    var out = text
    let rules: [(String, ([String]) -> String)]
    if AppLang.isZh {
      rules = [
        ("評分從 \(num) 掉到 \(num)", { m in word(m[0]) == word(m[1]) ? "局面還是\(word(m[0]))，但變差了" : "局面從\(word(m[0]))變成\(word(m[1]))" }),
        ("評分從 \(num) 升到 \(num)", { m in "局面從\(word(m[0]))變成\(word(m[1]))" }),
        ("評分維持在 \(num)", { m in "局面維持\(word(m[0]))" }),
        ("掉到 \(num)", { m in "變成\(word(m[0]))" }),
        ("評分 \(num)", { m in word(m[0]) }),
      ]
    } else {
      rules = [
        ("the score drops from \(num) to \(num)", { m in word(m[0]) == word(m[1]) ? "the position is still \(word(m[0])), but worse" : "the position goes from \(word(m[0])) to \(word(m[1]))" }),
        ("the score stays at \(num)", { m in "the position stays \(word(m[0]))" }),
        ("the score drops to \(num)", { m in "the position becomes \(word(m[0]))" }),
        ("your move drops it to \(num)", { m in "your move makes it \(word(m[0]))" }),
        ("\\(score \(num)\\)", { m in "(\(word(m[0])))" }),
      ]
    }
    for (pattern, make) in rules {
      guard let re = try? NSRegularExpression(pattern: pattern) else { continue }
      for m in re.matches(in: out, range: NSRange(out.startIndex..., in: out)).reversed() {
        let groups = (1..<m.numberOfRanges).compactMap { Range(m.range(at: $0), in: out).map { String(out[$0]) } }
        guard let r = Range(m.range, in: out) else { continue }
        out.replaceSubrange(r, with: make(groups))
      }
    }
    return out
  }

  /// 解說引擎在自己的執行緒上跑（一次幾十到幾百毫秒），主執行緒只負責畫面：載入動畫、換卡才不會卡
  private static let queue = DispatchQueue(label: "rookielab.explain-js", qos: .userInitiated)
  /// 棋盤標示與解說共用同一個 JSContext，所以用同一個執行緒
  static var boardQueue: DispatchQueue { queue }
  nonisolated(unsafe) static var contextForBoard: JSContext? { context }

  nonisolated(unsafe) private static let context: JSContext? = {
    guard let url = Bundle.main.url(forResource: "explain", withExtension: "js"), let src = try? String(contentsOf: url, encoding: .utf8),
          let ctx = JSContext() else { return nil }
    ctx.exceptionHandler = { _, e in
      #if DEBUG
      print("[explain.js]", e?.toString() ?? "")
      #endif
    }
    ctx.evaluateScript(src)
    return ctx
  }()

  private static var cache: [String: Explanation] = [:]
  struct Eval: Encodable { var cp: Int?; var mate: Int? }
  /// 網站的 MoveRecord（我方＝走這步的一方）
  struct WebRecord: Encodable {
    let ply: Int, moveNumber: Int, san: String, cls: String
    let winBefore: Double, winAfter: Double, accuracy: Double
    let best: String?, punishedBy: String?
    let line: [String], bestLine: [String]?
    let evalBefore: Eval?, evalAfter: Eval?
  }

  /// 我們的分析結果 → 網站的 MoveRecord。oneBased：網站的 ply 從 1 算（跨局彙整用）
  nonisolated static func webRecord(_ r: MoveRecord, ply p: Ply, before: [EngineLine]?, after: [EngineLine]?, oneBased: Bool = false) -> WebRecord {
    // 引擎評分換成白方視角（網站的 evalBefore／evalAfter）
    func white(_ l: EngineLine?, fen: String) -> Eval? {
      guard let l else { return nil }
      let k = FEN.sideToMove(fen) == .white ? 1 : -1
      return Eval(cp: l.cp.map { $0 * k }, mate: l.mate.map { $0 * k })
    }
    return WebRecord(
      ply: p.index + (oneBased ? 1 : 0), moveNumber: p.moveNumber, san: p.san, cls: r.cls.rawValue,
      winBefore: r.winBefore, winAfter: r.winAfter, accuracy: r.accuracy,
      best: r.bestSan, punishedBy: after?.first?.best.flatMap { FEN.san(fen: p.fenAfter, uci: $0) },
      line: FEN.sanLine(fen: p.fenAfter, pv: after?.first?.pv ?? [], max: 8),
      bestLine: before?.first.map { FEN.sanLine(fen: p.fenBefore, pv: $0.pv, max: 8) },
      evalBefore: white(before?.first, fen: p.fenBefore),
      evalAfter: p.isCheckmate ? Eval(cp: nil, mate: p.mover == .white ? 1 : -1) : white(after?.first, fen: p.fenAfter))
  }

  /// 一個要算的解說：只帶原始資料，轉成網站格式（走法換算、JSON）也在解說執行緒上做，主執行緒只排隊
  struct Request: @unchecked Sendable {
    let key: String
    let record: MoveRecord
    let ply: Ply
    let before: [EngineLine]?
    let after: [EngineLine]?
    let opponent: Bool
    let lang: String
  }

  static func request(key: String, record r: MoveRecord, ply p: Ply, before: [EngineLine]?, after: [EngineLine]?, opponent: Bool = false) -> Request? {
    let lang = AppLang.js
    return Request(key: (opponent ? key + "-opp" : key) + "-" + lang, record: r, ply: p, before: before, after: after, opponent: opponent, lang: lang)
  }

  /// 在解說執行緒上算（呼叫端自己決定是同步等，還是非同步）
  nonisolated private static func compute(_ q: Request) -> Explanation? {
    guard let json = try? JSONEncoder().encode(webRecord(q.record, ply: q.ply, before: q.before, after: q.after)), let rec = String(data: json, encoding: .utf8),
          let fn = context?.objectForKeyedSubscript("RLExplain"), !fn.isUndefined,
          let out = fn.call(withArguments: [q.ply.fenBefore, q.ply.san, rec, q.opponent, q.lang])?.toString(), out != "null", out != "undefined" else { return nil }
    return try? JSONDecoder().decode(Explanation.self, from: Data(out.utf8))
  }

  /// before／after：走這步之前、之後的局面的引擎前幾名（走棋方視角）
  /// opponent：這步是對手走的，說明換成從使用者的角度講（「你」「對手」對調）
  /// 同步版：先查快取（載入時都先用 prefetch 算好了）；沒有才當場算
  static func explain(key: String, record r: MoveRecord, ply p: Ply, before: [EngineLine]?, after: [EngineLine]?, opponent: Bool = false) -> Explanation? {
    let k = (opponent ? key + "-opp" : key) + "-" + AppLang.js
    if let hit = cache[k] { return hit }
    guard let q = request(key: key, record: r, ply: p, before: before, after: after, opponent: opponent) else { return nil }
    // 不用 queue.sync：sync 會直接在呼叫的執行緒（主執行緒）跑 JS，之後 JS 回收記憶體時會暫停主執行緒、動畫一頓一頓。
    // 一律丟到解說執行緒，主執行緒等結果（只有快取沒算到時才會走這裡）
    nonisolated(unsafe) var e: Explanation?
    let done = DispatchSemaphore(value: 0)
    queue.async { e = compute(q); done.signal() }
    done.wait()
    if let e { cache[k] = e }
    return e
  }

  static func cached(_ q: Request) -> Bool { cache[q.key] != nil }

  /// 在背景一個一個算好放進快取，主執行緒完全不等；progress：算完幾個（0...1）
  static func prefetch(_ list: [Request], progress: ((Double) -> Void)? = nil) async {
    let todo = list.filter { cache[$0.key] == nil }
    for (i, q) in todo.enumerated() {
      if Task.isCancelled { return }
      let e: Explanation? = await withCheckedContinuation { c in queue.async { c.resume(returning: compute(q)) } }
      if let e { cache[q.key] = e }
      progress?(Double(i + 1) / Double(todo.count))
    }
    progress?(1)
  }
}

extension Grading {
  /// 局面好壞的白話（走棋方視角的勝率）：勝勢、大優、小優、均勢、小劣、大劣、敗勢
  static func standing(_ win: Double) -> String {
    switch win {
    case 0.9...: String(localized: "勝勢")
    case 0.75..<0.9: String(localized: "大優")
    case 0.6..<0.75: String(localized: "小優")
    case 0.4..<0.6: String(localized: "均勢")
    case 0.25..<0.4: String(localized: "小劣")
    case 0.1..<0.25: String(localized: "大劣")
    default: String(localized: "敗勢")
    }
  }

  /// 英文句子裡嵌的局面白話（JS 回英文時用）
  nonisolated static func standingEnglish(_ win: Double) -> String {
    switch win {
    case 0.9...: "winning"
    case 0.75..<0.9: "clearly better"
    case 0.6..<0.75: "slightly better"
    case 0.4..<0.6: "equal"
    case 0.25..<0.4: "slightly worse"
    case 0.1..<0.25: "clearly worse"
    default: "lost"
    }
  }

  /// 跟最佳步比差多少的白話（不用百分比）
  static func gapText(_ gap: Int) -> String {
    gap <= 2 ? String(localized: "一樣好") : gap <= 6 ? String(localized: "差一點") : gap <= 12 ? String(localized: "明顯變差") : String(localized: "大幅變差")
  }
}

extension MoveRecord {
  /// 「你：小優 → 大劣」——講清楚是誰的局面變了
  func standingText(me: Side) -> String {
    let who = mover == me ? String(localized: "你") : String(localized: "對手")
    let a = Grading.standing(winBefore), b = Grading.standing(winAfter)
    return a == b ? String(localized: "\(who)：維持\(a)") : String(localized: "\(who)：\(a) → \(b)")
  }
}

/// 棋盤標示的資料（網站 moveRelations＋沒保護被攻擊的子），格子用 "e4" 這種寫法
struct BoardRelations: Decodable, Equatable {
  struct Link: Decodable, Equatable { let from: String; let to: String }
  struct Pin: Decodable, Equatable { let from: String; let pinned: String; let behind: String }
  struct Threat: Decodable, Equatable { let from: String; let to: String; let kind: String; let san: String }
  var attacks: [Link] = []
  var defends: [Link] = []
  var attackedBy: [Link] = []
  var pins: [Pin] = []
  var threats: [Threat] = []
  var hanging: [String] = []
  /// 真正的威脅：下一步能白吃子或將殺
  var realThreat: Threat? { threats.first { $0.kind == "win" || $0.kind == "mate" } }
}

extension ExplainJS {
  nonisolated private static func boardCompute(fen: String, san: String) -> BoardRelations? {
    guard let fn = contextForBoard?.objectForKeyedSubscript("RLBoard"), !fn.isUndefined,
          let out = fn.call(withArguments: [fen, san])?.toString(), out != "null", out != "undefined" else { return nil }
    return try? JSONDecoder().decode(BoardRelations.self, from: Data(out.utf8))
  }

  /// 一次在解說執行緒上算好多步（主執行緒不等）
  static func boards(_ plies: [Ply]) async -> [Int: BoardRelations] {
    await withCheckedContinuation { c in
      boardQueue.async {
        var out: [Int: BoardRelations] = [:]
        for p in plies { if let r = boardCompute(fen: p.fenBefore, san: p.san) { out[p.index] = r } }
        c.resume(returning: out)
      }
    }
  }
}

/// 開局原則觀察：第幾個半回合（1 起算，同網站）、哪一類、一句話
struct OpeningNote: Decodable, Equatable { let ply: Int; let tag: String; let text: String }

extension ExplainJS {
  static func openingNotes(_ sans: [String], side: Side) async -> [OpeningNote] {
    guard let json = try? JSONEncoder().encode(sans), let list = String(data: json, encoding: .utf8) else { return [] }
    let lang = AppLang.js
    return await withCheckedContinuation { c in
      boardQueue.async {
        let fn = contextForBoard?.objectForKeyedSubscript("RLOpening")
        let out = fn?.call(withArguments: [list, side == .white ? "w" : "b", lang])?.toString() ?? "[]"
        c.resume(returning: (try? JSONDecoder().decode([OpeningNote].self, from: Data(out.utf8))) ?? [])
      }
    }
  }

  /// 挑一條有證據的：早出后要在之後 4 手內又被迫動后；其他三類本身就是證據。先看使用者，再看對手
  static func openingObservation(_ line: ChessLine, me: Side) async -> String? {
    let sans = line.plies.map(\.san)
    func usable(_ n: OpeningNote, _ side: Side) -> Bool {
      guard n.ply <= 20 else { return false }
      // 被將軍時的應對（例如用象擋）不算違反開局原則
      if n.ply >= 2, line.plies[n.ply - 2].san.hasSuffix("+") { return false }
      if n.tag != "early_queen" { return true }
      let later = line.plies.dropFirst(n.ply).filter { $0.mover == side }.prefix(4)
      return later.contains { $0.san.hasPrefix("Q") }
    }
    if let n = await openingNotes(sans, side: me).first(where: { usable($0, me) }) { return n.text }
    let other: Side = me == .white ? .black : .white
    if let n = await openingNotes(sans, side: other).first(where: { usable($0, other) }) { return String(localized: "對手 · \(n.text)") }
    return nil
  }
}
