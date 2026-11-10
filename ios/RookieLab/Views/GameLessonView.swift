import SwiftUI

/// 重點復盤的一個重點（照 Duolingo Chess 的 Game Review 分三類：好棋、錯失的機會、失誤）
struct GameHighlight: Identifiable {
  enum Kind {
    case good, missed, mistake, study
    var zh: String { if self == .study { return String(localized: "學習停點") }; return self == .good ? String(localized: "好棋") : self == .missed ? String(localized: "錯失的機會") : String(localized: "失誤") }
    var icon: String { if self == .study { return "lightbulb" }; return self == .good ? "trophy.fill" : self == .missed ? "exclamationmark.triangle.fill" : "exclamationmark.circle.fill" }
    var color: Color { if self == .study { return Brand.teal }; return self == .good ? Color(hex: 0x1BACA6) : self == .missed ? Brand.orange : Color(hex: 0xD64545) }
  }
  /// 最佳線的一步（要你走的、對手接的）
  struct Step { let uci: String; let san: String; let mine: Bool; let caption: String }

  let kind: Kind
  let record: MoveRecord
  let ply: Ply
  let explanation: ExplainJS.Explanation?
  /// 要你走的那一步（快速復盤只問一步，找到就繼續播）
  let steps: [Step]
  /// 第一步也算找到的（跟最佳步差不到 3%）
  let accept: [String]
  /// 先算好的文字（開始前一次備好，播放時不再算）
  var headline: String?
  var reason: String?
  var praise: String?
  var hint = ""
  var studyTitle: String?
  var studyDetail: String?
  var id: Int { record.ply }
  var interactive: Bool { kind != .good && !steps.isEmpty }
  var bestSan: String { steps.first?.san ?? record.bestSan ?? "" }

  /// 每局最多幾個重點（Duolingo 一局三個；這裡錯失的機會最多 3、失誤 2、好棋 2，照棋局順序）
  /// opening：開局停點的標題與說明（名稱、使用者這個開局的戰績）。有它就固定加一個開局停點，取代「這局的開局理論」備用停點
  @MainActor static func build(_ m: ReviewModel, theory: [Int: String] = [:], opening: (title: String, detail: String?)? = nil) -> [GameHighlight] {
    var highlights = picks(m, theory: theory, theoryStop: opening == nil)
    if let opening, let ply = openingPly(m, theory: theory, taken: Set(highlights.map(\.id))),
       let r = m.records[safe: ply] ?? nil, var h = make(m, r, kind: .study, practice: false) {
      h.studyTitle = opening.title
      h.studyDetail = opening.detail
      highlights.append(h)
    }
    return highlights.sorted { $0.id < $1.id }
  }

  /// 開局停點停在哪一手：最後一步理論走法；沒有理論資料就停在第 4 手黑方走完。避開已有的重點與自己的壞棋
  @MainActor static func openingPly(_ m: ReviewModel, theory: [Int: String], taken: Set<Int>) -> Int? {
    guard let line = m.line, !line.plies.isEmpty else { return nil }
    let target = min(theory.keys.max() ?? 7, line.plies.count - 1)
    for ply in stride(from: target, through: 0, by: -1) where !taken.contains(ply) {
      if let r = m.records[safe: ply] ?? nil, !r.cls.isBad { return ply }
    }
    return nil
  }

  @MainActor private static func picks(_ m: ReviewModel, theory: [Int: String], theoryStop: Bool) -> [GameHighlight] {
    guard let line = m.line else { return [] }
    let mine = m.records.compactMap { $0 }.filter { $0.mover == m.me }
    func drop(_ r: MoveRecord) -> Double { r.winBefore - r.winAfter }
    var missed: [MoveRecord] = [], mistakes: [MoveRecord] = []
    for r in mine where r.cls.isBad {
      guard let before = m.evals[safe: r.ply] ?? nil else { continue }
      if ReviewBuilder.isOpportunity(r, before: before) { missed.append(r) }
      // 已經輸定的局面不拿來教（怎麼走都差不多）
      else if r.winBefore >= 0.35 { mistakes.append(r) }
    }
    // 好棋：傑出、好棋，還有對手走壞之後你馬上抓到（走了最佳步）
    let punished = mine.filter { r in
      [.best, .excellent].contains(r.cls) && (m.records[safe: r.ply - 1] ?? nil)?.cls.isBad == true && r.winAfter >= 0.6
    }
    let good = mine.filter { [.brilliant, .great].contains($0.cls) } + punished.sorted { $0.winAfter - $0.winBefore > $1.winAfter - $1.winBefore }
    let picked = Array(missed.sorted { drop($0) > drop($1) }.prefix(3))
      + Array(mistakes.sorted { drop($0) > drop($1) }.prefix(2))
      + Array(good.prefix(2))
    var highlights = picked.compactMap { r in
      make(m, r, kind: r.cls.isBad ? (missed.contains(r) ? .missed : .mistake) : .good)
    }
    guard highlights.count < 2 else { return highlights.sorted { $0.id < $1.id } }
    let candidates = mine.filter { r in
      !r.cls.isBad && r.cls != .inaccuracy && !highlights.contains { abs($0.id - r.ply) <= 2 }
    }
    let times = mine.compactMap { m.thinkTimes[safe: $0.ply] ?? nil }.filter { $0.isFinite && $0 > 0 }.sorted()
    if times.count >= 5 {
      let threshold = max(12, times[times.count / 2] * 3)
      let longMoves = candidates.compactMap { r -> (MoveRecord, Double)? in
        guard theory[r.ply] == nil, let t = m.thinkTimes[safe: r.ply] ?? nil, t.isFinite, t >= threshold else { return nil }
        return (r, t)
      }.sorted { $0.1 == $1.1 ? $0.0.ply < $1.0.ply : $0.1 > $1.1 }
      for (r, time) in longMoves {
        guard [.best, .excellent].contains(r.cls), var h = make(m, r, kind: .study), !h.steps.isEmpty else { continue }
        h.studyTitle = String(localized: "這一步你用了較多時間")
        h.studyDetail = String(localized: "用時 \(Int(time.rounded())) 秒。可以再試一次，看看有哪些選擇。")
        highlights.append(h)
        break
      }
    }
    if theoryStop, highlights.count < 2, let lastBook = theory.keys.max(), let name = theory[lastBook],
       let r = m.records[safe: lastBook] ?? nil, !r.cls.isBad,
       !highlights.contains(where: { abs($0.id - r.ply) <= 2 }),
       var h = make(m, r, kind: .study, practice: false) {
      h.studyTitle = String(localized: "這局的開局理論")
      h.studyDetail = String(localized: "\(Openings.name(name))。\(r.san) 是這個局面已收錄的走法。")
      highlights.append(h)
    }
    if highlights.isEmpty {
      for r in candidates {
        let p = line.plies[r.ply]
        guard p.san.hasPrefix("O-O"), var h = make(m, r, kind: .study, practice: false) else { continue }
        h.studyTitle = String(localized: "王車易位")
        h.studyDetail = String(localized: "\(r.san) 讓王離開中央，也把車帶到更靠近中央的格子。")
        highlights.append(h)
        break
      }
    }
    return highlights.sorted { $0.id < $1.id }
  }

  /// 單一一步（逐步復盤按「重走一下」）：錯失良機或當時有勝勢的算機會，其他算失誤
  @MainActor static func single(_ m: ReviewModel, ply: Int) -> GameHighlight? {
    guard let r = m.records[safe: ply] ?? nil, r.cls.isBad else { return nil }
    let before = m.evals[safe: ply] ?? nil
    let chance = r.cls == .miss || before.map { ReviewBuilder.isOpportunity(r, before: $0) } == true
    return make(m, r, kind: chance ? .missed : .mistake)
  }

  @MainActor private static func make(_ m: ReviewModel, _ r: MoveRecord, kind: Kind, practice: Bool = true) -> GameHighlight? {
      guard let line = m.line, let p = line.plies[safe: r.ply] else { return nil }
      let e = m.explanation(r.ply)
      let before = m.evals[safe: r.ply] ?? nil
      let lines = before ?? []
      var accept = lines.indices.filter { Difficulty.winGap(lines, index: $0) <= 3 }.compactMap { lines[$0].best }
      if kind == .study, [.best, .excellent].contains(r.cls) { accept.append(r.uci) }
      var h = GameHighlight(kind: kind, record: r, ply: p, explanation: e, steps: kind == .good || !practice ? [] : steps(e, pv: before?.first?.pv ?? [], fen: p.fenBefore), accept: accept)
      h.headline = e?.headline
      h.reason = h.steps.first.flatMap { $0.caption.isEmpty ? nil : $0.caption } ?? e?.plainReasons.first
      let pun = r.cls == .best || r.cls == .excellent
      h.praise = pun ? String(localized: "抓到了！對手剛走錯，你用 \(r.san) 抓住了機會") : String(localized: "好棋！\(r.san)")
      if kind == .good { h.reason = e?.plainReasons.first ?? e?.headline }
      if let u = h.steps.first?.uci, let code = FEN.pieces(p.fenBefore)[String(u.prefix(2))] {
        h.hint = String(localized: "提示：動 \(String(u.prefix(2))) 的\(Explain.pieceName(String(code.last!).lowercased()))")
      }
      return h
  }

  /// 錯失的是哪一類機會：「錯過捉雙」→「捉雙」、「錯過白吃的馬」→「白吃的馬」、「錯過得子的機會」→「得子」
  var chanceType: String? {
    guard kind == .missed, let h = headline else { return nil }
    var t: String
    if h.hasPrefix("錯過") {
      t = String(h.dropFirst(2))
      if t.hasSuffix("的機會") { t.removeLast(3) }
    } else if h.hasPrefix("Missed ") {
      t = String(h.dropFirst(7))
      for art in ["a ", "an "] where t.hasPrefix(art) { t = String(t.dropFirst(art.count)) }
      if t.hasPrefix("chance") { return nil }
    } else if let p = ["Oportunidad perdida: ", "Oportunidade perdida: "].first(where: { h.hasPrefix($0) }) {
      // 西文、葡文：「Oportunidad perdida: horquilla」；「…de ganar material」這種籠統的不標
      t = String(h.dropFirst(p.count))
    } else if h == "Mate perdido" {
      t = "Mate"
    } else {
      return nil
    }
    return t.isEmpty ? nil : t
  }

  /// 最佳線：有網站解說的線就用它（每一步有說明），沒有就用引擎的線
  private static func steps(_ e: ExplainJS.Explanation?, pv: [String], fen: String) -> [Step] {
    var out: [Step] = []
    if let best = e?.lines.first(where: { $0.kind == "best" }), best.steps.first?.mine == true {
      for s in best.steps {
        let promo = s.san.split(separator: "=").dropFirst().first.map { String($0.prefix(1)).lowercased() } ?? ""
        out.append(Step(uci: s.from + s.to + promo, san: s.san, mine: s.mine, caption: ExplainJS.plain(s.caption)))
      }
    } else {
      var f = fen
      for (i, u) in pv.enumerated() {
        guard let p = ChessLine.ply(fen: f, uci: u, index: 0) else { break }
        out.append(Step(uci: u, san: p.san, mine: i % 2 == 0, caption: ""))
        f = p.fenAfter
      }
    }
    return Array(out.prefix(1))
  }
}

/// 快速復盤（照 Duolingo Chess）：就在復盤頁原本的棋盤上，整局快速自動播。
/// 開始前一次備好所有東西（每個重點的文字、答案、提示），播放時只換局面：不評級、不跑引擎、不算解說，背景分析也先停。
/// 好棋停一下誇一句；錯失的機會、失誤停在走之前讓你找，找到打勾、一句為什麼，再播你當時走的那步，接著往下播
@MainActor @Observable
final class QuickReview {
  enum Phase { case playing, praise, preview, trying, solved, revealed, done }
  let line: ChessLine
  let highlights: [GameHighlight]
  /// 只看不考的停點（雙方）與超過名額沒停的步
  let notices: [Int: ReviewNotice]
  let skipped: [Int]
  /// 停點的攻守關係（棋盤標示用，準備時先算好）
  let relations: [Int: BoardRelations]
  let me: Side
  /// 每一步先算好的：評級、走完的分數（你的角度）、分數變化
  struct Note { let cls: MoveClass; let score: String; let delta: String?; let tag: String }
  let notes: [Note?]
  /// 每個局面白方的勝率（評分條）
  let whiteWins: [Double?]
  /// 讓局勢逆轉的步（你的勝率從 65% 以上掉到 35% 以下，或反過來）
  let reversals: Set<Int>
  private let evals: [[EngineLine]?]
  /// 走錯時對手的懲罰：（對手走的、那步做了什麼、走完的分數）
  private(set) var refute: (san: String, tag: String, score: String?)?
  private(set) var phase: Phase = .playing
  private var began: TimeInterval?
  private var endLogged = false
  private(set) var pos = 0
  private(set) var next = 0
  private(set) var fen: String
  private(set) var wrongs = 0
  var hint = false
  private(set) var alt: String?
  private(set) var last: (from: String, to: String)?
  private(set) var toast: GameHighlight?
  /// 停下來講的失誤（不是要你找步的那種，例如對手的失誤）：第幾手
  private(set) var notice: Int?
  private(set) var results: [Int: Bool] = [:]
  private(set) var busy = false
  private var attempt = UUID()

  /// 一般的步播多快；好棋停多久
  static let gap: UInt64 = 320_000_000
  /// 停點的前一步放慢，讓人知道接下來要停
  static let slow: UInt64 = 900_000_000

  /// 走完第 i 步之後就要停（只看的停點、好棋），或下一步是要你找的重點
  private func pausesAfter(_ i: Int) -> Bool {
    notices[i] != nil || highlights.contains { ($0.record.ply == i && !$0.interactive) || ($0.interactive && $0.record.ply == i + 1) }
  }
  static let pause: UInt64 = 1_300_000_000

  private let resignedGame: Bool

  init(line: ChessLine, highlights: [GameHighlight], notices: [Int: ReviewNotice] = [:], skipped: [Int] = [], relations: [Int: BoardRelations] = [:], me: Side, records: [MoveRecord?], evals: [[EngineLine]?], whiteWins: [Double?], tags: [String], resigned: Bool = false) {
    resignedGame = resigned
    self.line = line; self.highlights = highlights; self.notices = notices; self.skipped = skipped; self.relations = relations; self.me = me; self.whiteWins = whiteWins; self.evals = evals
    reversals = Swing.plies(whiteWins: whiteWins, me: me)
    fen = line.startFen
    // 分數用你的角度：+ 是你好、- 是對手好（引擎的分數是輪到誰走就從誰的角度）
    func score(_ k: Int) -> (text: String, value: Double?)? {
      guard let e = (evals[safe: k] ?? nil)?.first else { return nil }
      let sign: Double = FEN.sideToMove(line.fen(at: k)) == me ? 1 : -1
      if let m = e.mate { return ((Double(m) * sign > 0 ? "" : "-") + "M\(abs(m))", nil) }
      let v = Double(e.cp ?? 0) / 100 * sign
      return (String(format: "%+.1f", v), v)
    }
    notes = line.plies.indices.map { i in
      guard let r = records[safe: i] ?? nil, let after = score(i + 1) else { return nil }
      var delta: String?
      if let b = score(i)?.value, let a = after.value { delta = abs(a - b) < 0.05 ? "±0" : String(format: "%+.1f", a - b) }
      return Note(cls: r.cls, score: after.text, delta: delta, tag: tags[safe: i] ?? "")
    }
  }

  /// 剛走的那一步
  private var lastNote: (ply: Ply, note: Note)? {
    guard pos > 0, let n = notes[safe: pos - 1] ?? nil else { return nil }
    return (line.plies[pos - 1], n)
  }
  /// 棋盤上標剛走那一步的評級
  var badge: (square: String, cls: MoveClass)? {
    guard [.playing, .praise, .done].contains(phase), let l = lastNote else { return nil }
    return (l.ply.to, l.note.cls)
  }
  var whiteWin: Double { whiteWins[safe: pos].flatMap { $0 } ?? 0.5 }

  var current: GameHighlight? { highlights[safe: next] }
  var tried: [GameHighlight] { highlights.filter { $0.interactive && ($0.kind != .study || results[$0.id] != nil) } }
  var found: Int { tried.filter { results[$0.id] == true }.count }
  /// 停著的重點（找步中、剛播到的好棋）
  var active: GameHighlight? { toast ?? ([.playing, .done].contains(phase) || notice != nil ? nil : current) }
  /// 停在失誤上（標題用）
  var noticing: Bool { notice != nil }
  var canMove: Bool { phase == .trying && !busy }

  /// 棋盤標示（只在停點畫，箭頭最多 3 條）：剛走那步灰；最佳步綠；威脅／牽制紅；保護藍細線
  var arrows: [Arrow] {
    if let k = notice {
      let p = line.plies[k]
      var out = [arrow(p.uci, Self.played)]
      // 下一步就要你自己找：不先畫出最佳步（不然答案就洩露了）
      let from = notices[k].map { $0.bestFrom } ?? k + 1
      if !askNext(after: k), let f = from, let u = (evals[safe: f] ?? nil)?.first?.best {
        // 你的失誤：畫對手接下來的懲罰（紅）；其他：畫該走的最佳步（綠）
        out.append(arrow(u, f == k + 1 && p.mover == me ? Self.threat : Brand.bestArrow))
      }
      if !askNext(after: k), let r = relations[k] { out += Self.pinOrThreat(r, moved: p.to, existing: out) }
      return Array(out.prefix(3))
    }
    if let t = toast {
      var out = [arrow(t.ply.uci, Self.played)]
      if t.studyTitle != nil, t.kind == .good, let prev = relations[t.record.ply - 1]?.realThreat {
        out.append(Arrow(from: prev.from, to: prev.to, color: Self.threat))
      }
      if t.kind == .good, let r = relations[t.record.ply] {
        if t.studyTitle != nil { out += r.defends.prefix(3 - out.count).map { Arrow(from: $0.from, to: $0.to, color: Self.defend, thin: true) } }
        else { out += Self.pinOrThreat(r, moved: t.ply.to, existing: out) }
      }
      return Array(out.prefix(3))
    }
    guard phase == .revealed || phase == .solved, alt == nil, let u = current?.steps.first?.uci else { return [] }
    return [Arrow(from: String(u.prefix(2)), to: String(u.dropFirst(2).prefix(2)), color: Brand.bestArrow)]
  }

  /// 格子標示：只看的停點把沒保護又被攻擊的子塗紅；守住威脅時把被保護的子圈藍
  var marks: [SquareMark] {
    if let k = notice, !askNext(after: k), let r = relations[k] {
      return r.hanging.prefix(2).map { SquareMark(square: $0, color: Self.threat) }
    }
    if let t = toast, t.studyTitle != nil, t.kind == .good, let r = relations[t.record.ply] {
      return r.defends.prefix(2).map { SquareMark(square: $0.to, color: Self.defend, ring: true) }
    }
    return []
  }

  static let played = Color.gray.opacity(0.75)
  static let threat = Color(hex: 0xD64545)
  static let defend = Color(hex: 0x3B82F6)

  /// 牽制優先（跟剛走的子有關的那條，從發動的子畫到後面的子），其次是這步準備的威脅
  private static func pinOrThreat(_ r: BoardRelations, moved: String, existing: [Arrow]) -> [Arrow] {
    if let pin = r.pins.first(where: { $0.from == moved || $0.pinned == moved || $0.behind == moved }) {
      return [Arrow(from: pin.from, to: pin.behind, color: threat)]
    }
    if let t = r.realThreat, !existing.contains(where: { $0.from == t.from && $0.to == t.to }) {
      return [Arrow(from: t.from, to: t.to, color: threat)]
    }
    return []
  }
  /// 第 k 手之後緊接著就是要你找最佳步的重點
  private func askNext(after k: Int) -> Bool { current.map { $0.interactive && $0.record.ply == k + 1 } ?? false }
  private func arrow(_ u: String, _ c: Color) -> Arrow { Arrow(from: String(u.prefix(2)), to: String(u.dropFirst(2).prefix(2)), color: c) }

  var squares: [String] { last.map { [$0.from, $0.to] } ?? [] }
  /// 提示要動的那顆子
  var pulse: String? { phase == .trying && hint ? current?.steps.first.map { String($0.uci.prefix(2)) } : nil }
  /// 看完了、而且是對手投降：棋盤上舉白旗
  var resigned = false

  private static func scoreText(_ head: String, score: String, delta: String?) -> String {
    let base = String(localized: "\(head)・分數 \(score)")
    return delta.map { base + String(localized: "（\($0)）") } ?? base
  }

  /// 教練這時候說的話：（表情、標題、一句說明）—都是先算好的字串
  var say: (mood: String, title: String, detail: String?) {
    if let k = notice, let stop = notices[k] { return (stop.mood, stop.title, stop.detail) }
    if let k = notice, let n = notes[safe: k] ?? nil {
      let p = line.plies[k], mine = p.mover == me
      let turned = reversals.contains(k)
      let title = turned
        ? (mine ? String(localized: "你 \(p.san)：局勢逆轉") : String(localized: "對手 \(p.san)：局勢逆轉，你的機會來了"))
        : (mine ? String(localized: "你 \(p.san)：\(n.cls.zh)") : String(localized: "對手 \(p.san)：\(n.cls.zh)，你的機會來了"))
      let arrow = mine ? String(localized: "橘色箭頭是對手接下來的好棋") : String(localized: "綠色箭頭是你可以抓的機會")
      // 下一步要你自己找：不提箭頭（沒有畫），標籤也只說評級——解說的標題像「送子：e5 的馬」會直接講出要吃哪裡
      let ask = askNext(after: k)
      var score = Self.scoreText(ask ? n.cls.zh : n.tag, score: n.score, delta: n.delta)
      var rising = false
      if turned, let b = whiteWins[safe: k] ?? nil, let a = whiteWins[safe: k + 1] ?? nil {
        let from = Swing.percent(b, me: me), to = Swing.percent(a, me: me)
        rising = to > from
        score += "\n" + String(localized: "你的勝率 \(from)% → \(to)%")
      }
      return (mine ? (rising ? "happy" : "sad") : "point", title, ask ? score : score + "\n" + arrow)
    }
    if let t = toast {
      if let title = t.studyTitle { return ("point", title, t.studyDetail) }
      let n = notes[safe: t.record.ply] ?? nil
      let change = n.map { Self.scoreText($0.tag, score: $0.score, delta: $0.delta) }
      return ("happy", t.praise ?? String(localized: "好棋！"), [t.reason, change].compactMap { $0 }.joined(separator: "\n"))
    }
    if phase == .playing {
      guard let l = lastNote else { return ("think", String(localized: "快速播放中…"), String(localized: "停在重點分析")) }
      let title = l.ply.mover == me ? String(localized: "你 \(l.ply.san)：\(l.note.tag)") : String(localized: "對手 \(l.ply.san)：\(l.note.tag)")
      return (l.ply.mover == me && l.note.cls.isBad ? "sad" : "think", title,
              Self.scoreText(l.note.cls.zh, score: l.note.score, delta: l.note.delta))
    }
    guard let h = current, phase != .done else { return ("cheer", String(localized: "這局看完了"), nil) }
    switch phase {
    case .preview: return ("think", h.studyTitle ?? h.kind.zh, h.studyDetail)
    case .playing, .praise, .done: return ("cheer", String(localized: "這局看完了"), nil)
    case .trying:
      if wrongs > 0 {
        if let r = refute {
          let detail = r.tag + (r.score.map { String(localized: "・分數變成 \($0)") } ?? "") + (busy ? "" : String(localized: "。再試一次")) + (hint ? "\n\(h.hint)" : "")
          return ("sad", String(localized: "不是這步：對手會走 \(r.san)"), detail)
        }
        return ("sad", busy ? String(localized: "看看對手會怎麼走…") : String(localized: "不是這步，再想想"), hint ? h.hint : nil)
      }
      let prev = pos > 0 ? String(localized: "對手剛走了 \(line.plies[pos - 1].san)") : nil
      let lead = reversals.contains(h.record.ply) ? String(localized: "這一步是這局的轉折點。") : h.chanceType.map { String(localized: "這裡有個「\($0)」的機會！") } ?? (h.kind == .missed ? String(localized: "這裡有個機會！") : String(localized: "這一步要小心。"))
      return ("think", String(localized: "\(lead)找出最好的一步"),
              hint ? h.hint : [prev, h.headline].compactMap { $0 }.joined(separator: "・"))
    case .solved: return ("cheer", alt.map { String(localized: "\($0) 也可以！") } ?? String(localized: "就是這步！\(h.bestSan)"), h.reason)
    case .revealed: return ("point", String(localized: "更好的一步是 \(h.bestSan)"), h.reason)
    }
  }

  // MARK: 流程

  func start() {
    began = ProcessInfo.processInfo.systemUptime; endLogged = false
    Task { await StockfishService.shared.holdBackground(true) }
    run()
  }

  /// 只重走一步（逐步復盤的「重走一下」）：走完就回去
  var onSingleDone: (() -> Void)?

  func startSingle(_ done: @escaping () -> Void) {
    onSingleDone = done
    Task { await StockfishService.shared.holdBackground(true) }
    skipAhead()
  }

  func stop() {
    if let began, !endLogged {
      endLogged = true
      Telemetry.log("quick_review_exit", ["position": pos, "plies": line.plies.count,
                                          "duration_ms": Int((ProcessInfo.processInfo.systemUptime - began) * 1000)])
    }
    attempt = UUID()
    Task { await StockfishService.shared.holdBackground(false) }
  }

  private func show(_ f: String, last l: (String, String)?) {
    withAnimation(.easeInOut(duration: 0.2)) { fen = f }
    last = l
  }

  private func run() {
    let a = attempt
    phase = .playing
    Task {
      while a == attempt, pos < line.plies.count {
        if let x = current, x.record.ply == pos, x.interactive {
          wrongs = 0; hint = false; alt = nil; refute = nil
          phase = x.kind == .study && onSingleDone == nil ? .preview : .trying
          return
        }
        let p = line.plies[pos]
        try? await Task.sleep(nanoseconds: pausesAfter(p.index) ? Self.slow : Self.gap)
        guard a == attempt else { return }
        show(p.fenAfter, last: (p.from, p.to))
        Sounds.play(for: p)
        pos += 1
        // 好棋：停下來講它好在哪，等你按「繼續」
        if let x = current, x.record.ply == p.index, !x.interactive {
          toast = x
          phase = .praise
          Haptics.bump()
          return
        }
        // 失誤（雙方都算，不精確不停）：停下來讓人知道這裡出錯了，按「繼續」再播
        if notices[p.index] != nil {
          notice = p.index
          phase = .praise
          Haptics.bump()
          return
        }
      }
      guard a == attempt else { return }
      finish()
    }
  }

  func beginStudy() {
    guard phase == .preview else { return }
    phase = .trying
  }

  func skipStudy() {
    guard phase == .preview else { return }
    next += 1
    run()
  }

  /// 好棋看完了：接著播
  func continuePraise() {
    guard phase == .praise else { return }
    if toast != nil { next += 1 }
    toast = nil
    notice = nil
    run()
  }

  private func finish() {
    phase = .done
    if let began, !endLogged {
      endLogged = true
      Telemetry.log("quick_review_done", ["found": found, "tried": tried.count, "highlights": highlights.count,
                                          "duration_ms": Int((ProcessInfo.processInfo.systemUptime - began) * 1000)])
    }
    if resignedGame { resigned = true }
    ReviewStore.shared.markPracticed()
    Task { await StockfishService.shared.holdBackground(false) }
  }

  func tryMove(_ from: String, _ to: String) {
    guard canMove, let h = current, let want = h.steps.first?.uci else { return }
    let promo = FEN.pieces(fen)[from]?.last == "P" && (to.hasSuffix("8") || to.hasSuffix("1")) ? (want.count == 5 ? String(want.suffix(1)) : "q") : ""
    let uci = from + to + promo
    guard let p = ChessLine.ply(fen: fen, uci: uci, index: 0) else { return }
    if uci == want || h.accept.contains(uci) || p.isCheckmate {
      Haptics.bump(); Sounds.play(for: p)
      show(p.fenAfter, last: (p.from, p.to))
      alt = uci == want ? nil : p.san
      if results[h.id] == nil { results[h.id] = wrongs == 0 && !hint }
      phase = .solved
      resume()
      return
    }
    if h.kind == .study {
      reveal()
      return
    }
    // 不是這步：子走過去，對手走出懲罰的那一步（讓你看到為什麼不好），停一下再退回來重試
    wrongs += 1
    Haptics.bump()
    let before = fen, a = attempt
    busy = true
    refute = nil
    show(p.fenAfter, last: (p.from, p.to))
    Sounds.play(for: p)
    Task {
      // 你走的就是當時那步：分析時已經算好對手最好的應手；別的走法才請引擎看一下（只看這一個局面）
      let lines: [EngineLine]
      if uci == h.ply.uci, let e = evals[safe: h.record.ply + 1] ?? nil { lines = e }
      else { lines = await StockfishService.shared.analyse(fen: p.fenAfter, depth: 10, multipv: 1, priority: .interactive) }
      try? await Task.sleep(nanoseconds: 450_000_000)
      guard a == attempt else { return }
      if let u = lines.first?.best, let r = ChessLine.ply(fen: p.fenAfter, uci: u, index: 0) {
        show(r.fenAfter, last: (r.from, r.to))
        Sounds.play(for: r)
        // 分數用你的角度（引擎是從對手的角度算的）
        let e = lines[0]
        let sc = e.mate.map { ($0 > 0 ? "-" : "") + "M\(abs($0))" } ?? String(format: "%+.1f", -Double(e.cp ?? 0) / 100)
        refute = (r.san, MoveTags.tag(r, explanation: nil), sc)
        try? await Task.sleep(nanoseconds: 1_700_000_000)
      } else {
        try? await Task.sleep(nanoseconds: 300_000_000)
      }
      guard a == attempt else { return }
      show(before, last: nil)
      busy = false
    }
  }

  /// 看答案：箭頭指出來、走給你看，然後繼續播
  func reveal() {
    guard let h = current, let u = h.steps.first?.uci else { return }
    if results[h.id] == nil { results[h.id] = false }
    phase = .revealed
    let a = attempt
    Task {
      try? await Task.sleep(nanoseconds: 700_000_000)
      guard a == attempt, let p = ChessLine.ply(fen: h.ply.fenBefore, uci: u, index: 0) else { return }
      Sounds.play(for: p)
      show(p.fenAfter, last: (p.from, p.to))
      resume()
    }
  }

  /// 停一下讓人看懂 → 退回走之前 → 播你當時走的那步 → 接著往下播
  private func resume() {
    guard let h = current else { return }
    let a = attempt
    Task {
      try? await Task.sleep(nanoseconds: 1_600_000_000)
      guard a == attempt else { return }
      show(h.ply.fenBefore, last: nil)
      try? await Task.sleep(nanoseconds: 300_000_000)
      guard a == attempt else { return }
      show(h.ply.fenAfter, last: (h.ply.from, h.ply.to))
      Sounds.play(for: h.ply)
      pos = h.record.ply + 1
      if let done = onSingleDone {
        try? await Task.sleep(nanoseconds: 900_000_000)
        guard a == attempt else { return }
        done()
        return
      }
      next += 1
      run()
    }
  }

  /// 不想等：直接跳到下一個要你走的重點
  func skipAhead() {
    attempt = UUID()
    toast = nil
    notice = nil
    while let x = current, x.record.ply < pos { next += 1 }
    guard let x = current else {
      pos = line.plies.count
      show(line.fen(at: pos), last: nil)
      finish()
      return
    }
    pos = x.record.ply
    show(line.fen(at: pos), last: pos > 0 ? (line.plies[pos - 1].from, line.plies[pos - 1].to) : nil)
    run()
  }
}

/// 快速復盤時的解說區：教練一句話；看完是總結
struct QuickPanel: View {
  let q: QuickReview
  var jump: (Int) -> Void

  var body: some View {
    if q.phase == .done { summary } else { coach }
  }

  private var coach: some View {
    let s = q.say
    return VStack(alignment: .leading, spacing: 8) {
      HStack(spacing: 6) {
        if let x = q.active { Image(systemName: x.kind.icon); Text(x.kind.zh) }
        else if q.noticing { Image(systemName: "exclamationmark.circle.fill"); Text("失誤") }
        else { Image(systemName: "forward.fill"); Text("快速復盤") }
        Spacer()
        HStack(spacing: 4) {
          ForEach(q.highlights) { x in
            Circle().fill(x.kind == .good ? x.kind.color.opacity(x.record.ply < q.pos ? 1 : 0.3)
                          : q.results[x.id].map { $0 ? Color.green : Color.red } ?? Color(.secondarySystemFill))
              .frame(width: 8, height: 8)
          }
        }
      }
      .font(.subheadline.weight(.bold)).foregroundStyle(q.active?.kind.color ?? (q.noticing ? Color(hex: 0xD64545) : Brand.ink))
      HStack(alignment: .top, spacing: 10) {
        Image(ChessAccentAsset.name(s.mood)).resizable().scaledToFit().accessibilityHidden(true).frame(width: 56, height: 56)
        VStack(alignment: .leading, spacing: 4) {
          Text(s.title).font(.headline).foregroundStyle(Brand.ink).fixedSize(horizontal: false, vertical: true)
          if let d = s.detail, !d.isEmpty { Text(d).font(.subheadline).foregroundStyle(Brand.ink.opacity(0.8)).fixedSize(horizontal: false, vertical: true) }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Brand.cream, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
      }
    }
  }

  private var summary: some View {
    VStack(alignment: .leading, spacing: 10) {
      HStack(spacing: 10) {
        Image("accent-rook").resizable().scaledToFit().accessibilityHidden(true).frame(width: 56, height: 56)
        VStack(alignment: .leading, spacing: 2) {
          Text("這局看完了").font(.headline).foregroundStyle(Brand.ink)
          if !q.tried.isEmpty { Text("更好的一步，你找到了 \(q.found)/\(q.tried.count) 個").font(.subheadline).foregroundStyle(q.found == q.tried.count ? .green : Brand.ink) }
        }
      }
      ForEach(q.highlights) { x in
        Button { jump(x.record.ply) } label: {
          HStack(spacing: 8) {
            Image(systemName: x.kind.icon).foregroundStyle(x.kind.color)
            Text("第 \(x.ply.moveNumber) 手・\(x.kind.zh)").font(.subheadline).foregroundStyle(Brand.ink)
            Spacer()
            Text(x.interactive ? (q.results[x.id] == true ? String(localized: "找到了") : String(localized: "答案 \(x.bestSan)")) : x.record.san)
              .font(.caption.weight(.semibold)).foregroundStyle(q.results[x.id] == true ? .green : .secondary)
            Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
          }
          .padding(.horizontal, 12).padding(.vertical, 8)
          .background(Brand.cream, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .buttonStyle(.plain)
      }
      ForEach(q.notices.values.sorted { $0.ply < $1.ply }, id: \.ply) { n in
        Button { jump(n.ply) } label: {
          HStack(spacing: 8) {
            Image(systemName: "eye").foregroundStyle(Brand.teal)
            Text("第 \(q.line.plies[n.ply].moveNumber) 手・\(n.title)").font(.subheadline).foregroundStyle(Brand.ink).lineLimit(1)
            Spacer()
            Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
          }
          .padding(.horizontal, 12).padding(.vertical, 8)
          .background(Brand.cream, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .buttonStyle(.plain)
      }
      if !q.skipped.isEmpty {
        Text("另外 \(q.skipped.count) 步也值得看").font(.subheadline.weight(.semibold)).foregroundStyle(Brand.ink).padding(.top, 4)
        ForEach(q.skipped, id: \.self) { ply in
          Button { jump(ply) } label: {
            HStack(spacing: 8) {
              Text("第 \(q.line.plies[ply].moveNumber) 手").font(.subheadline).foregroundStyle(Brand.ink)
              Text(q.line.plies[ply].mover == q.me ? String(localized: "你 \(q.line.plies[ply].san)") : String(localized: "對手 \(q.line.plies[ply].san)"))
                .font(.subheadline).foregroundStyle(.secondary)
              Spacer()
              Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 12).padding(.vertical, 6)
          }
          .buttonStyle(.plain)
        }
      }
      // 1.1.0 起練習／複習入口已收起：不提複習題庫

    }
  }
}

/// 只看不考的停點（雙方都有）：走完這步停下來，兩行字＋棋盤標示
struct ReviewNotice: Equatable {
  let ply: Int
  let title: String
  let detail: String?
  let mood: String
  /// 畫哪一個局面的引擎最佳步（綠箭頭）；nil 不畫
  let bestFrom: Int?
}

/// 一局快速復盤的停點安排（2026-11-10 grill 定案）
struct ReviewPlan {
  var highlights: [GameHighlight]
  var notices: [Int: ReviewNotice]
  /// 值得講但超過名額、沒停下來的步（總結裡列出、可跳轉）
  var skipped: [Int]
  static let cap = 8, mineQuota = 4, interactiveCap = 4
}

extension GameHighlight {
  private struct Candidate { let ply: Int; let mine: Bool; let score: Double; let good: Bool; let defended: String? }

  /// 停點標準：局勢實質改變（走棋方勝率掉 ≥15 個百分點或逆轉；已贏定／已輸定不算），或有人抓到機會、走出好棋，或你守住對手的威脅
  /// defended：你這一步守住的對手威脅（ply → 對手威脅的那步 SAN），最低優先
  @MainActor static func plan(_ m: ReviewModel, theory: [Int: String] = [:], opening: (title: String, detail: String?)? = nil,
                              defended: [Int: String] = [:]) -> ReviewPlan {
    guard let line = m.line else { return ReviewPlan(highlights: [], notices: [:], skipped: []) }
    let swings = Swing.plies(whiteWins: m.whiteWins, me: m.me)
    let records = m.records
    func drop(_ r: MoveRecord) -> Double { r.winBefore - r.winAfter }
    var candidates: [Candidate] = []
    for r in records.compactMap({ $0 }) {
      let mine = r.mover == m.me, turned = swings.contains(r.ply)
      let decided = (r.winBefore >= 0.9 && r.winAfter >= 0.9) || r.winBefore <= 0.1
      if r.cls.isBad {
        if !decided, drop(r) >= 0.15 || turned { candidates.append(Candidate(ply: r.ply, mine: mine, score: drop(r) + (turned ? 0.3 : 0), good: false, defended: nil)) }
        continue
      }
      let prev = records[safe: r.ply - 1] ?? nil
      let prevDrop = prev.map(drop) ?? 0
      let punished = [.best, .excellent].contains(r.cls) && prev?.cls.isBad == true && prevDrop >= 0.15
      if [.brilliant, .great].contains(r.cls) || punished {
        candidates.append(Candidate(ply: r.ply, mine: mine, score: max(0.2, prevDrop), good: true, defended: nil))
      } else if mine, let threat = defended[r.ply] {
        candidates.append(Candidate(ply: r.ply, mine: true, score: 0.01, good: true, defended: threat))
      }
    }
    // 依影響排序；先保留使用者自己的名額，再依分數補滿；前後 2 步內只留一個（優先使用者的步）
    let sorted = candidates.sorted { $0.score == $1.score ? $0.ply < $1.ply : $0.score > $1.score }
    var picked: [Candidate] = []
    func add(_ c: Candidate) {
      if picked.contains(where: { $0.ply == c.ply }) { return }
      if let i = picked.firstIndex(where: { abs($0.ply - c.ply) <= 2 }) {
        if c.mine && !picked[i].mine { picked[i] = c }
        return
      }
      picked.append(c)
    }
    for c in sorted where c.mine && picked.filter(\.mine).count < ReviewPlan.mineQuota { add(c) }
    for c in sorted where picked.count < ReviewPlan.cap { add(c) }
    let chosen = Set(picked.map(\.ply))
    // 沒停的：超過名額、也沒有併進前後 2 步內某個停點的事件
    let skipped = candidates.map(\.ply).filter { ply in !chosen.contains(where: { abs($0 - ply) <= 2 }) }.sorted()

    var highlights: [GameHighlight] = []
    var notices: [Int: ReviewNotice] = [:]
    let interactive = Set(picked.filter { c in
      c.mine && !c.good
    }.sorted { $0.score > $1.score }.prefix(ReviewPlan.interactiveCap).map(\.ply))
    for c in picked {
      guard let r = records[safe: c.ply] ?? nil, let p = line.plies[safe: c.ply] else { continue }
      if c.mine, !c.good, interactive.contains(c.ply) {
        let before = m.evals[safe: c.ply] ?? nil
        let kind: Kind = r.cls == .miss || before.map { ReviewBuilder.isOpportunity(r, before: $0) } == true ? .missed : .mistake
        if let h = make(m, r, kind: kind), h.interactive { highlights.append(h); continue }
      }
      if c.mine, c.good, var h = make(m, r, kind: .good) {
        if let threat = c.defended {
          h.studyTitle = String(localized: "你守住了：\(p.san)")
          h.studyDetail = String(localized: "對手 \(threat) 製造了威脅，你沒有讓它得逞。")
        }
        highlights.append(h); continue
      }
      notices[c.ply] = notice(m, r, p, turned: swings.contains(c.ply))
    }
    // 對手沒抓住你的失誤：併成一個停點（你那步只看時，停在對手那步一起講；你那步要找答案時，對手那步補一句、不另算名額）
    for c in picked where c.mine && !c.good {
      guard let opp = records[safe: c.ply + 1] ?? nil, opp.cls.isBad || drop(opp) >= 0.15,
            let mine = records[safe: c.ply] ?? nil, let p = line.plies[safe: c.ply + 1] else { continue }
      notices[c.ply] = nil
      notices[c.ply + 1] = ReviewNotice(ply: c.ply + 1,
                                        title: String(localized: "對手 \(p.san)：沒抓到你 \(mine.san) 的漏洞"),
                                        detail: opp.bestSan.map { String(localized: "綠色箭頭是對手可以走的 \($0)") },
                                        mood: "point", bestFrom: c.ply + 1)
    }
    // 長考：只看使用者的步、名額有剩才補
    if highlights.count + notices.count < ReviewPlan.cap {
      let taken = Set(highlights.map(\.id)).union(notices.keys)
      let mine = records.compactMap { $0 }.filter { $0.mover == m.me }
      let times = mine.compactMap { m.thinkTimes[safe: $0.ply] ?? nil }.filter { $0.isFinite && $0 > 0 }.sorted()
      if times.count >= 5 {
        let threshold = max(12, times[times.count / 2] * 3)
        let long = mine.compactMap { r -> (MoveRecord, Double)? in
          guard theory[r.ply] == nil, [.best, .excellent].contains(r.cls), !taken.contains(where: { abs($0 - r.ply) <= 2 }),
                let t = m.thinkTimes[safe: r.ply] ?? nil, t.isFinite, t >= threshold else { return nil }
          return (r, t)
        }.sorted { $0.1 > $1.1 }
        for (r, time) in long {
          guard var h = make(m, r, kind: .study), !h.steps.isEmpty else { continue }
          h.studyTitle = String(localized: "這一步你用了較多時間")
          h.studyDetail = String(localized: "用時 \(Int(time.rounded())) 秒。可以再試一次，看看有哪些選擇。")
          highlights.append(h)
          break
        }
      }
    }
    if let opening, let ply = openingPly(m, theory: theory, taken: Set(highlights.map(\.id)).union(notices.keys)),
       let r = records[safe: ply] ?? nil, var h = make(m, r, kind: .study, practice: false) {
      h.studyTitle = opening.title
      h.studyDetail = opening.detail
      highlights.append(h)
    }
    return ReviewPlan(highlights: highlights.sorted { $0.id < $1.id }, notices: notices, skipped: skipped)
  }

  /// 只看的停點文字：第一行發生什麼，第二行原因或勝率變化
  @MainActor private static func notice(_ m: ReviewModel, _ r: MoveRecord, _ p: Ply, turned: Bool) -> ReviewNotice {
    let mine = r.mover == m.me
    let title: String
    if r.cls.isBad {
      title = turned
        ? (mine ? String(localized: "你 \(p.san)：局勢逆轉") : String(localized: "對手 \(p.san)：局勢逆轉，你的機會來了"))
        : (mine ? String(localized: "你 \(p.san)：\(r.cls.zh)") : String(localized: "對手 \(p.san)：\(r.cls.zh)，你的機會來了"))
    } else {
      title = mine ? String(localized: "你 \(p.san)：\(r.cls.zh)") : String(localized: "對手 \(p.san)：\(r.cls.zh)")
    }
    var detail: String?
    if turned, let b = m.whiteWins[safe: r.ply] ?? nil, let a = m.whiteWins[safe: r.ply + 1] ?? nil {
      detail = String(localized: "你的勝率 \(Swing.percent(b, me: m.me))% → \(Swing.percent(a, me: m.me))%")
    } else if let e = m.explanation(r.ply) {
      detail = ExplainJS.plain(e.headline)
    }
    return ReviewNotice(ply: r.ply, title: title, detail: detail, mood: mine ? (r.cls.isBad ? "sad" : "happy") : "point",
                        bestFrom: r.cls.isBad ? r.ply + 1 : nil)
  }
}
