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
    var plainOutcome: String { ExplainJS.plain(outcome) + (note.map { "（\(ExplainJS.plain($0))）" } ?? "") }
  }

  struct Explanation: Decodable {
    let motif: String
    let headline: String
    let reasons: [String]
    let lines: [Line]
    /// 給使用者看的理由：拿掉「評分 +2.7 → -4.4」這行，其他句子裡的評分換成「均勢、小優」這種說法
    var plainReasons: [String] { reasons.filter { !$0.hasPrefix("評分") }.map(ExplainJS.plain) }
  }

  /// 「評分從 -0.4 掉到 -1.6」→「局面從均勢變成小劣」。網站解說裡的評分是走這步那一方的視角
  nonisolated static func plain(_ text: String) -> String {
    func word(_ v: String) -> String {
      if v.contains("M") { return v.hasPrefix("-") ? "被將殺" : "可以將殺" }
      guard let x = Double(v) else { return v }
      return Grading.standing(Grading.winProb(cp: Int(x * 100), mate: nil))
    }
    let num = #"([+-]?M?\d*(?:\.\d+)?)"#
    var out = text
    let rules: [(String, ([String]) -> String)] = [
      ("評分從 \(num) 掉到 \(num)", { m in word(m[0]) == word(m[1]) ? "局面還是\(word(m[0]))，但變差了" : "局面從\(word(m[0]))變成\(word(m[1]))" }),
      ("評分從 \(num) 升到 \(num)", { m in "局面從\(word(m[0]))變成\(word(m[1]))" }),
      ("評分維持在 \(num)", { m in "局面維持\(word(m[0]))" }),
      ("掉到 \(num)", { m in "變成\(word(m[0]))" }),
      ("評分 \(num)", { m in word(m[0]) }),
    ]
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

  private static let context: JSContext? = {
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

  /// before／after：走這步之前、之後的局面的引擎前幾名（走棋方視角）
  /// opponent：這步是對手走的，說明換成從使用者的角度講（「你」「對手」對調）
  static func explain(key: String, record r: MoveRecord, ply p: Ply, before: [EngineLine]?, after: [EngineLine]?, opponent: Bool = false) -> Explanation? {
    let key = opponent ? key + "-opp" : key
    if let hit = cache[key] { return hit }
    guard let ctx = context, let fn = ctx.objectForKeyedSubscript("RLExplain"), !fn.isUndefined else { return nil }
    let rec = webRecord(r, ply: p, before: before, after: after)
    guard let json = try? JSONEncoder().encode(rec), let s = String(data: json, encoding: .utf8),
          let out = fn.call(withArguments: [p.fenBefore, p.san, s, opponent])?.toString(), out != "null", out != "undefined",
          let e = try? JSONDecoder().decode(Explanation.self, from: Data(out.utf8)) else { return nil }
    cache[key] = e
    return e
  }
}

extension Grading {
  /// 局面好壞的白話（走棋方視角的勝率）：勝勢、大優、小優、均勢、小劣、大劣、敗勢
  static func standing(_ win: Double) -> String {
    switch win {
    case 0.9...: "勝勢"
    case 0.75..<0.9: "大優"
    case 0.6..<0.75: "小優"
    case 0.4..<0.6: "均勢"
    case 0.25..<0.4: "小劣"
    case 0.1..<0.25: "大劣"
    default: "敗勢"
    }
  }

  /// 跟最佳步比差多少的白話（不用百分比）
  static func gapText(_ gap: Int) -> String {
    gap <= 2 ? "一樣好" : gap <= 6 ? "差一點" : gap <= 12 ? "明顯變差" : "大幅變差"
  }
}

extension MoveRecord {
  /// 「你：小優 → 大劣」——講清楚是誰的局面變了
  func standingText(me: Side) -> String {
    let who = mover == me ? "你" : "對手"
    let a = Grading.standing(winBefore), b = Grading.standing(winAfter)
    return a == b ? "\(who)：維持\(a)" : "\(who)：\(a) → \(b)"
  }
}
