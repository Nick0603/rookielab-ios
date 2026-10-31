import SwiftUI

/// 重點復盤的一個重點（照 Duolingo Chess 的 Game Review 分三類：好棋、錯失的機會、失誤）
struct GameHighlight: Identifiable {
  enum Kind {
    case good, missed, mistake
    var zh: String { self == .good ? "好棋" : self == .missed ? "錯失的機會" : "失誤" }
    var icon: String { self == .good ? "trophy.fill" : self == .missed ? "exclamationmark.triangle.fill" : "exclamationmark.circle.fill" }
    var color: Color { self == .good ? Color(hex: 0x1BACA6) : self == .missed ? Brand.orange : Color(hex: 0xD64545) }
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
  var id: Int { record.ply }
  var interactive: Bool { kind != .good && !steps.isEmpty }
  var bestSan: String { steps.first?.san ?? record.bestSan ?? "" }

  /// 每局最多幾個重點（Duolingo 一局三個；這裡錯失的機會最多 3、失誤 2、好棋 2，照棋局順序）
  @MainActor static func build(_ m: ReviewModel) -> [GameHighlight] {
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
    return picked.sorted { $0.ply < $1.ply }.compactMap { r in
      make(m, r, kind: r.cls.isBad ? (missed.contains(r) ? .missed : .mistake) : .good)
    }
  }

  /// 單一一步（逐步復盤按「重走一下」）：錯失良機或當時有勝勢的算機會，其他算失誤
  @MainActor static func single(_ m: ReviewModel, ply: Int) -> GameHighlight? {
    guard let r = m.records[safe: ply] ?? nil, r.cls.isBad else { return nil }
    let before = m.evals[safe: ply] ?? nil
    let chance = r.cls == .miss || before.map { ReviewBuilder.isOpportunity(r, before: $0) } == true
    return make(m, r, kind: chance ? .missed : .mistake)
  }

  @MainActor private static func make(_ m: ReviewModel, _ r: MoveRecord, kind: Kind) -> GameHighlight? {
      guard let line = m.line, let p = line.plies[safe: r.ply] else { return nil }
      let e = m.explanation(r.ply)
      let before = m.evals[safe: r.ply] ?? nil
      let accept = (before ?? []).indices.filter { Difficulty.winGap(before!, index: $0) <= 3 }.compactMap { before![$0].best }
      var h = GameHighlight(kind: kind, record: r, ply: p, explanation: e, steps: kind == .good ? [] : steps(e, pv: before?.first?.pv ?? [], fen: p.fenBefore), accept: accept)
      h.headline = e?.headline
      h.reason = h.steps.first.flatMap { $0.caption.isEmpty ? nil : $0.caption } ?? e?.plainReasons.first
      let pun = r.cls == .best || r.cls == .excellent
      h.praise = pun ? "抓到了！對手剛走錯，你用 \(r.san) 抓住了機會" : "好棋！\(r.san)"
      if kind == .good { h.reason = e?.plainReasons.first ?? e?.headline }
      let names = ["K": "王", "Q": "后", "R": "車", "B": "象", "N": "馬", "P": "兵"]
      if let u = h.steps.first?.uci, let code = FEN.pieces(p.fenBefore)[String(u.prefix(2))] {
        h.hint = "提示：動 \(u.prefix(2)) 的\(names[String(code.last!)] ?? "子")"
      }
      return h
  }

  /// 錯失的是哪一類機會：「錯過捉雙」→「捉雙」、「錯過白吃的馬」→「白吃的馬」、「錯過得子的機會」→「得子」
  var chanceType: String? {
    guard kind == .missed, let h = headline, h.hasPrefix("錯過") else { return nil }
    var t = String(h.dropFirst(2))
    if t.hasSuffix("的機會") { t.removeLast(3) }
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
  enum Phase { case playing, praise, trying, solved, revealed, done }
  let line: ChessLine
  let highlights: [GameHighlight]
  let me: Side
  /// 每一步先算好的：評級、走完的分數（你的角度）、分數變化
  struct Note { let cls: MoveClass; let score: String; let delta: String?; let tag: String }
  let notes: [Note?]
  /// 每個局面白方的勝率（評分條）
  let whiteWins: [Double?]
  private let evals: [[EngineLine]?]
  /// 走錯時對手的懲罰：（對手走的、那步做了什麼、走完的分數）
  private(set) var refute: (san: String, tag: String, score: String?)?
  private(set) var phase: Phase = .playing
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
  static let pause: UInt64 = 1_300_000_000

  private let resignedGame: Bool

  init(line: ChessLine, highlights: [GameHighlight], me: Side, records: [MoveRecord?], evals: [[EngineLine]?], whiteWins: [Double?], tags: [String], resigned: Bool = false) {
    resignedGame = resigned
    self.line = line; self.highlights = highlights; self.me = me; self.whiteWins = whiteWins; self.evals = evals
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
  var tried: [GameHighlight] { highlights.filter(\.interactive) }
  var found: Int { tried.filter { results[$0.id] == true }.count }
  /// 停著的重點（找步中、剛播到的好棋）
  var active: GameHighlight? { toast ?? ([.playing, .done].contains(phase) || notice != nil ? nil : current) }
  /// 停在失誤上（標題用）
  var noticing: Bool { notice != nil }
  var canMove: Bool { phase == .trying && !busy }

  var arrows: [Arrow] {
    // 停在失誤上：這步從哪走到哪（紅），以及接下來最好的一步（你的失誤＝對手的懲罰，橘；對手的失誤＝你的機會，綠）
    if let k = notice {
      let p = line.plies[k]
      var out = [arrow(p.uci, Color.red.opacity(0.85))]
      if let u = (evals[safe: k + 1] ?? nil)?.first?.best { out.append(arrow(u, p.mover == me ? Brand.orange : Brand.bestArrow)) }
      return out
    }
    guard phase == .revealed || phase == .solved, alt == nil, let u = current?.steps.first?.uci else { return [] }
    return [Arrow(from: String(u.prefix(2)), to: String(u.dropFirst(2).prefix(2)), color: Brand.bestArrow)]
  }
  private func arrow(_ u: String, _ c: Color) -> Arrow { Arrow(from: String(u.prefix(2)), to: String(u.dropFirst(2).prefix(2)), color: c) }

  var squares: [String] { last.map { [$0.from, $0.to] } ?? [] }
  /// 提示要動的那顆子
  var pulse: String? { phase == .trying && hint ? current?.steps.first.map { String($0.uci.prefix(2)) } : nil }
  /// 看完了、而且是對手投降：棋盤上舉白旗
  var resigned = false

  /// 教練這時候說的話：（表情、標題、一句說明）—都是先算好的字串
  var say: (mood: String, title: String, detail: String?) {
    if let k = notice, let n = notes[safe: k] ?? nil {
      let p = line.plies[k], mine = p.mover == me
      return (mine ? "sad" : "point", mine ? "你 \(p.san)：\(n.cls.zh)" : "對手 \(p.san)：\(n.cls.zh)，你的機會來了",
              "\(n.tag)・分數 \(n.score)" + (n.delta.map { "（\($0)）" } ?? "") + (mine ? "\n橘色箭頭是對手接下來的好棋" : "\n綠色箭頭是你可以抓的機會"))
    }
    if let t = toast {
      let n = notes[safe: t.record.ply] ?? nil
      let change = n.map { "\($0.tag)・分數 \($0.score)" + ($0.delta.map { "（\($0)）" } ?? "") }
      return ("happy", t.praise ?? "好棋！", [t.reason, change].compactMap { $0 }.joined(separator: "\n"))
    }
    if phase == .playing {
      guard let l = lastNote else { return ("think", "快速播放中…", "停在重點分析") }
      let who = l.ply.mover == me ? "你" : "對手"
      return (l.ply.mover == me && l.note.cls.isBad ? "sad" : "think", "\(who) \(l.ply.san)：\(l.note.tag)",
              "\(l.note.cls.zh)・分數 \(l.note.score)" + (l.note.delta.map { "（\($0)）" } ?? ""))
    }
    guard let h = current, phase != .done else { return ("cheer", "這局看完了", nil) }
    switch phase {
    case .playing, .praise, .done: return ("cheer", "這局看完了", nil)
    case .trying:
      if wrongs > 0 {
        if let r = refute {
          return ("sad", "不是這步：對手會走 \(r.san)", "\(r.tag)" + (r.score.map { "・分數變成 \($0)" } ?? "") + (busy ? "" : "。再試一次") + (hint ? "\n\(h.hint)" : ""))
        }
        return ("sad", busy ? "看看對手會怎麼走…" : "不是這步，再想想", hint ? h.hint : nil)
      }
      let prev = pos > 0 ? "對手剛走了 \(line.plies[pos - 1].san)" : nil
      let lead = h.chanceType.map { "這裡有個「\($0)」的機會！" } ?? (h.kind == .missed ? "這裡有個機會！" : "這一步要小心。")
      return ("think", lead + "找出最好的一步",
              hint ? h.hint : [prev, h.headline].compactMap { $0 }.joined(separator: "・"))
    case .solved: return ("cheer", alt.map { "\($0) 也可以！" } ?? "就是這步！\(h.bestSan)", h.reason)
    case .revealed: return ("point", "更好的一步是 \(h.bestSan)", h.reason)
    }
  }

  // MARK: 流程

  func start() {
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
          phase = .trying
          return
        }
        let p = line.plies[pos]
        try? await Task.sleep(nanoseconds: Self.gap)
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
        if let n = notes[safe: p.index] ?? nil, n.cls.isBad {
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
    Telemetry.log("quick_review_done", ["found": found, "tried": tried.count, "highlights": highlights.count])
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
    while let x = current, !x.interactive || x.record.ply < pos { next += 1 }
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
        Image("coach-\(s.mood)").resizable().scaledToFit().frame(width: 56, height: 56)
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
        Image(q.found == q.tried.count ? "coach-cheer" : "coach-happy").resizable().scaledToFit().frame(width: 56, height: 56)
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
            Text(x.interactive ? (q.results[x.id] == true ? "找到了" : "答案 \(x.bestSan)") : x.record.san)
              .font(.caption.weight(.semibold)).foregroundStyle(q.results[x.id] == true ? .green : .secondary)
            Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
          }
          .padding(.horizontal, 12).padding(.vertical, 8)
          .background(Brand.cream, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .buttonStyle(.plain)
      }
      if q.found < q.tried.count, AutoAnalyzer.autoAdd {
        Text("錯失的機會已經放進複習題庫，過幾天會再練一次").font(.footnote).foregroundStyle(.secondary)
      }
    }
  }
}
