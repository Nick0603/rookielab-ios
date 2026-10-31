import Foundation
import Observation
import SwiftUI

/// 單局復盤的狀態：解析棋局 → 逐步跑引擎（每個局面一次，前兩名）→ 每一手的評級、準確率、最佳步與第二選擇。
/// 評級規則與網站相同（Grading）。分析是一步一步填進來的，畫面不用等全部算完。
@MainActor @Observable
final class ReviewModel {
  let game: GameSummary
  let line: ChessLine?
  private(set) var records: [MoveRecord?]
  private(set) var evals: [[EngineLine]?]
  private(set) var progress = 0.0
  private(set) var status: String = "準備中…"
  var current = 0 {
    didSet {
      guard current != oldValue, !following else { return }
      Haptics.tick()
      Sounds.play(for: current > 0 ? line?.plies[current - 1] : nil, forward: current == oldValue + 1)
    }
  }
  /// 分析中：棋盤跟著引擎的進度往前走，評級一步步跳出來（像 chess.com 的分析動畫），使用者一碰就停
  private(set) var following = false
  /// 剛分析完的提示（關鍵步幾個）
  var doneToast: String?
  /// 剛分析完：這局最該記住的一件事、加進複習的題數
  var lesson: Lesson?
  private(set) var added = 0

  func stopFollowing() { following = false; pacer?.cancel() }

  /// 分析到第幾個局面了（跟著播不會超過它）
  private var analyzed = 0
  private var pacer: Task<Void, Never>?

  /// 分析中跟著播：每 0.25 秒走一步，追著分析的進度，不會超過
  private func startFollowPacer() {
    pacer?.cancel()
    pacer = Task { [weak self] in
      while let self, self.following, !Task.isCancelled {
        try? await Task.sleep(nanoseconds: 250_000_000)
        guard self.following else { return }
        if self.current < min(self.analyzed, self.count) {
          withAnimation(.easeInOut(duration: 0.18)) { self.current += 1 }
        }
      }
    }
  }
  var playing = false
  private var playTask: Task<Void, Never>?
  private var analyzeTask: Task<Void, Never>?

  var me: Side { game.color }

  /// 三種看法：快速重點（快速播、只停關鍵步）、逐步分析（每步標好壞、關鍵步停）、自由分析（自己按下一步，可以在棋盤上走自己的延伸）
  enum Mode: String, CaseIterable, Identifiable {
    case quick, step, free
    var id: String { rawValue }
    var zh: String { self == .quick ? "快速重點" : self == .step ? "逐步分析" : "自由分析" }
    /// 自動播放每一手隔多久
    var interval: UInt64 { self == .quick ? 350_000_000 : 1_100_000_000 }
  }

  var mode: Mode = .step { didSet { if mode != oldValue { playing = false; playTask?.cancel() } } }
  /// 每一手想了幾秒（棋譜沒有時鐘紀錄就是 nil）
  let thinkTimes: [Double?]
  /// 每一手走完剩幾秒
  let clockLeft: [Double?]

  /// 某一方在目前這一步時剩幾秒（玩家列顯示）
  func clock(of side: Side, at pos: Int? = nil) -> Double? {
    guard let line else { return nil }
    if let i = (0..<min(pos ?? current, line.plies.count)).last(where: { line.plies[$0].mover == side }) { return clockLeft[i] }
    return game.timeControl.contains("/") ? nil : game.timeControl.split(separator: "+").first.flatMap { Double($0) }
  }
  /// 自由分析時，延伸局面的引擎前幾名
  private(set) var freeLines: [EngineLine] = []
  private var freeTask: Task<Void, Never>?
  var count: Int { line?.plies.count ?? 0 }

  /// 打開一局要先做的重活（解析棋譜、讀分析存檔、照現在的規則重評）：在背景執行緒做，畫面先放載入動畫
  struct Prepared {
    let line: ChessLine?
    let thinkTimes: [Double?]
    let clockLeft: [Double?]
    let analysis: AnalyzedGame?
  }

  nonisolated static func prepare(_ game: GameSummary) -> Prepared {
    let line = ChessLine(pgn: game.pgn)
    let n = line?.plies.count ?? 0
    let t = ChessLine.thinkTimes(pgn: game.pgn, timeControl: game.timeControl)
    let c = ChessLine.moveTokens(game.pgn).map(\.clock)
    var a: AnalyzedGame?
    if let line, let raw = AnalysisStore.load(game.id), raw.evals.count == n + 1 { a = AnalysisStore.regraded(raw, line: line) }
    return Prepared(line: line, thinkTimes: t.count == n ? t : Array(repeating: nil, count: n),
                    clockLeft: c.count == n ? c : Array(repeating: nil, count: n), analysis: a)
  }

  convenience init(game: GameSummary, startAt: Int = 0) {
    self.init(game: game, prepared: Self.prepare(game), startAt: startAt)
  }

  init(game: GameSummary, prepared p: Prepared, startAt: Int = 0) {
    self.game = game
    line = p.line
    let n = line?.plies.count ?? 0
    thinkTimes = p.thinkTimes
    clockLeft = p.clockLeft
    records = Array(repeating: nil, count: n)
    evals = Array(repeating: nil, count: n + 1)
    current = min(startAt, n)
    if let a = p.analysis {
      evals = a.evals
      records = a.records
      progress = 1
      status = ""
    }
  }

  // MARK: 分析

  func start() {
    guard analyzeTask == nil, let line, !status.isEmpty else { return }
    analyzeTask = Task { [weak self] in
      guard let self else { return }
      do {
        if !StockfishService.netsReady { self.status = "第一次使用：下載引擎評估檔（約 80MB）…" }
        try await StockfishService.shared.start()
      } catch {
        self.status = "引擎啟動失敗，請檢查網路後重試"
        return
      }
      let n = line.plies.count
      // 先全部分析完再開始復盤（畫面上是載入動畫），不再邊分析邊播
      self.following = false
      let began = Date()
      self.analyzed = 0
      _ = await AnalysisStore.analyze(self.game, line: line, priority: .interactive) { [weak self] k, e, r in
        guard let self else { return }
        self.evals = e
        self.records = r
        self.progress = Double(k) / Double(max(n, 1))
        self.status = k < n ? "分析中 \(k)/\(n)" : ""
        // 跟著播用固定節奏（followPacer），不跟分析的速度：分析快的地方不會一下跳好幾步、精算時也不會停住
        self.analyzed = max(self.analyzed, k)
      }
      self.status = ""
      Telemetry.log("game_analyzed", ["plies": n, "seconds": Int(Date().timeIntervalSince(began).rounded()), "platform": self.game.platform.rawValue])
      if self.following {
        self.following = false
        self.pacer?.cancel()
        self.current = 0
      }
      // 剛分析完：記一筆、失誤加進複習、跳出「這局最該記住的一件事」
      if let a = AnalysisStore.load(self.game.id), let d = GameDigest(game: self.game, line: line, analysis: a) {
        self.added = AutoAnalyzer.shared.record(d)
        self.lesson = Lesson(d)
        // 分析完直接停在「一件事」那一步，不跳回開頭
        if let l = self.lesson { self.current = l.ply + 1 }
        Notifier.reschedule()
      }
      self.prewarm()
    }
  }

  func stop() { analyzeTask?.cancel(); playTask?.cancel(); prewarmTask?.cancel() }

  private var prewarmTask: Task<Void, Never>?

  /// 分析完先把關鍵步的解說算好存起來，點開不用等
  func prewarm() {
    guard prewarmTask == nil else { return }
    prewarmTask = Task { [weak self] in await self?.warmExplanations() }
  }

  /// 畫面上會顯示解說的步（雙方的關鍵步、不精確）全部先算好：滑棋譜、播放時不用當場算。
  /// 一次算一個就讓出主執行緒，載入動畫不會停
  func warmExplanations() async {
    guard let line else { return }
    for r in records.compactMap({ $0 }) where r.cls.isKey || r.cls == .inaccuracy {
      if Task.isCancelled { return }
      _ = ExplainJS.explain(key: key(r.ply), record: r, ply: line.plies[r.ply], before: evals[r.ply] ?? nil, after: evals[r.ply + 1] ?? nil, opponent: r.mover != me)
      await Task.yield()
    }
  }

  func key(_ ply: Int) -> String { "\(game.id)-\(ply)" }

  /// 這一手的白話解說（網站的 explainMove）
  func explanation(_ ply: Int) -> ExplainJS.Explanation? {
    guard let line, let r = records[safe: ply] ?? nil else { return nil }
    return ExplainJS.explain(key: key(ply), record: r, ply: line.plies[ply], before: evals[ply] ?? nil, after: evals[safe: ply + 1] ?? nil, opponent: r.mover != me)
  }

  // MARK: 統計

  func accuracy(of side: Side) -> Double? {
    let xs = records.compactMap { $0 }.filter { $0.mover == side }.map(\.accuracy)
    return xs.isEmpty ? nil : Grading.gameAccuracy(xs)
  }

  func counts(of side: Side) -> [(MoveClass, Int)] {
    let rs = records.compactMap { $0 }.filter { $0.mover == side }
    return MoveClass.allCases.compactMap { c in let n = rs.filter { $0.cls == c }.count; return n > 0 ? (c, n) : nil }
  }

  /// 關鍵步：我方的好棋與失誤，加上對手的失誤
  var keyMoves: [MoveRecord] {
    records.compactMap { $0 }.filter { $0.mover == me ? $0.cls.isKey : $0.cls.isBad }
  }

  /// 每個局面白方的勝率（分數走勢用），還沒算到的是 nil
  var whiteWins: [Double?] {
    guard let line else { return [] }
    return evals.indices.map { k in
      guard let e = evals[k]?.first else { return k > 0 && line.plies[k - 1].isCheckmate ? (line.plies[k - 1].mover == .white ? 1 : 0) : nil }
      let w = Grading.winProb(e)
      return FEN.sideToMove(line.fen(at: k)) == .white ? w : 1 - w
    }
  }

  /// 白方視角的勝率（評分條）
  var whiteWin: Double {
    guard let e = evals[current]?.first, let line else { return 0.5 }
    let side = FEN.sideToMove(line.fen(at: current))
    let w = Grading.winProb(e)
    return side == .white ? w : 1 - w
  }

  var evalText: String {
    guard let e = evals[current]?.first, let line else { return "…" }
    let k = FEN.sideToMove(line.fen(at: current)) == .white ? 1 : -1
    return Grading.evalText(cp: e.cp.map { $0 * k }, mate: e.mate.map { $0 * k })
  }

  // MARK: 延伸棋局

  struct Variation {
    let option: LineOption
    var cursor = 0
    var fen: String { cursor == 0 ? option.startFen : option.plies[cursor - 1].fenAfter }
    var last: Ply? { cursor > 0 ? option.plies[cursor - 1] : nil }
  }

  private(set) var variation: Variation?

  /// 開始看一條延伸：從起點自動一步一步播
  func open(_ o: LineOption) {
    go(o.base)
    variation = Variation(option: o)
    playVariation()
  }

  func closeVariation() {
    playTask?.cancel()
    playing = false
    variation = nil
    refreshFreeLines()
  }

  func stepVariation(_ d: Int) {
    guard var v = variation else { return }
    playing = false
    playTask?.cancel()
    let n = min(max(0, v.cursor + d), v.option.plies.count)
    guard n != v.cursor else { return }
    let forward = n == v.cursor + 1
    v.cursor = n
    variation = v
    Haptics.tick()
    Sounds.play(for: v.last, forward: forward)
    refreshFreeLines()
  }

  func playVariation() {
    guard variation != nil else { return }
    playing = true
    playTask?.cancel()
    playTask = Task { [weak self] in
      try? await Task.sleep(nanoseconds: 500_000_000)
      while let self, self.playing, var v = self.variation, v.cursor < v.option.plies.count {
        v.cursor += 1
        self.variation = v
        Haptics.tick()
        Sounds.play(for: v.last)
        try? await Task.sleep(nanoseconds: 850_000_000)
      }
      self?.playing = false
    }
  }

  // MARK: 比較候選步（取代以前的長延伸）：你走的、最佳的、也不錯的，各只走一兩步，說會怎樣

  struct Candidate: Identifiable {
    enum Kind { case played, best, alt }
    let kind: Kind
    let option: LineOption
    /// 這步走完局面怎樣（白話）
    let verdict: String
    var id: String { option.id }
    var uci: String { option.plies.first?.uci ?? "" }
    var san: String { option.plies.first?.san ?? "" }
  }
  struct Compare { let ply: Int; let candidates: [Candidate]; let why: String?; var selected: String? }
  private(set) var compare: Compare?

  /// 最多走幾步（你走一步、對手接一步）：再多就看不出是不是只有這種情況
  static let compareDepth = 2

  /// 打開比較：棋盤回到走這一手之前，畫出幾個候選步
  func openCompare(_ ply: Int) {
    guard let line, let r = records[safe: ply] ?? nil else { return }
    let p = line.plies[ply]
    let before = evals[safe: ply] ?? nil
    let e = explanation(ply)
    func trim(_ o: LineOption, id: String, title: String) -> LineOption {
      LineOption(id: id, title: title, source: .engine, startFen: p.fenBefore, base: ply, plies: Array(o.plies.prefix(Self.compareDepth)),
                 captions: o.captions.map { Array($0.prefix(Self.compareDepth)) })
    }
    func engine(_ l: EngineLine?, id: String, title: String) -> LineOption? {
      guard let l else { return nil }
      var f = p.fenBefore, out: [Ply] = []
      for u in l.pv.prefix(Self.compareDepth) { guard let x = ChessLine.ply(fen: f, uci: u, index: out.count) else { break }; out.append(x); f = x.fenAfter }
      return out.isEmpty ? nil : LineOption(id: id, title: title, source: .engine, startFen: p.fenBefore, base: ply, plies: out)
    }
    let js = Dictionary((e?.lines ?? []).compactMap { l in LineOption(l, base: ply).map { (l.kind, $0) } }, uniquingKeysWith: { a, _ in a })
    var out: [Candidate] = []
    let bestLine = before?.first
    if let o = js["best"].map({ trim($0, id: "best", title: "最佳") }) ?? engine(bestLine, id: "best", title: "最佳") {
      out.append(Candidate(kind: .best, option: o, verdict: "走完局面\(Grading.standing(Grading.winProb(bestLine)))"))
    }
    if let alt = before.flatMap({ Grading.secondChoice($0) }), alt.best != r.uci, let o = engine(alt, id: "alt", title: "也不錯") {
      out.append(Candidate(kind: .alt, option: o, verdict: "跟最佳差不多：走完局面\(Grading.standing(Grading.winProb(alt)))"))
    }
    if r.uci != bestLine?.best {
      let after = evals[safe: ply + 1] ?? nil
      let o = js["played"].map { trim($0, id: "played", title: "你走的") }
        ?? LineOption(id: "played", title: "你走的", source: .engine, startFen: p.fenBefore, base: ply,
                      plies: [p] + (after?.first?.best.flatMap { ChessLine.ply(fen: p.fenAfter, uci: $0, index: 1) }.map { [$0] } ?? []))
      out.insert(Candidate(kind: .played, option: o, verdict: "走完局面\(Grading.standing(r.winAfter))"), at: 0)
    }
    playing = false; playTask?.cancel(); variation = nil
    current = ply
    // 為什麼選最佳：你走的哪裡不好（網站解說的標題），改走最佳會怎樣（最佳線的結論）
    let why: String? = out.first(where: { $0.kind == .best }).map { b in
      let bad = r.uci == bestLine?.best ? nil : e?.headline
      let good = js["best"]?.outcome.flatMap { $0.isEmpty ? nil : $0 }
      return [bad, "改走 \(b.san)" + (good.map { "：\($0)" } ?? "")].compactMap { $0 }.joined(separator: "。")
    }
    compare = Compare(ply: ply, candidates: out, why: why)
  }

  /// 在棋盤上走這個候選步（一兩步）
  func pickCandidate(_ c: Candidate) {
    compare?.selected = c.id
    variation = Variation(option: c.option)
    playVariation()
  }

  /// 回到這一手（走完這一手之後的局面），繼續看對局
  func closeCompare() {
    guard let c = compare else { return }
    playTask?.cancel(); playing = false
    variation = nil
    compare = nil
    current = min(c.ply + 1, count)
    refreshFreeLines()
  }

  // MARK: 自由分析：在棋盤上自己走

  /// 現在看的局面（延伸中就是延伸的那一步）
  var shownFen: String { variation?.fen ?? line?.fen(at: current) ?? "" }

  /// 自由分析：從目前的局面自己走一步，變成（或接上）一條自己的延伸
  func freeMove(_ from: String, _ to: String, promotion: String = "") {
    let uci = from + to + promotion
    let base: (start: String, at: Int, plies: [Ply])
    if let v = variation, v.option.source == .manual || v.cursor > 0 {
      base = (v.option.startFen, v.option.base, Array(v.option.plies.prefix(v.cursor)))
    } else {
      base = (shownFen, current, [])
    }
    let f = base.plies.last?.fenAfter ?? base.start
    guard let p = ChessLine.ply(fen: f, uci: uci, index: base.plies.count) else { return }
    // 剛好走了對局裡的下一步：直接往下一步，不開延伸
    if variation == nil, let next = line?.plies[safe: current], next.uci == uci { go(current + 1); Sounds.play(for: next); return }
    let plies = base.plies + [p]
    let o = LineOption(id: "free", title: "自己走的延伸", source: .manual, startFen: base.start, base: base.at, plies: plies)
    playTask?.cancel()
    playing = false
    if variation == nil { current = base.at }
    variation = Variation(option: o, cursor: plies.count)
    Haptics.tick()
    Sounds.play(for: p)
    refreshFreeLines()
  }

  func freeTargets(_ from: String) -> [String] { FEN.targets(fen: shownFen, from: from) }

  /// 延伸裡的局面沒有現成的分析：另外算前三名（候選步用）
  func refreshFreeLines() {
    freeTask?.cancel()
    guard mode == .free else { return }
    let f = shownFen
    if variation == nil, let e = evals[safe: current] ?? nil { freeLines = e; return }
    freeLines = []
    freeTask = Task { [weak self] in
      await StockfishService.shared.stopInteractive()
      let out = await StockfishService.shared.analyse(fen: f, nodes: 300_000, multipv: 3, priority: .interactive)
      guard let self, !Task.isCancelled, self.shownFen == f else { return }
      self.freeLines = out
    }
  }

  // MARK: 播放

  func go(_ n: Int) { following = false; playing = false; playTask?.cancel(); variation = nil; compare = nil; current = min(max(0, n), count); refreshFreeLines() }

  /// 你自己的失誤（「下一個關鍵步」只跳這些，好棋與對手的失誤看關鍵步清單）
  var myMistakes: [MoveRecord] { records.compactMap { $0 }.filter { $0.mover == me && $0.cls.isBad } }

  func nextKey() {
    if let k = myMistakes.first(where: { $0.ply + 1 > current }) ?? keyMoves.first(where: { $0.ply + 1 > current }) { go(k.ply + 1) }
  }

  func prevKey() {
    if let k = myMistakes.last(where: { $0.ply + 1 < current }) ?? keyMoves.last(where: { $0.ply + 1 < current }) { go(k.ply + 1) }
  }

  /// 自動播放：每手 1.1 秒，遇到關鍵步停下來
  func togglePlay() {
    following = false
    if playing { playing = false; playTask?.cancel(); return }
    if current >= count { current = 0 }
    playing = true
    playTask = Task { [weak self] in
      while let self, self.playing, self.current < self.count {
        try? await Task.sleep(nanoseconds: self.mode.interval)
        guard self.playing else { return }
        self.current += 1
        if let r = self.records[self.current - 1], r.mover == self.me ? r.cls.isKey : r.cls.isBad { self.playing = false }
      }
      self?.playing = false
    }
  }
}

extension Array {
  subscript(safe i: Int) -> Element? { indices.contains(i) ? self[i] : nil }
}
