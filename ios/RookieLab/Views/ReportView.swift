import Charts
import SwiftUI

/// 一局的摘要（跨局報告用）
struct GameDigest: Identifiable {
  let game: GameSummary
  let line: ChessLine
  let analysis: AnalyzedGame
  let accuracy: Double
  let counts: [MoveClass: Int]
  let phases: [Grading.Phase: (moves: Int, errors: Int, accuracy: [Double])]
  let lossReason: LossReason?
  let mistakes: [MoveRecord]
  var id: String { game.id }

  enum LossReason: String, CaseIterable {
    case threwWinning, opening, timeout, outplayed
    var zh: String {
      switch self {
      case .threwWinning: "曾經大優，優勢沒守住"
      case .opening: "開局就落後，沒追回來"
      case .timeout: "超時"
      case .outplayed: "一路被壓著打"
      }
    }
  }

  /// 輸法規則與網站 lossReason.ts 一致：大優後又失誤 > 開局就落後 > 超時 > 曾經大優 > 被壓著打
  init?(game: GameSummary, line: ChessLine, analysis a: AnalyzedGame) {
    let mine = a.records.compactMap { $0 }.filter { $0.mover == game.color }
    guard !mine.isEmpty else { return nil }
    self.game = game
    self.line = line
    analysis = a
    accuracy = Grading.gameAccuracy(mine.map(\.accuracy))
    counts = Dictionary(grouping: mine, by: \.cls).mapValues(\.count)
    var ph: [Grading.Phase: (moves: Int, errors: Int, accuracy: [Double])] = [:]
    for r in mine {
      let p = line.plies[r.ply]
      let k = Grading.phase(moveNumber: p.moveNumber, fen: p.fenBefore)
      var x = ph[k] ?? (0, 0, [])
      x.moves += 1
      if r.cls.isBad { x.errors += 1 }
      x.accuracy.append(r.accuracy)
      ph[k] = x
    }
    phases = ph
    mistakes = mine.filter(\.cls.isBad)
    if game.result == .loss {
      let win = mine.map(\.winAfter)
      let peak = win.max() ?? 0
      let peakAt = win.firstIndex(of: peak) ?? 0
      let blunderAfterPeak = mine.dropFirst(peakAt + 1).contains { $0.cls.isBad }
      let at = min(12, win.count) - 1
      let openingLost = at >= 0 && win[at] <= 0.25 && (win[at...].max() ?? 0) < 0.5
      lossReason = peak >= 0.85 && blunderAfterPeak ? .threwWinning
        : openingLost ? .opening
        : game.lostOnTime ? .timeout
        : peak >= 0.85 ? .threwWinning : .outplayed
    } else {
      lossReason = nil
    }
  }
}

/// 跨局報告：同一種時間制的最近 N 局，逐局用引擎分析（已分析過的直接讀存檔），算完一局就更新
@MainActor @Observable
final class ReportModel {
  var typeKey: String?
  var count = 10
  private(set) var digests: [GameDigest] = []
  /// 網站的規則分析（只看棋譜，馬上有）與引擎彙整（分析完一局就更新）
  private(set) var quick: ReportJS.Quick?
  private(set) var prescription: ReportJS.Prescription?
  private(set) var deep: ReportJS.Deep?
  private(set) var done = 0
  private(set) var total = 0
  private(set) var running = false
  private var task: Task<Void, Never>?
  private var runKey = ""

  func games(from all: [GameSummary]) -> [GameSummary] {
    guard let k = typeKey ?? GameType.pick(all) else { return [] }
    return Array(all.filter { GameType.key($0) == k }.prefix(count))
  }

  func run(_ all: [GameSummary]) {
    let list = games(from: all)
    // 只看棋譜的部分用這種時間類型最近 50 局（比引擎分析的局多，數字比較穩）
    if let k = typeKey ?? GameType.pick(all) {
      let typed = Array(all.filter { GameType.key($0) == k }.prefix(50))
      Task { [weak self] in
        let q = await ReportJS.quick(typed)
        let p = await typed.first?.myRating.asyncMap { await ReportJS.prescription(typed, rating: $0) } ?? nil
        self?.quick = q
        self?.prescription = p
      }
    }
    let key = list.map(\.id).joined(separator: ",")
    guard key != runKey else { return }
    runKey = key
    task?.cancel()
    digests = []
    deep = nil
    reviewCards = []
    done = 0
    total = list.count
    running = true
    task = Task { [weak self] in
      try? await StockfishService.shared.start()
      for g in list {
        guard !Task.isCancelled else { return }
        let fresh = AnalysisStore.load(g.id) == nil
        guard let line = ChessLine(pgn: g.pgn), let a = await AnalysisStore.analyze(g, line: line) else { continue }
        guard let self, !Task.isCancelled else { return }
        if let d = GameDigest(game: g, line: line, analysis: a) {
          self.digests.append(d)
          self.reviewCards += ReviewBuilder.cards(d)
          if fresh { _ = AutoAnalyzer.shared.record(d) }
        }
        self.done += 1
      }
      // 全部分析完才算一次彙整，然後整頁一次出來（分析中是載入畫面）
      guard let self, !Task.isCancelled else { return }
      self.deep = await ReportJS.deep(self.digests)
      self.running = false
      Telemetry.log("report_done", ["games": self.digests.count])
    }
  }

  func stop() { task?.cancel(); running = false; runKey = "" }

  // MARK: 彙總

  /// 曾經大優卻沒贏的局
  var reversals: [Reversal] { digests.compactMap(ReviewBuilder.reversal) }

  /// 這幾局可以加進複習的卡（我走壞的步）：分析完一局就算一次，不要每次畫面更新都重算
  private(set) var reviewCards: [ReviewCard] = []

  var wins: Int { digests.filter { $0.game.result == .win }.count }
  var losses: Int { digests.filter { $0.game.result == .loss }.count }
  var draws: Int { digests.count - wins - losses }
  var avgAccuracy: Double? { digests.isEmpty ? nil : digests.map(\.accuracy).reduce(0, +) / Double(digests.count) }

  func side(_ s: Side) -> (games: Int, score: Double, accuracy: Double)? {
    let ds = digests.filter { $0.game.color == s }
    guard !ds.isEmpty else { return nil }
    return (ds.count, Self.score(ds), ds.map(\.accuracy).reduce(0, +) / Double(ds.count))
  }

  struct PhaseRow: Identifiable { let phase: Grading.Phase; let moves: Int; let per100: Double; let accuracy: Double; var id: String { phase.rawValue } }

  var phaseRows: [PhaseRow] {
    Grading.Phase.allCases.compactMap { p in
      let xs = digests.compactMap { $0.phases[p] }
      let moves = xs.reduce(0) { $0 + $1.moves }
      guard moves >= 5 else { return nil }
      let errors = xs.reduce(0) { $0 + $1.errors }
      let acc = xs.flatMap(\.accuracy)
      return PhaseRow(phase: p, moves: moves, per100: (Double(errors) / Double(moves) * 1000).rounded() / 10, accuracy: Grading.gameAccuracy(acc))
    }
  }

  var lossRows: [(GameDigest.LossReason, Int)] {
    GameDigest.LossReason.allCases.compactMap { r in
      let n = digests.filter { $0.lossReason == r }.count
      return n > 0 ? (r, n) : nil
    }
  }

  struct OpeningRow: Identifiable { let name: String; let games: Int; let score: Double; let accuracy: Double; var id: String { name } }

  private static func score(_ ds: [GameDigest]) -> Double {
    var sum = 0.0
    for d in ds { sum += d.game.result == .win ? 1 : d.game.result == .draw ? 0.5 : 0 }
    return ds.isEmpty ? 0 : sum / Double(ds.count)
  }

  var openingRows: [OpeningRow] {
    let groups = Dictionary(grouping: digests) { (d: GameDigest) in Openings.family(d.game.openingRaw) }
    var rows: [OpeningRow] = []
    for (name, ds) in groups {
      let acc = ds.map(\.accuracy).reduce(0, +) / Double(ds.count)
      rows.append(OpeningRow(name: name, games: ds.count, score: Self.score(ds), accuracy: acc))
    }
    return rows.sorted { $0.games > $1.games }
  }

  /// 勝率掉最多的失誤（跨局）
  var worstMistakes: [(GameDigest, MoveRecord)] {
    digests.flatMap { d in d.mistakes.map { (d, $0) } }
      .sorted { ($0.1.winBefore - $0.1.winAfter) > ($1.1.winBefore - $1.1.winAfter) }
      .prefix(8).map { $0 }
  }

  /// 最上面那一句話：樣本太小不下結論；輸棋主因夠集中就講它，不然講失誤最多的階段（跟網站 pickHeadline 同一個順序）
  var headline: (title: String, detail: String)? {
    guard digests.count >= 3 else { return nil }
    if losses >= 3 {
      let threw = digests.filter { $0.lossReason == .threwWinning }.count
      if Double(threw) / Double(losses) >= 0.3 {
        return ("優勢守住，就能多贏", "\(losses) 局輸棋裡有 \(threw) 局曾經大優，最後沒轉成勝利。拿到優勢之後，每一步先看對手的威脅。")
      }
      let timeout = digests.filter { $0.lossReason == .timeout }.count
      if Double(timeout) / Double(losses) >= 0.3 {
        return ("時間分配是下一步", "\(losses) 局輸棋裡有 \(timeout) 局是超時。開局走熟悉的變化，把時間留給中局。")
      }
      let opening = digests.filter { $0.lossReason == .opening }.count
      if Double(opening) / Double(losses) >= 0.3 {
        return ("先把開局走穩", "\(losses) 局輸棋裡有 \(opening) 局在第 12 手就明顯落後。挑一兩個開局練熟。")
      }
    }
    if let worst = phaseRows.max(by: { $0.per100 < $1.per100 }), worst.per100 > 0 {
      return ("\(worst.phase.zh)最值得練", "你的\(worst.phase.zh)每 100 步有 \(String(format: "%.1f", worst.per100)) 個失誤，是三個階段裡最多的。")
    }
    return ("這幾局下得很穩", "沒有明顯一再出現的失誤，多分析幾局會看得更清楚。")
  }
}

/// 跨局報告頁
struct ReportView: View {
  @Environment(AppModel.self) private var app
  @State private var model = ReportModel()
  @State private var added: Int?
  @State private var drillSession: PracticeView.Session?

  private var types: [GameType] { GameType.types(app.games) }
  private var currentKey: String? { model.typeKey ?? GameType.pick(app.games) }

  var body: some View {
    List {
      if app.games.isEmpty {
        Section { HStack { ProgressView(); Text("載入對局…").foregroundStyle(.secondary) } }
      } else {
        if !model.digests.isEmpty { exportSection }
        if !model.running && model.digests.count >= 3 { Section { FeedbackPromptCard(trigger: "report_done", task: "report") } }
        if let p = model.prescription { prescriptionSection(p) }
        summary
        if let q = model.quick { quickSections(q) }
        if model.digests.count >= 2 { trend }
        if !model.phaseRows.isEmpty { phases }
        if !model.lossRows.isEmpty { lossSection }
        if let q = model.quick { openingSection(q) } else if !model.openingRows.isEmpty { openings }
        if !model.reversals.isEmpty { reversalSection }
        if let d = model.deep { deepSections(d) }
        if !model.worstMistakes.isEmpty { mistakes }
      }
    }
    .listStyle(.insetGrouped)
    // 還沒分析完：整頁是載入動畫，全部好了再一次出來（不一段一段跳出來）
    .overlay {
      if model.running && model.total > 0 {
        AnalyzingView(progress: Double(model.done) / Double(model.total), status: "分析最近 \(model.total) 局", plies: nil,
                      note: "第 \(min(model.done + 1, model.total))/\(model.total) 局・全部分析完會一次出來", tips: AnalyzingView.reportTips)
          .transition(.opacity)
      }
    }
    .animation(.snappy, value: model.running)
    .navigationTitle("報告")
    .fullScreenCover(item: $drillSession) { s in PuzzleSessionView(title: s.title, items: s.items, more: s.more) }
    .navigationDestination(for: KeyMoveLink.self) { l in ReviewView(game: l.game, startAt: l.ply + 1) }
    .toolbar {
      ToolbarItem(placement: .topBarTrailing) {
        Menu {
          Picker("時間類型", selection: Binding(get: { currentKey ?? "" }, set: { model.typeKey = $0 })) {
            ForEach(types) { t in Text("\(t.label)（\(t.games) 局）").tag(t.key) }
          }
          Picker("局數", selection: $model.count) {
            Text("最近 10 局").tag(10)
            Text("最近 20 局").tag(20)
          }
        } label: {
          Label(currentKey.map { GameType.label($0) } ?? "篩選", systemImage: "line.3.horizontal.decrease.circle")
            .labelStyle(.titleAndIcon).font(.subheadline)
        }
      }
    }
    .onAppear { model.run(app.games); AppLog.add("open", "report \(model.digests.count)") }
    .onChange(of: app.games.count) { model.run(app.games) }
    .onChange(of: model.typeKey) { model.run(app.games) }
    .onChange(of: model.count) { model.run(app.games) }
  }

  // MARK: 區塊

  private var summary: some View {
    Section {
      if model.prescription == nil, let h = model.headline {
        VStack(alignment: .leading, spacing: 6) {
          Text(h.title).font(.title3.bold()).foregroundStyle(Brand.ink)
          Text(h.detail).font(.subheadline).foregroundStyle(.secondary)
        }
        .padding(.vertical, 4)
      } else if model.prescription == nil && model.digests.count < 3 {
        Text("再多分析幾局，就看得出你最常在哪裡丟分。").font(.subheadline).foregroundStyle(.secondary)
      }
      HStack(spacing: 0) {
        stat("準確率", model.avgAccuracy.map { String(format: "%.1f", $0) } ?? "—", Brand.orange)
        stat("勝", "\(model.wins)", .green)
        stat("和", "\(model.draws)", .gray)
        stat("負", "\(model.losses)", .red)
      }
      if !model.digests.isEmpty {
        HStack(spacing: 12) {
          sideRow(.white)
          sideRow(.black)
        }
      }
    } header: {
      Text("\(currentKey.map { GameType.label($0) } ?? "")・已分析 \(model.digests.count) 局")
    }
  }

  private func stat(_ label: String, _ value: String, _ c: Color) -> some View {
    VStack(spacing: 2) {
      Text(value).font(.title2.bold().monospacedDigit()).foregroundStyle(c)
      Text(label).font(.caption).foregroundStyle(.secondary)
    }
    .frame(maxWidth: .infinity)
  }

  @ViewBuilder private func sideRow(_ s: Side) -> some View {
    if let x = model.side(s) {
      HStack(spacing: 6) {
        Circle().fill(s == .white ? Color.white : Brand.ink).overlay(Circle().stroke(Color.gray.opacity(0.5))).frame(width: 12, height: 12)
        VStack(alignment: .leading, spacing: 0) {
          Text("\(s == .white ? "執白" : "執黑") \(x.games) 局").font(.caption.weight(.semibold))
          Text("得分 \(Int(x.score * 100))%・準確率 \(String(format: "%.0f", x.accuracy))").font(.caption2).foregroundStyle(.secondary)
        }
      }
      .frame(maxWidth: .infinity, alignment: .leading)
    }
  }

  private var trend: some View {
    Section("準確率走勢") {
      let ds = Array(model.digests.reversed().enumerated())
      Chart {
        if let avg = model.avgAccuracy {
          RuleMark(y: .value("平均", avg)).foregroundStyle(.secondary.opacity(0.5)).lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 3]))
        }
        ForEach(ds, id: \.element.id) { i, d in
          LineMark(x: .value("局", i + 1), y: .value("準確率", d.accuracy)).foregroundStyle(Brand.orange.opacity(0.6)).interpolationMethod(.monotone)
          PointMark(x: .value("局", i + 1), y: .value("準確率", d.accuracy))
            .foregroundStyle(d.game.result == .win ? Color.green : d.game.result == .loss ? Color.red : Color.gray)
            .symbolSize(50)
        }
      }
      .chartYScale(domain: 0...100)
      .chartXAxis(.hidden)
      .frame(height: 160)
      .accessibilityLabel("最近幾局的準確率")
      Text("由舊到新；綠點贏、紅點輸、灰點和。").font(.caption2).foregroundStyle(.secondary)
    }
  }

  private var phases: some View {
    Section {
      ForEach(model.phaseRows) { r in
        HStack {
          Text(r.phase.zh).font(.subheadline.weight(.semibold)).frame(width: 40, alignment: .leading)
          VStack(alignment: .leading, spacing: 4) {
            GeometryReader { g in
              Capsule().fill(Color(.secondarySystemFill)).overlay(alignment: .leading) {
                // 只標最差的那個階段，其他用中性色（三條都紅看不出差別）
                Capsule().fill(r.id == model.phaseRows.max(by: { $0.per100 < $1.per100 })?.id ? Brand.orange : Color.gray.opacity(0.45))
                  .frame(width: max(6, g.size.width * min(r.per100 / 15, 1)))
              }
            }
            .frame(height: 8)
            Text("每 100 步 \(String(format: "%.1f", r.per100)) 個失誤・準確率 \(String(format: "%.0f", r.accuracy))・\(r.moves) 步")
              .font(.caption).foregroundStyle(.secondary)
          }
        }
        .padding(.vertical, 2)
      }
    } header: {
      Text("各階段")
    } footer: {
      Text("開局＝前 10 手；殘局＝雙方非兵子力加起來 16 分以下（約各剩一車一輕子）。")
    }
  }

  private var lossSection: some View {
    Section("怎麼輸的（\(model.losses) 局）") {
      ForEach(model.lossRows, id: \.0) { r, n in
        HStack {
          Text(r.zh).font(.subheadline)
          Spacer()
          Text("\(n) 局").font(.subheadline.monospacedDigit()).foregroundStyle(.secondary)
        }
      }
    }
  }

  // MARK: 產生複習、被逆轉的局

  /// 分析的終點：把這幾局走錯的局面變成複習卡，到「練習」每天複習
  private var exportSection: some View {
    let cards = model.reviewCards
    let fresh = cards.filter { !ReviewStore.shared.has($0.id) }
    return Section {
      VStack(alignment: .leading, spacing: 10) {
        Text(fresh.isEmpty ? "這幾局的失誤都在複習裡了" : "把 \(fresh.count) 個失誤變成複習題").font(.headline)
        let kinds = ReviewCard.Kind.allCases.compactMap { k -> (ReviewCard.Kind, Int)? in
          let n = fresh.filter { $0.kinds.contains(k) }.count
          return n > 0 ? (k, n) : nil
        }
        if !kinds.isEmpty {
          ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
              ForEach(kinds, id: \.0) { k, n in
                Label("\(k.zh) \(n)", systemImage: k.icon).font(.caption).padding(.horizontal, 8).padding(.vertical, 4)
                  .background(Brand.cream, in: Capsule())
              }
            }
          }
          .scrollBounceBehavior(.basedOnSize, axes: .vertical)
        }
        Button {
          let n = ReviewStore.shared.add(fresh)
          added = n
          Haptics.bump()
        } label: {
          // 圖示＋字一起置中（Label 直接撐滿寬度時圖示和字會偏）
          HStack(spacing: 8) {
            Image(systemName: fresh.isEmpty ? "figure.strengthtraining.traditional" : "plus.rectangle.on.rectangle")
            Text(fresh.isEmpty ? "去練習複習題" : "加進複習題庫（\(fresh.count) 題）")
          }
          .font(.headline).frame(maxWidth: .infinity, minHeight: 46)
        }
        .buttonStyle(.borderedProminent).tint(Brand.orange)
        .simultaneousGesture(TapGesture().onEnded { if fresh.isEmpty { app.tab = .practice } })
        if let added, added > 0 {
          Button { app.tab = .practice } label: {
            HStack(spacing: 8) { Image(systemName: "checkmark.circle.fill"); Text("已加入 \(added) 題，去練習"); Image(systemName: "chevron.right").font(.caption.weight(.bold)) }
              .font(.subheadline.weight(.semibold)).frame(maxWidth: .infinity, minHeight: 44)
          }
          .buttonStyle(.bordered).tint(.green)
        }
      }
      .padding(.vertical, 4)
    } footer: {
      Text("每天練幾題。答錯的會再出現，答對的隔幾天再複習。")
    }
  }

  private var reversalSection: some View {
    let rs = model.reversals
    let counts = Reversal.Reason.allCases.compactMap { r -> (Reversal.Reason, Int)? in
      let n = rs.filter { $0.reason == r }.count
      return n > 0 ? (r, n) : nil
    }.sorted { $0.1 > $1.1 }
    return Section {
      ForEach(counts, id: \.0) { r, n in bar(r.zh, n, of: rs.count, r == .endgame ? .indigo : r == .timeout || r == .timePressure ? .purple : .orange) }
      if let top = counts.first { Label(top.0.tip, systemImage: "lightbulb").font(.subheadline) }
      ForEach(rs) { r in
        NavigationLink(value: KeyMoveLink(game: r.game, ply: r.record.ply)) {
          VStack(alignment: .leading, spacing: 2) {
            Text("vs \(r.game.opponent)・第 \(r.record.ply / 2 + 1) 手 \(r.record.san)").font(.subheadline)
            Text("最高到\(Grading.standing(r.peak))，\(r.reason.zh)\(r.clock.map { "（剩 \(Int($0)) 秒）" } ?? "")・\(r.game.result == .draw ? "和棋" : "輸了")")
              .font(.caption).foregroundStyle(.secondary)
          }
        }
      }
    } header: {
      Text("被逆轉的局（\(rs.count) 局）")
    } footer: {
      Text("曾經大優卻沒贏的局，以及優勢從哪一步開始流失。")
    }
  }

  // MARK: 網站的跨局分析

  /// 先學的一件事：跟同分段、下一個分段比，挑差最多的那一項
  private func prescriptionSection(_ p: ReportJS.Prescription) -> some View {
    Section {
      VStack(alignment: .leading, spacing: 8) {
        if p.status == "ready" {
          Label("這個分段的基本功都做到了", systemImage: "checkmark.seal.fill").font(.headline).foregroundStyle(.green)
          Text("下面幾項都跟上（或超過）\(p.next)的玩家，可以往更難的戰術練。").font(.subheadline).foregroundStyle(.secondary)
        } else {
          Text("先練：\(p.pick.label)").font(.title3.bold()).foregroundStyle(Brand.ink)
          Text(p.pick.hint).font(.footnote).foregroundStyle(.secondary)
          HStack(spacing: 0) {
            compare("你", p.pick.mine, Brand.orange)
            compare("同分段", p.pick.same, .secondary)
            compare("下一段", p.pick.next, .green)
          }
          Label { Text(p.pick.lesson).fixedSize(horizontal: false, vertical: true) } icon: { Image(systemName: "lightbulb.fill").foregroundStyle(Brand.orange) }
            .font(.subheadline.weight(.medium)).foregroundStyle(Brand.ink)
            .padding(10).frame(maxWidth: .infinity, alignment: .leading)
            .background(Brand.orange.opacity(0.1), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
          practiceButtons(p.pick.key)
        }
      }
      .padding(.vertical, 4)
      ForEach(p.rows.filter { $0.key != p.pick.key }, id: \.key) { r in
        HStack(alignment: .firstTextBaseline) {
          Image(systemName: r.gap <= 0 ? "checkmark.circle.fill" : "circle").foregroundStyle(r.gap <= 0 ? .green : .orange)
          VStack(alignment: .leading, spacing: 2) {
            Text(r.label).font(.subheadline)
            Text(r.lesson).font(.caption).foregroundStyle(.secondary)
          }
          Spacer()
          Text("你 \(r.mine)・同分段 \(r.same)").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
        }
      }
    } header: {
      Text("先學的一件事")
    } footer: {
      Text("比較對象：\(p.same)、\(p.next)的玩家（最近 \(p.games) 局）。綠勾代表你已經跟上下一個分段。")
    }
  }

  /// 指標 → 練習：主題題庫與我自己的相關失誤
  private static let drill: [String: (theme: String, kind: ReviewCard.Kind)] = [
    "hungRate": ("hanging", .tactic), "missedFreeRate": ("hanging", .tactic), "missedChanceRate": ("hanging", .tactic),
    "missedMateRate": ("mate1", .tactic), "allowedMateRate": ("mate1", .tactic), "forkRate": ("fork", .tactic),
  ]

  @ViewBuilder private func practiceButtons(_ key: String) -> some View {
    let d = Self.drill[key]
    let theme = d.flatMap { t in PuzzleBank.themes.first { $0.key == t.theme } }
    let mine = ReviewStore.shared.cards.filter { !$0.mastered && $0.kinds.contains(d?.kind ?? .other) }
    VStack(spacing: 8) {
      if let theme {
        Button {
          Task {
            let items = await PuzzleBank.fetch(theme, rating: app.games.first?.myRating, platform: app.account?.platform ?? .chesscom, n: PracticeView.daily)
            let rating = app.games.first?.myRating, platform = app.account?.platform ?? .chesscom
            if !items.isEmpty { drillSession = PracticeView.Session(title: theme.name, items: items) { await PuzzleBank.fetch(theme, rating: rating, platform: platform) } }
          }
        } label: {
          HStack(spacing: 8) { Image(systemName: "target"); Text("練 \(PracticeView.daily) 題「\(theme.name)」") }
            .font(.subheadline.weight(.semibold)).frame(maxWidth: .infinity, minHeight: 44)
        }
        .buttonStyle(.borderedProminent).tint(Brand.orange)
        .onAppear {
          // 報告挑出來的重點，就是練習分頁的「本週重點」
          PuzzleBank.focus = theme
          PuzzleBank.focusLabel = theme.name
        }
      }
      if !mine.isEmpty {
        Button { drillSession = PracticeView.Session(title: "我的相關失誤", items: mine.prefix(10).map(PuzzleItem.init(card:))) } label: {
          HStack(spacing: 8) { Image(systemName: "arrow.uturn.backward.circle"); Text("複習我自己走錯的 \(min(mine.count, 10)) 步") }
            .font(.subheadline.weight(.semibold)).frame(maxWidth: .infinity, minHeight: 44)
        }
        .buttonStyle(.bordered).tint(Brand.orange)
      }
    }
  }

  private func compare(_ who: String, _ v: String, _ c: Color) -> some View {
    VStack(spacing: 2) {
      Text(v).font(.title3.bold().monospacedDigit()).foregroundStyle(c)
      Text(who).font(.caption2).foregroundStyle(.secondary)
    }
    .frame(maxWidth: .infinity)
  }

  @ViewBuilder private func quickSections(_ q: ReportJS.Quick) -> some View {
    Section {
      bar("被將死", q.lossBy.checkmated, of: q.record.loss, .red)
      bar("認輸", q.lossBy.resigned, of: q.record.loss, .orange)
      bar("超時", q.lossBy.timeout, of: q.record.loss, .purple)
      if q.lossBy.other > 0 { bar("其他", q.lossBy.other, of: q.record.loss, .gray) }
    } header: {
      Text("怎麼輸的（\(q.record.loss) 局）")
    }
    Section("對手與狀態") {
      row("對手平均分數", "\(q.opponentRating.avg)")
      row("贏的時候對手", "\(q.opponentRating.whenWin) 分")
      row("輸的時候對手", "\(q.opponentRating.whenLoss) 分")
      if let d = q.ratingDelta { row("分數變化", "\(d.from) → \(d.to)（\(d.diff >= 0 ? "+" : "")\(d.diff)）") }
      if let f = q.fatigue {
        VStack(alignment: .leading, spacing: 2) {
          Text("一天下超過 \(f.threshold) 局之後").font(.subheadline)
          Text("勝率 \(f.earlyWinRate)% → \(f.lateWinRate)%\(f.lateWinRate < f.earlyWinRate - 5 ? "，累了就休息一下" : "")").font(.caption).foregroundStyle(.secondary)
        }
      }
      row("執白勝率", "\(q.byColor.white.winRate)%（\(q.byColor.white.games) 局）")
      row("執黑勝率", "\(q.byColor.black.winRate)%（\(q.byColor.black.games) 局）")
    }
  }

  private func row(_ k: String, _ v: String) -> some View {
    HStack { Text(k).font(.subheadline); Spacer(); Text(v).font(.subheadline.monospacedDigit()).foregroundStyle(.secondary) }
  }

  private func bar(_ label: String, _ n: Int, of total: Int, _ c: Color) -> some View {
    HStack(spacing: 10) {
      Text(label).font(.subheadline).frame(width: 72, alignment: .leading)
      GeometryReader { g in
        Capsule().fill(Color(.secondarySystemFill)).overlay(alignment: .leading) {
          Capsule().fill(c.opacity(0.8)).frame(width: total == 0 ? 0 : max(4, g.size.width * Double(n) / Double(total)))
        }
      }
      .frame(height: 8)
      Text("\(n)").font(.caption.monospacedDigit()).foregroundStyle(.secondary).frame(width: 28, alignment: .trailing)
    }
  }

  private func openingSection(_ q: ReportJS.Quick) -> some View {
    Section {
      ForEach([("執白", q.topOpenings.asWhite), ("執黑", q.topOpenings.asBlack)], id: \.0) { side, list in
        if !list.isEmpty {
          Text(side).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
          ForEach(list.prefix(4), id: \.name) { o in
            HStack {
              VStack(alignment: .leading, spacing: 1) {
                Text(o.name).font(.subheadline).lineLimit(1)
                Text("\(o.games) 局").font(.caption).foregroundStyle(.secondary)
              }
              Spacer()
              Text("勝 \(o.winRate)%").font(.subheadline.monospacedDigit().weight(.semibold)).foregroundStyle(o.winRate >= 50 ? .green : .red)
            }
          }
        }
      }
    } header: {
      Text("開局")
    }
  }

  @ViewBuilder private func deepSections(_ d: ReportJS.Deep) -> some View {
    if let t = d.time, t.moves >= 20 {
      Section {
        row("平均每步", seconds(t.avg))
        if let bad = t.avgBad, let other = t.avgOther {
          row("失誤的那步平均想", seconds(bad))
          row("其他步平均想", seconds(other))
        }
        if let f = t.fastBadShare, t.badCount >= 3 {
          Text("\(t.badCount) 個失誤裡，\(Int(f * 100))% 是很快就走的\(f >= 0.5 ? "：失誤多半是走太快，關鍵局面多想幾秒" : "")。").font(.subheadline)
        }
        if let low = t.lowRate, let normal = t.normalRate, t.lowMoves >= 10 {
          Text("時間快不夠時每 100 步 \(String(format: "%.1f", low)) 個失誤，時間夠時 \(String(format: "%.1f", normal)) 個。").font(.subheadline)
        }
      } header: {
        Text("用時（\(t.games) 局）")
      }
    }
    let endgames = d.endgames.filter { $0.games > 0 }
    if !endgames.isEmpty {
      Section {
        ForEach(endgames, id: \.type) { e in
          VStack(alignment: .leading, spacing: 3) {
            HStack {
              Text(e.name).font(.subheadline.weight(.semibold))
              Spacer()
              Text("\(e.games) 局・準確率 \(Int(e.accuracy))").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            }
            if e.ahead > 0 { Text("大優收下 \(e.converted)/\(e.ahead) 局").font(.caption).foregroundStyle(e.converted < e.ahead ? .orange : .green) }
            if e.even > 0 { Text("均勢輸掉 \(e.evenLost)/\(e.even) 局").font(.caption).foregroundStyle(e.evenLost > 0 ? .orange : .secondary) }
            Text(e.tip).font(.caption2).foregroundStyle(.secondary)
          }
        }
      } header: {
        Text("殘局")
      } footer: {
        Text("看進入殘局那一刻雙方剩什麼子；大優＝勝率七成五以上，均勢＝三成五到六成五。")
      }
    }
    if !d.habits.isEmpty {
      Section("開局習慣") {
        ForEach(d.habits, id: \.kind) { h in
          VStack(alignment: .leading, spacing: 3) {
            HStack {
              Text(h.name).font(.subheadline.weight(.semibold))
              Spacer()
              Text("\(h.games) 局").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            }
            Text(h.desc).font(.caption).foregroundStyle(.secondary)
            Label(h.tip, systemImage: "lightbulb").font(.caption).foregroundStyle(Brand.ink)
          }
        }
      }
    }
  }

  private func seconds(_ t: Double) -> String { t < 10 ? String(format: "%.1f 秒", t) : "\(Int(t.rounded())) 秒" }

  private var openings: some View {
    Section("開局") {
      ForEach(model.openingRows.prefix(6)) { o in
        HStack {
          VStack(alignment: .leading, spacing: 2) {
            Text(o.name).font(.subheadline).lineLimit(1)
            Text("\(o.games) 局・準確率 \(String(format: "%.0f", o.accuracy))").font(.caption).foregroundStyle(.secondary)
          }
          Spacer()
          Text("得分 \(Int(o.score * 100))%").font(.subheadline.monospacedDigit().weight(.semibold))
            .foregroundStyle(o.score >= 0.5 ? .green : .red)
        }
      }
    }
  }

  private var mistakes: some View {
    Section {
      ForEach(model.worstMistakes, id: \.1.ply) { d, r in
        NavigationLink(value: KeyMoveLink(game: d.game, ply: r.ply)) {
          HStack(spacing: 10) {
            GradeBadge(cls: r.cls, size: 22)
            VStack(alignment: .leading, spacing: 2) {
              Text("\(r.ply / 2 + 1)\(r.mover == .white ? "." : "…") \(r.san)・該走 \(r.bestSan ?? "—")").font(.subheadline.monospacedDigit())
              Text("vs \(d.game.opponent)・\(r.standingText(me: d.game.color))").font(.caption).foregroundStyle(.secondary)
            }
          }
        }
      }
    } header: {
      Text("掉最多的關鍵步")
    } footer: {
      Text("點進去直接停在那一步，可以看說明和延伸棋局。")
    }
  }
}

struct KeyMoveLink: Hashable {
  let game: GameSummary
  let ply: Int
}

extension Optional {
  func asyncMap<U>(_ f: (Wrapped) async -> U) async -> U? {
    guard let x = self else { return nil }
    return await f(x)
  }
}
