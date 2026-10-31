import SwiftUI

/// 單局復盤：一屏放得下（統計列 → 棋盤＋勝率條 → 棋譜條 → 這一步 → 播放控制 → 圖示列），次要資訊用面板彈出。
/// 棋盤左右滑可以換步；關鍵步有說明，可以打開延伸棋局（引擎的線＋資料庫裡真人常見的接法）
/// 單局復盤的入口：先放載入動畫，背景把棋譜、分析存檔、要顯示的解說都備好，再淡入復盤畫面（之後滑、播都不用再算）
struct ReviewView: View {
  let game: GameSummary
  var startAt = 0
  @State private var model: ReviewModel?

  var body: some View {
    ZStack {
      if let model {
        ReviewContent(model: model).transition(.opacity)
      } else {
        AnalyzingView(progress: nil, status: "載入對局", plies: nil)
          .toolbar(.hidden, for: .tabBar)
          .navigationTitle("\(game.color == .white ? "執白" : "執黑") vs \(game.opponent)")
          .navigationBarTitleDisplayMode(.inline)
      }
    }
    .animation(.easeOut(duration: 0.25), value: model == nil)
    .task {
      guard model == nil else { return }
      let g = game
      let prepared = await Task.detached(priority: .userInitiated) { ReviewModel.prepare(g) }.value
      let m = ReviewModel(game: g, prepared: prepared, startAt: startAt)
      if m.status.isEmpty { await m.warmExplanations() }
      model = m
    }
  }
}

struct ReviewContent: View {
  @State private var model: ReviewModel
  @State private var flipped: Bool
  @State private var sheet: Sheet?
  @State private var showHint = true
  @State private var explore: ExploreTarget?
  @State private var promo: (from: String, to: String)?
  /// 重點復盤（Duolingo 式）：一個一個重點，自己找更好的一步
  /// 快速復盤（Duolingo 式）：就在這個棋盤上快速自動播，停在重點讓你找
  @State private var quick: QuickReview?
  @State private var preparing = false
  /// 從開始分析到快速復盤開始播，載入畫面一直蓋著（中間不閃）
  @State private var loading = false

  enum Sheet: String, Identifiable { case db, keys, lines; var id: String { rawValue } }
  /// 勝率條＋棋盤那一列的高度：照螢幕寬算，固定不變
  static let boardRow: CGFloat = {
    let w = min(UIScreen.main.bounds.width, 600) - 24
    return w - 16
  }()
  struct ExploreTarget: Hashable { let line: [Ply]; let start: String; let at: Int }

  init(model: ReviewModel) {
    _model = State(initialValue: model)
    _flipped = State(initialValue: model.game.color == .black)
    _loading = State(initialValue: !model.status.isEmpty)
    #if DEBUG
    // 開發用：-mode quick|step|free
    let args = ProcessInfo.processInfo.arguments
    if let i = args.firstIndex(of: "-mode"), i + 1 < args.count, let m = ReviewModel.Mode(rawValue: args[i + 1]) { model.mode = m }
    if let i = args.firstIndex(of: "-at"), i + 1 < args.count, let n = Int(args[i + 1]) { model.go(n) }
    #endif
  }

  var body: some View {
    // 跟 chess.com Game Review 一樣的排法：對手 → 棋盤 → 你 → 棋譜 → 解說區（佔滿剩下的空間）→ 最下面的操作列
    VStack(spacing: 0) {
      playerBar(flipped ? .white : .black)
      HStack(spacing: 6) {
        EvalBar(white: quick?.whiteWin ?? model.whiteWin, flipped: flipped)
        BoardView(fen: fen, flipped: flipped, arrows: arrows, highlight: lastSquares, pulse: quick?.pulse, badge: badge,
                  legalTargets: quick.map { q in q.canMove ? { sq in quickTargets(q, sq) } : nil } ?? (model.mode == .free ? { model.freeTargets($0) } : canExplore ? { FEN.targets(fen: fen, from: $0) } : nil),
                  onMove: quick.map { q in q.canMove ? { q.tryMove($0, $1) } : nil } ?? (model.mode == .free ? { from, to in
                    if FEN.pieces(fen)[from]?.last == "P", to.hasSuffix("8") || to.hasSuffix("1") { promo = (from, to) } else { model.freeMove(from, to) }
                  } : canExplore ? { exploreWith($0, $1) } : nil),
                  onSwipe: canExplore ? { step($0) } : nil)
          .gesture(model.mode == .free || quick != nil || canExplore ? nil : swipe)
          .overlay {
            if (quick?.resigned ?? false) || (quick == nil && model.game.opponentResigned && model.current == model.count && model.count > 0 && model.variation == nil) {
              ResignFlag(name: model.game.opponent).transition(.scale.combined(with: .opacity))
            }
          }
          .overlay {
            if let p = promo {
              PromotionPicker(white: FEN.sideToMove(fen) == .white) { k in
                promo = nil
                if let k { model.freeMove(p.from, p.to, promotion: k) }
              }
            }
          }
      }
      // 棋盤大小固定（照螢幕寬），下面的解說變長也不會跟著縮放
      .frame(height: Self.boardRow)
      .padding(.horizontal, 12)
      playerBar(flipped ? .black : .white)
      if let q = quick { quickStrip(q) } else if model.compare != nil && model.variation == nil { compareStrip } else if model.variation != nil { variationStrip } else { moveStrip }
      Divider()
      ScrollView {
        coachPanel.padding(.horizontal, 14).padding(.vertical, 10)
      }
      .scrollBounceBehavior(.basedOnSize)
    }
    .safeAreaInset(edge: .bottom, spacing: 0) { if !isLoading { if let q = quick { quickBar(q) } else { bottomBar } } }
    // 分析中、準備解說中：整個畫面是載入動畫，好了自動開始快速復盤
    .overlay {
      if isLoading {
        AnalyzingView(progress: preparing ? 1 : model.progress, status: preparing ? "準備每一步的解說" : model.status, plies: model.count).transition(.opacity)
      }
    }
    .animation(.easeOut(duration: 0.3), value: isLoading)
    // 剛分析完：直接開始快速復盤
    .onChange(of: model.status.isEmpty) { was, now in if now && !was { openLesson() } }
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    .background(Brand.paper)
    .toolbar(.hidden, for: .tabBar)
    .navigationTitle("\(model.game.color == .white ? "執白" : "執黑") vs \(model.game.opponent)")
    .navigationBarTitleDisplayMode(.inline)
    .toolbar {
      ToolbarItem(placement: .topBarTrailing) { SoundToggle() }
      ToolbarItem(placement: .topBarTrailing) {
        if let url = model.game.url { ShareLink(item: url) { Image(systemName: "square.and.arrow.up") } }
      }
    }
    .navigationDestination(item: $explore) { t in
      AnalysisBoardView(startFen: t.start, line: t.line, at: t.at, orientation: flipped ? .black : .white,
                        returnLabel: model.current == 0 ? "回到復盤" : "回到復盤・第 \((model.current + 1) / 2) 手")
    }
    .onAppear {
      model.start()
      AppLog.add("open", "review \(model.game.platform.rawValue) \(model.count) plies") }
    .onChange(of: model.mode) { _, m in model.stopFollowing(); if m == .free { model.refreshFreeLines() } }
    .task { if model.mode == .free { model.refreshFreeLines() } }
    .onDisappear { model.stop(); quick?.stop() }
    #if DEBUG
    // 開發用：-demoExplore 走到第 10 手後切到深入分析
    .task {
      guard ProcessInfo.processInfo.arguments.contains("-demoExplore"), let line = model.line else { return }
      try? await Task.sleep(nanoseconds: 3_000_000_000)
      model.go(19)
      try? await Task.sleep(nanoseconds: 2_500_000_000)
      explore = ExploreTarget(line: line.plies, start: line.startFen, at: model.current)
    }
    // 開發用：-demoLessonReview 分析完直接進重點復盤，-lessonStep N 自動走到第 N 個重點的找步畫面
    .task {
      guard ProcessInfo.processInfo.arguments.contains("-demoLessonReview") else { return }
      while !model.status.isEmpty { try? await Task.sleep(nanoseconds: 500_000_000) }
      try? await Task.sleep(nanoseconds: 800_000_000)
      if quick == nil { openLesson() }
      if ProcessInfo.processInfo.arguments.contains("-lessonSkip") {
        while quick == nil { try? await Task.sleep(nanoseconds: 300_000_000) }
        try? await Task.sleep(nanoseconds: 1_000_000_000)
        quick?.skipAhead()
        // -lessonWrong：停下來之後自動走一步不是答案的棋（看對手怎麼懲罰）
        if ProcessInfo.processInfo.arguments.contains("-lessonWrong"), let q = quick {
          while q.phase != .trying { try? await Task.sleep(nanoseconds: 200_000_000) }
          try? await Task.sleep(nanoseconds: 800_000_000)
          let want = q.current?.steps.first?.uci ?? ""
          let mine = FEN.pieces(q.fen).filter { $0.value.first == (model.me == .white ? "w" : "b") }.keys.sorted()
          if let m = mine.lazy.flatMap({ sq in FEN.targets(fen: q.fen, from: sq).map { sq + $0 } }).first(where: { $0 != want && !(q.current?.accept.contains($0) ?? false) }) {
            q.tryMove(String(m.prefix(2)), String(m.suffix(2)))
          }
        }
      }
    }
    // 開發用：-demoCompare 打開第一個失誤的候選步比較，並選最佳
    .task {
      guard ProcessInfo.processInfo.arguments.contains("-demoCompare") else { return }
      while !model.status.isEmpty { try? await Task.sleep(nanoseconds: 500_000_000) }
      try? await Task.sleep(nanoseconds: 800_000_000)
      guard let k = model.myMistakes.first else { return }
      model.openCompare(k.ply)
      try? await Task.sleep(nanoseconds: 1_500_000_000)
      if let b = model.compare?.candidates.first(where: { $0.kind == .best }) { model.pickCandidate(b) }
    }
    // 開發用：-demoKey 分析完跳到第一個關鍵步並打開延伸棋局
    .onChange(of: model.status) {
      if model.status.isEmpty, ProcessInfo.processInfo.arguments.contains("-demoKey"),
         let k = model.keyMoves.first(where: { $0.mover == model.me && $0.cls.isBad }) {
        model.go(k.ply + 1)
        Task { try? await Task.sleep(nanoseconds: 1_500_000_000); sheet = .lines }
      }
    }
    #endif
    .onChange(of: model.lesson != nil) { _, has in if has { model.lesson = nil } }

    .sheet(item: $sheet) { s in
      switch s {
      case .db:
        ExplorerSheet(fen: dbFen, played: playedRecord?.san, playedByOpp: playedRecord.map { $0.mover != model.me } ?? false,
                      best: playedRecord?.bestSan, rating: model.game.myRating, platform: model.game.platform)
          .presentationDetents([.medium, .large])
      case .keys:
        KeyMovesSheet(model: model) { sheet = nil }
          .presentationDetents([.medium, .large])
      case .lines:
        if let r = playedRecord, let p = playedPly {
          LinesSheet(key: model.key(p.index), record: r, ply: p, me: model.me, explanation: model.explanation(p.index),
                     before: model.evals[p.index] ?? nil, after: model.evals[p.index + 1] ?? nil) { o in
            sheet = nil
            model.open(o)
          }
          .presentationDetents([.medium, .large])
        }
      }
    }
  }

  // MARK: 目前這一手

  private var fen: String { quick?.fen ?? model.variation?.fen ?? model.line?.fen(at: model.current) ?? "8/8/8/8/8/8/8/8 w - - 0 1" }
  private var playedRecord: MoveRecord? { model.current > 0 ? model.records[model.current - 1] : nil }
  private var playedPly: Ply? { model.current > 0 ? model.line?.plies[model.current - 1] : nil }
  /// 資料庫看的是「走這一手之前」的局面：大家在這裡走哪一步
  private var dbFen: String { model.variation?.fen ?? model.line?.fen(at: max(model.current - 1, 0)) ?? fen }

  private var lastSquares: [String] {
    if let q = quick { return q.squares }
    if let v = model.variation { return v.last.map { [$0.from, $0.to] } ?? [] }
    return playedPly.map { [$0.from, $0.to] } ?? []
  }

  private var badge: (square: String, cls: MoveClass)? {
    if let q = quick { return q.badge }
    guard model.variation == nil, model.compare == nil, let p = playedPly, let r = playedRecord else { return nil }
    return (p.to, r.cls)
  }

  /// 箭頭：關鍵的壞棋畫該走的（綠）＋第二選擇（淡綠）；最佳步提示開著時畫下一步的最佳與第二選擇
  private var arrows: [Arrow] {
    if let q = quick { return q.arrows }
    // 比較候選步：還沒選、或選了但還在起點，畫出每個候選（你走的紅、最佳綠、也不錯淡綠）
    if let c = model.compare {
      guard (model.variation?.cursor ?? 0) == 0 else { return [] }
      return c.candidates.map { x in
        Arrow(from: String(x.uci.prefix(2)), to: String(x.uci.dropFirst(2).prefix(2)),
              color: x.kind == .best ? Brand.bestArrow : x.kind == .alt ? Brand.altArrow : Color.red.opacity(0.75))
      }
    }
    guard model.variation == nil else { return [] }
    var out: [Arrow] = []
    if let r = playedRecord, r.mover == model.me, r.cls.isBad {
      if let b = r.bestUci { out.append(Arrow(from: String(b.prefix(2)), to: String(b.dropFirst(2).prefix(2)), color: Brand.bestArrow)) }
      if let a = r.altUci { out.append(Arrow(from: String(a.prefix(2)), to: String(a.dropFirst(2).prefix(2)), color: Brand.altArrow)) }
    } else if showHint, FEN.sideToMove(fen) == model.me, let lines = model.evals[model.current], let best = lines.first?.best, !model.playing {
      // 最佳步提示只在輪到你走時畫（輪到對手時畫對手的最佳步，會以為是你該走的）
      if let alt = Grading.secondChoice(lines)?.best { out.append(Arrow(from: String(alt.prefix(2)), to: String(alt.dropFirst(2).prefix(2)), color: Brand.altArrow)) }
      out.append(Arrow(from: String(best.prefix(2)), to: String(best.dropFirst(2).prefix(2)), color: Brand.bestArrow.opacity(0.7)))
    }
    return out
  }

  /// 棋盤左滑下一步、右滑上一步
  private var swipe: some Gesture {
    DragGesture(minimumDistance: 24).onEnded { v in
      guard abs(v.translation.width) > abs(v.translation.height) * 1.5 else { return }
      step(v.translation.width < 0 ? 1 : -1)
    }
  }

  private func step(_ d: Int) {
    if model.compare != nil && model.variation == nil { return }
    if model.variation != nil { model.stepVariation(d) } else { model.go(model.current + d) }
  }

  /// 自由分析的候選步：這個局面引擎前幾名，點一下就走
  private var freeCandidates: [AnalysisModel.Candidate] {
    let lines = model.freeLines
    let k = FEN.sideToMove(fen) == .white ? 1 : -1
    return lines.prefix(3).enumerated().compactMap { i, l in
      guard let u = l.best, let san = FEN.san(fen: fen, uci: u) else { return nil }
      return AnalysisModel.Candidate(san: san, uci: u, rank: i, eval: Grading.evalText(cp: l.cp.map { $0 * k }, mate: l.mate.map { $0 * k }),
                                     gap: Difficulty.winGap(lines, index: i), share: nil)
    }
  }

  private func secondsText(_ t: Double) -> String { t < 10 ? String(format: "%.1f 秒", t) : "\(Int(t.rounded())) 秒" }

  // MARK: 區塊

  /// 玩家列：顏色、名字、分數、準確率，右邊是這一步時剩下的時間（跟 chess.com 一樣在棋盤上下）
  private func playerBar(_ side: Side) -> some View {
    let mine = side == model.me
    let name = mine ? "你" : model.game.opponent
    let rating = mine ? model.game.myRating : model.game.opponentRating
    return HStack(spacing: 8) {
      Circle().fill(side == .white ? Color.white : Brand.ink).overlay(Circle().stroke(Color.gray.opacity(0.5))).frame(width: 14, height: 14)
      Text(name).font(.subheadline.weight(.semibold)).foregroundStyle(Brand.ink).lineLimit(1)
      if let rating { Text("(\(rating))").font(.caption).foregroundStyle(.secondary) }
      if let a = model.accuracy(of: side) {
        Text(String(format: "%.1f", a)).font(.caption.weight(.bold).monospacedDigit())
          .padding(.horizontal, 6).padding(.vertical, 2)
          .background(mine ? Brand.orange.opacity(0.15) : Color(.secondarySystemFill), in: Capsule())
          .foregroundStyle(mine ? Brand.orange : Brand.ink)
      }
      Spacer()
      if let t = model.clock(of: side, at: quick?.pos) {
        Text(clockText(t)).font(.subheadline.monospacedDigit().weight(.semibold))
          .padding(.horizontal, 8).padding(.vertical, 3)
          .background(FEN.sideToMove(fen) == side ? Brand.ink : Color(.secondarySystemFill), in: RoundedRectangle(cornerRadius: 5))
          .foregroundStyle(FEN.sideToMove(fen) == side ? .white : Brand.ink)
      }
    }
    .padding(.horizontal, 14).frame(height: 34)
  }

  private func clockText(_ t: Double) -> String {
    let s = Int(t.rounded(.down))
    return t < 20 ? String(format: "%d:%04.1f", s / 60, t.truncatingRemainder(dividingBy: 60)) : String(format: "%d:%02d", s / 60, s % 60)
  }

  /// 棋譜滾輪：左右滑，停在中間的那一步就是現在看的；每一步下面是想了幾秒（30 秒以上標橘色）
  private var moveStrip: some View {
    let plies = model.line?.plies ?? []
    let items = [MoveWheel.Item(id: 0, number: nil, san: "開始")] + plies.map { p in
      let t = model.thinkTimes[safe: p.index] ?? nil
      let r = model.records[safe: p.index] ?? nil
      return MoveWheel.Item(id: p.index + 1, number: p.mover == .white ? "\(p.moveNumber)." : nil, san: p.san,
                            badge: r.flatMap { $0.cls != .good && $0.cls != .excellent ? $0.cls : nil },
                            sub: t.map { $0 < 10 ? String(format: "%.1fs", $0) : "\(Int($0.rounded()))s" }, subHighlight: (t ?? 0) >= 30)
    }
    return MoveWheel(items: items, selection: Binding(get: { model.current }, set: { model.go($0) }))
  }

  /// 延伸模式的棋譜條：這條線的每一步，最前面是「回到對局」
  private var variationStrip: some View {
    ScrollViewReader { proxy in
      ScrollView(.horizontal, showsIndicators: false) {
        HStack(spacing: 4) {
          Button { model.compare != nil ? model.closeCompare() : model.closeVariation() } label: {
            Label(model.compare != nil ? "回到這一手" : "回到對局", systemImage: "arrow.uturn.backward").font(.caption.weight(.semibold))
          }
            .buttonStyle(.borderedProminent).tint(Brand.ink)
          if let v = model.variation {
            ForEach(Array(v.option.plies.enumerated()), id: \.offset) { i, p in
              Text((p.mover == .white ? "\(p.moveNumber). " : i == 0 ? "\(p.moveNumber)… " : "") + p.san)
                .font(.caption.monospacedDigit()).fontWeight(v.cursor == i + 1 ? .bold : .regular)
                .padding(.horizontal, 6).padding(.vertical, 4)
                .background(v.cursor == i + 1 ? Color.blue.opacity(0.15) : .clear, in: Capsule())
                .id(i + 1)
            }
          }
        }
      }
      .onChange(of: model.variation?.cursor) { _, v in withAnimation { proxy.scrollTo(v ?? 0, anchor: .center) } }
    }
    .frame(height: 30)
  }

  /// 比較候選步時的棋譜條：只有「回到這一手」
  private var compareStrip: some View {
    HStack {
      Button { model.closeCompare() } label: { Label("回到這一手", systemImage: "arrow.uturn.backward").font(.caption.weight(.semibold)) }
        .buttonStyle(.borderedProminent).tint(Brand.ink)
      Text("點下面的候選步，在棋盤上走走看").font(.caption).foregroundStyle(.secondary)
      Spacer()
    }
    .padding(.horizontal, 12).frame(height: 30)
  }

  /// 比較候選步：每一步走一兩步，說會怎樣；最上面一句為什麼選最佳
  @ViewBuilder private func comparePanel(_ c: ReviewModel.Compare) -> some View {
    if let why = c.why {
      Label { Text(why).font(.subheadline.weight(.semibold)).foregroundStyle(Brand.ink).fixedSize(horizontal: false, vertical: true) } icon: {
        Image(systemName: "lightbulb.fill").foregroundStyle(Brand.orange)
      }
    }
    ForEach(c.candidates) { x in
      let on = c.selected == x.id
      let v = on ? model.variation : nil
      Button { model.pickCandidate(x) } label: {
        VStack(alignment: .leading, spacing: 6) {
          HStack(spacing: 8) {
            Circle().fill(x.kind == .best ? Brand.bestArrow : x.kind == .alt ? Color(hex: 0x86D9A0) : Color.red.opacity(0.75)).frame(width: 10, height: 10)
            Text("\(x.option.title)・\(x.san)").font(.subheadline.weight(.bold)).foregroundStyle(Brand.ink)
            Spacer()
            Image(systemName: on && model.playing ? "pause.circle.fill" : "play.circle.fill").foregroundStyle(Brand.orange)
          }
          // 每一步會怎樣：選了才展開，播到哪一步亮到哪一步
          if on {
            ForEach(Array(x.option.plies.enumerated()), id: \.offset) { i, p in
              // 說明開頭的「你／對手」前面已經標了，拿掉
              let cap = x.option.captions?[safe: i].flatMap { $0.isEmpty ? nil : $0 }.map { c in
                ["你 ", "對手 "].reduce(c) { t, pre in t.hasPrefix(pre) ? String(t.dropFirst(pre.count)) : t }
              }
              HStack(alignment: .top, spacing: 6) {
                Text(p.mover == model.me ? "你" : "對手").font(.caption.weight(.bold)).foregroundStyle(p.mover == model.me ? Brand.orange : Brand.ink).frame(width: 30, alignment: .leading)
                Text(cap ?? p.san).font(.caption).foregroundStyle(Brand.ink.opacity((v?.cursor ?? 0) > i ? 1 : 0.45)).fixedSize(horizontal: false, vertical: true)
              }
            }
          }
          Text(x.verdict).font(.caption.weight(.medium)).foregroundStyle(x.kind == .played ? Color.red.opacity(0.85) : Color(hex: 0x15803D))
        }
        .padding(12).frame(maxWidth: .infinity, alignment: .leading)
        .background(on ? Brand.cream : Color(.secondarySystemBackground).opacity(0.6), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(on ? Brand.orange.opacity(0.6) : .clear, lineWidth: 1.5))
      }
      .buttonStyle(.plain)
    }
  }

  // MARK: 解說區

  @ViewBuilder private var coachPanel: some View {
    if let q = quick {
      QuickPanel(q: q) { ply in endQuick(); model.mode = .step; model.go(ply + 1) }
    } else { reviewPanel }
  }

  @ViewBuilder private var reviewPanel: some View {
    VStack(alignment: .leading, spacing: 12) {
      // 分數走勢：點或滑動跳到那一步
      if model.whiteWins.compactMap({ $0 }).count >= 3 && model.variation == nil {
        EvalGraph(white: model.whiteWins, current: model.current,
                  marks: model.records.compactMap { $0 }.filter { ($0.mover == model.me && $0.cls.isBad) || $0.cls == .brilliant || $0.cls == .great }.map { ($0.ply, $0.cls) },
                  flipped: false) { model.go($0) }
      }
      if model.following {
        HStack(spacing: 10) {
          ProgressView().tint(Brand.orange)
          VStack(alignment: .leading, spacing: 2) {
            Text("分析中 \(Int(model.progress * 100))%").font(.headline).monospacedDigit()
            Text("邊分析邊播放這局").font(.caption).foregroundStyle(.secondary)
          }
          Spacer()
          Button("先自己看") { model.stopFollowing() }.buttonStyle(.bordered).tint(Brand.orange)
        }
      } else if let c = model.compare {
        comparePanel(c)
      } else if let v = model.variation {
        HStack(alignment: .top, spacing: 10) {
          Image(systemName: "arrow.triangle.branch").font(.title3).foregroundStyle(.blue)
          VStack(alignment: .leading, spacing: 4) {
            Text(v.option.title).font(.headline).foregroundStyle(Brand.ink)
            if v.cursor > 0, let c = v.option.captions?[safe: v.cursor - 1], !c.isEmpty {
              Text(c).font(.subheadline).foregroundStyle(Brand.ink.opacity(0.85)).fixedSize(horizontal: false, vertical: true)
            } else if v.cursor == v.option.plies.count, let o = v.option.outcome {
              Text(o).font(.subheadline.weight(.medium)).foregroundStyle(Brand.ink.opacity(0.85))
            } else {
              Text(sourceText(v.option.source)).font(.subheadline).foregroundStyle(.secondary)
            }
          }
          Spacer(minLength: 0)
          evalPill(v.option.evalText ?? "…")
        }
        if model.mode == .free { freeStrip }
      } else if model.current == 0 && model.status.isEmpty {
        summaryPanel
      } else if let r = playedRecord, let p = playedPly {
        movePanel(r, p)
      } else if model.current > 0 {
        HStack { ProgressView(); Text("這一步還在分析…").foregroundStyle(.secondary) }
      } else {
        HStack { ProgressView(); Text(model.status.isEmpty ? "準備中…" : model.status).foregroundStyle(.secondary) }
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .animation(.snappy, value: model.current)
  }

  /// 這一步：大徽章＋「Nf3 是失誤」、白話解說、局面變化、可以做的事
  @ViewBuilder private func movePanel(_ r: MoveRecord, _ p: Ply) -> some View {
    let mine = r.mover == model.me
    HStack(alignment: .center, spacing: 10) {
      GradeBadge(cls: r.cls, size: 34)
      VStack(alignment: .leading, spacing: 2) {
        Text("\(mine ? "" : "對手 ")\(p.san) 是\(r.cls.zh)").font(.title3.bold()).foregroundStyle(r.cls.isBad ? r.cls.color : Brand.ink)
        HStack(spacing: 8) {
          Text(r.standingText(me: model.me)).font(.caption).foregroundStyle(.secondary)
          if let t = model.thinkTimes[safe: p.index] ?? nil {
            Label("想了 \(secondsText(t))", systemImage: "clock").font(.caption).foregroundStyle(t >= 30 ? Brand.orange : .secondary)
          }
        }
      }
      Spacer(minLength: 0)
      evalPill(model.evalText)
    }
    if model.mode == .free { freeStrip }
    if (r.cls.isKey || r.cls == .inaccuracy), let e = model.explanation(p.index) {
      VStack(alignment: .leading, spacing: 6) {
        Text(e.headline).font(.subheadline.weight(.semibold)).foregroundStyle(r.cls.isBad ? r.cls.color : Brand.ink)
        ForEach(Array(e.plainReasons.prefix(3).enumerated()), id: \.offset) { _, t in
          Text(t).font(.subheadline).foregroundStyle(Brand.ink.opacity(0.85)).fixedSize(horizontal: false, vertical: true)
        }
      }
      .padding(12).frame(maxWidth: .infinity, alignment: .leading)
      .background(Brand.cream, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    } else if let why = Explain.text(r, ply: p, before: model.evals[p.index] ?? nil, after: model.evals[p.index + 1] ?? nil) {
      Text(why).font(.subheadline).foregroundStyle(Brand.ink.opacity(0.85)).fixedSize(horizontal: false, vertical: true)
    }
    ScrollView(.horizontal, showsIndicators: false) {
      HStack(spacing: 8) {
        if r.cls.isBad || r.cls == .inaccuracy, let b = r.bestSan, b != r.san {
          chip("該走 \(b)", "star.fill", Brand.bestArrow) { showHint = true }
        }
        if r.cls.isKey || r.cls == .inaccuracy {
          chip("比較候選步", "arrow.triangle.branch", .blue) { model.openCompare(p.index) }
        }
        if mine && r.cls.isBad {
          chip("重走一下", "arrow.counterclockwise", Brand.orange) { openRetry(p.index) }
        }
        chip("深入分析", "magnifyingglass", Brand.ink) { exploreHere() }
      }
    }
    .scrollBounceBehavior(.basedOnSize, axes: .vertical)
    DbChip(fen: dbFen, played: p.san, rating: model.game.myRating, engine: model.evals[p.index] ?? nil) { sheet = .db }
  }

  /// 對局總覽（chess.com Game Review 的第一頁）：雙方準確率、各評級的步數，選要怎麼看
  @ViewBuilder private var summaryPanel: some View {
    let opp: Side = model.me == .white ? .black : .white
    HStack(spacing: 0) {
      accuracyBlock("你", model.accuracy(of: model.me), Brand.orange)
      accuracyBlock(model.game.opponent, model.accuracy(of: opp), Brand.ink)
    }
    let mine = Dictionary(uniqueKeysWithValues: model.counts(of: model.me))
    let theirs = Dictionary(uniqueKeysWithValues: model.counts(of: opp))
    VStack(spacing: 6) {
      ForEach(MoveClass.allCases.filter { $0 != .book }, id: \.self) { c in
        HStack {
          Text("\(mine[c] ?? 0)").font(.subheadline.monospacedDigit().weight(.semibold)).frame(width: 40, alignment: .leading).foregroundStyle(c.color)
          Spacer()
          HStack(spacing: 6) { GradeBadge(cls: c, size: 18); Text(c.zh).font(.subheadline) }
          Spacer()
          Text("\(theirs[c] ?? 0)").font(.subheadline.monospacedDigit().weight(.semibold)).frame(width: 40, alignment: .trailing).foregroundStyle(c.color)
        }
      }
    }
    .padding(12)
    .background(Brand.cream, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    FeedbackPromptCard(trigger: "review_done", task: "review")
    VStack(spacing: 8) {
      Button { start(.quick) } label: {
        Label("看重點（\(model.myMistakes.count) 個你的失誤）", systemImage: "forward.fill").font(.headline).frame(maxWidth: .infinity, minHeight: 46)
      }
      .buttonStyle(.borderedProminent).tint(Brand.orange)
      HStack(spacing: 8) {
        Button { start(.step) } label: { Text("逐步看").frame(maxWidth: .infinity, minHeight: 40) }.buttonStyle(.bordered).tint(Brand.ink)
        Button { model.mode = .free; step(1) } label: { Text("自由分析").frame(maxWidth: .infinity, minHeight: 40) }.buttonStyle(.bordered).tint(Brand.ink)
      }
    }
  }

  private func accuracyBlock(_ who: String, _ v: Double?, _ c: Color) -> some View {
    VStack(spacing: 2) {
      Text(v.map { String(format: "%.1f", $0) } ?? "—").font(.system(size: 30, weight: .bold, design: .rounded)).monospacedDigit().foregroundStyle(c)
      Text(who).font(.caption).foregroundStyle(.secondary).lineLimit(1)
    }
    .frame(maxWidth: .infinity)
  }

  private func start(_ m: ReviewModel.Mode) {
    model.mode = m
    Haptics.bump()
    model.togglePlay()
  }

  private var freeStrip: some View {
    CandidateStrip(items: freeCandidates, thinking: true) { uci in
      model.freeMove(String(uci.prefix(2)), String(uci.dropFirst(2).prefix(2)), promotion: uci.count == 5 ? String(uci.suffix(1)) : "")
    }
  }

  private func evalPill(_ t: String) -> some View {
    Text(t).font(.subheadline.monospacedDigit().bold()).padding(.horizontal, 8).padding(.vertical, 4)
      .background(Brand.ink, in: RoundedRectangle(cornerRadius: 6)).foregroundStyle(.white)
  }

  private func chip(_ t: String, _ icon: String, _ c: Color, action: @escaping () -> Void) -> some View {
    Button(action: action) { Label(t, systemImage: icon).font(.subheadline.weight(.medium)) }
      .buttonStyle(.bordered).buttonBorderShape(.capsule).tint(c)
  }

  /// 暫停時可以直接在棋盤上走：一走就換到深入分析（從這個局面、帶著這一步）
  private var canExplore: Bool {
    quick == nil && model.mode != .free && !model.playing && model.variation == nil && model.compare == nil && model.status.isEmpty && model.line != nil
  }

  private func exploreWith(_ from: String, _ to: String) {
    guard let line = model.line else { return }
    let promoted = FEN.pieces(fen)[from]?.last == "P" && (to.hasSuffix("8") || to.hasSuffix("1"))
    guard let p = ChessLine.ply(fen: fen, uci: from + to + (promoted ? "q" : ""), index: model.current) else { return }
    Sounds.play(for: p)
    explore = ExploreTarget(line: Array(line.plies.prefix(model.current)) + [p], start: line.startFen, at: model.current + 1)
  }

  private func exploreHere() {
    model.playing = false
    if let v = model.variation {
      explore = ExploreTarget(line: v.option.plies, start: v.option.startFen, at: v.cursor)
    } else if let line = model.line {
      explore = ExploreTarget(line: line.plies, start: line.startFen, at: model.current)
    }
  }

  private func sourceText(_ s: LineOption.Source) -> String {
    switch s {
    case .engine: "引擎的線"
    case let .database(games, share): "資料庫 \(games.formatted()) 局・\(share)% 的人這樣走"
    case .manual: "在棋盤上拖子繼續走，或點下面的候選步"
    }
  }

  // MARK: 最下面的操作列（固定）：選單、上一步、主按鈕、下一步、翻轉

  /// 這局快速復盤過了：回到分析頁時主按鈕縮小，上一步、下一步變大（之後多半是自己一步一步看）
  @State private var reviewed = false
  static func wasReviewed(_ id: String) -> Bool { (UserDefaults.standard.stringArray(forKey: "quickReviewed") ?? []).contains(id) }
  static func markReviewed(_ id: String) {
    var ids = UserDefaults.standard.stringArray(forKey: "quickReviewed") ?? []
    guard !ids.contains(id) else { return }
    ids.append(id)
    UserDefaults.standard.set(Array(ids.suffix(500)), forKey: "quickReviewed")
  }

  private var bottomBar: some View {
    HStack(spacing: 4) {
      if reviewed {
        // 復盤過了：主按鈕縮小、不搶眼
        Button(action: primary) {
          Text(primaryLabel == "開始復盤" ? "快速復盤" : primaryLabel).font(.subheadline.weight(.semibold)).lineLimit(1).minimumScaleFactor(0.8)
            .padding(.horizontal, 12).frame(minHeight: 44)
            .background(Color(.secondarySystemFill), in: RoundedRectangle(cornerRadius: 10, style: .continuous)).foregroundStyle(Brand.ink)
        }
        .buttonStyle(.plain)
      } else {
        // 主按鈕（開始復盤、下一個重點、播放…）在左邊
        Button(action: primary) {
          Text(primaryLabel).font(.headline).lineLimit(1).minimumScaleFactor(0.8)
            .frame(maxWidth: .infinity, minHeight: 48)
            .background(Brand.orange, in: RoundedRectangle(cornerRadius: 12, style: .continuous)).foregroundStyle(.white)
        }
        .buttonStyle(.plain)
        .padding(.trailing, 4)
      }
      Menu {
        Picker("看法", selection: $model.mode) { ForEach(ReviewModel.Mode.allCases) { Text($0.zh).tag($0) } }
        Toggle("最佳步提示", isOn: $showHint)
        Button { openLesson() } label: { Label("快速復盤", systemImage: "graduationcap") }.disabled(!model.status.isEmpty)
        Button { sheet = .keys } label: { Label(model.myMistakes.isEmpty ? "關鍵步（\(model.keyMoves.count)）" : "你的失誤（\(model.myMistakes.count)）", systemImage: "flag") }
        Button { sheet = .db } label: { Label("大家怎麼走", systemImage: "person.2") }
        Button { exploreHere() } label: { Label("深入分析", systemImage: "magnifyingglass") }
        Button { model.go(0) } label: { Label("回到總覽", systemImage: "list.bullet.rectangle") }
      } label: {
        barIcon("ellipsis.circle", "選單")
      }
      Button { flipped.toggle() } label: { barIcon("arrow.up.arrow.down", "翻轉棋盤") }.buttonStyle(.plain)
      // 上一步、下一步一起放右邊（右手拇指好按）；復盤過之後變成大按鈕
      if reviewed {
        RepeatButton(action: { step(-1) }) { stepButton("chevron.left", "上一步（按住快退）") }
        RepeatButton(action: { step(1) }) { stepButton("chevron.right", "下一步（按住快轉）") }
      } else {
        RepeatButton(action: { step(-1) }) { barIcon("chevron.left", "上一步（按住快退）") }
        RepeatButton(action: { step(1) }) { barIcon("chevron.right", "下一步（按住快轉）") }
      }
    }
    .padding(.horizontal, 10).padding(.top, 8).padding(.bottom, 4)
    .background(.bar)
    .overlay(alignment: .top) { Divider() }
    .onAppear { reviewed = Self.wasReviewed(model.game.id) }
  }

  private func stepButton(_ name: String, _ label: String) -> some View {
    Image(systemName: name).font(.system(size: 20, weight: .bold)).foregroundStyle(.white)
      .frame(maxWidth: .infinity, minHeight: 48)
      .background(Brand.orange, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
      .contentShape(Rectangle()).accessibilityLabel(label)
  }

  private func barIcon(_ name: String, _ label: String) -> some View {
    Image(systemName: name).font(.system(size: 18, weight: .semibold)).foregroundStyle(Brand.ink)
      .frame(width: 48, height: 48).contentShape(Rectangle()).accessibilityLabel(label)
  }

  /// 主按鈕：快速重點 → 下一個重點；逐步 → 播放／暫停；自由 → 下一步；延伸中 → 播這條線
  private var primaryLabel: String {
    if model.compare != nil { return "回到這一手" }
    if model.variation != nil { return model.playing ? "暫停" : "播放這條線" }
    if model.current == 0 && model.status.isEmpty && !model.playing { return "開始復盤" }
    if model.mode == .free { return "下一步" }
    if model.playing { return "暫停" }
    if model.current >= model.count { return "重新看" }
    return model.mode == .quick ? "下一個重點" : "播放"
  }

  /// 開始快速復盤：先把所有要用的東西備好（重點、每一步的名稱與解說、答案），再從頭快速播。
  /// 準備中還是載入畫面；一次算一小段就讓出主執行緒，動畫不會停
  private func openLesson() {
    guard model.status.isEmpty, quick == nil, !preparing, let line = model.line else { loading = false; return }
    preparing = true
    model.stopFollowing()
    model.playing = false
    Task {
      let items = GameHighlight.build(model)
      var tags: [String] = []
      for p in line.plies {
        let r = model.records[safe: p.index] ?? nil
        // 關鍵步、走差的步用網站解說的標題（戰術名稱）
        let e = r.flatMap { $0.cls.isKey || $0.cls == .inaccuracy ? model.explanation(p.index) : nil }
        tags.append(MoveTags.tag(p, explanation: e))
        if p.index % 4 == 3 { await Task.yield() }
      }
      preparing = false
      loading = false
      guard !items.isEmpty else { start(.quick); return }
      Self.markReviewed(model.game.id)
    Telemetry.log("quick_review_start", ["plies": line.plies.count])
    reviewed = true
    let q = QuickReview(line: line, highlights: items, me: model.me, records: model.records, evals: model.evals, whiteWins: model.whiteWins, tags: tags,
                        resigned: model.game.opponentResigned)
      quick = q
      q.start()
    }
  }

  /// 逐步復盤停在錯失良機（或失誤）：在同一個棋盤上重走這一步，走完回到這一手之後
  private func openRetry(_ ply: Int) {
    guard quick == nil, let line = model.line, let h = GameHighlight.single(model, ply: ply) else { return }
    model.playing = false
    let q = QuickReview(line: line, highlights: [h], me: model.me, records: model.records, evals: model.evals, whiteWins: model.whiteWins, tags: [])
    quick = q
    Telemetry.log("move_retry", ["cls": h.record.cls.rawValue])
    q.startSingle { endQuick(); model.go(ply + 1) }
  }

  private func endQuick() {
    quick?.stop()
    quick = nil
  }

  private func quickTargets(_ q: QuickReview, _ sq: String) -> [String] {
    guard let code = FEN.pieces(q.fen)[sq], (code.first == "w") == (model.me == .white) else { return [] }
    return FEN.targets(fen: q.fen, from: sq)
  }

  private var isLoading: Bool { loading || preparing || !model.status.isEmpty }

  /// 快速復盤時的棋譜條：播到第幾手（不顯示評級）
  private func quickStrip(_ q: QuickReview) -> some View {
    HStack(spacing: 10) {
      Text(q.pos == 0 ? "開始" : "第 \((q.pos + 1) / 2) 手").font(.caption.monospacedDigit().weight(.semibold)).foregroundStyle(Brand.ink)
      ProgressView(value: Double(q.pos), total: Double(max(q.line.plies.count, 1))).tint(Brand.orange)
    }
    .padding(.horizontal, 14).frame(height: 30)
  }

  /// 快速復盤的操作列：找步時是提示、看答案；播放時可以跳到下一個重點；隨時可以結束
  private func quickBar(_ q: QuickReview) -> some View {
    HStack(spacing: 8) {
      Button { endQuick() } label: { barIcon("xmark", "結束快速復盤") }.buttonStyle(.plain)
      Group {
        switch q.phase {
        case .trying:
          HStack(spacing: 8) {
            if !q.hint { quickButton("提示", prominent: false) { q.hint = true; Haptics.tick() } }
            quickButton("看答案", prominent: false) { q.reveal() }
          }
        case .playing:
          quickButton("跳到下一個重點", prominent: true) { q.skipAhead() }
            .disabled(!q.highlights.contains { $0.interactive && $0.record.ply >= q.pos })
        case .praise:
          quickButton("繼續", prominent: true) { q.continuePraise() }
        case .solved, .revealed:
          Text(q.phase == .solved ? "找到了！接著播…" : "接著播…").font(.subheadline.weight(.semibold)).foregroundStyle(.secondary).frame(maxWidth: .infinity, minHeight: 48)
        case .done:
          quickButton("逐步看整局", prominent: true) { endQuick(); model.mode = .step; model.go(0) }
        }
      }
      Button { flipped.toggle() } label: { barIcon("arrow.up.arrow.down", "翻轉棋盤") }.buttonStyle(.plain)
    }
    .padding(.horizontal, 10).padding(.top, 8).padding(.bottom, 4)
    .background(.bar)
    .overlay(alignment: .top) { Divider() }
  }

  private func quickButton(_ text: String, prominent: Bool, _ action: @escaping () -> Void) -> some View {
    Button { Haptics.bump(); action() } label: {
      Text(text).font(.headline).lineLimit(1).minimumScaleFactor(0.8)
        .frame(maxWidth: .infinity, minHeight: 48)
        .background(prominent ? Brand.orange : Color(.secondarySystemFill), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .foregroundStyle(prominent ? .white : Brand.ink)
    }
    .buttonStyle(.plain)
  }

  private func primary() {
    Haptics.bump()
    if model.compare != nil { model.closeCompare(); return }
    if model.variation != nil { model.playing ? (model.playing = false) : model.playVariation(); return }
    // 總覽頁：跟 chess.com 一樣按一下就從第一個重點開始
    if model.current == 0 && model.status.isEmpty && !model.playing && model.mode != .free { openLesson(); return }
    if model.mode == .free { step(1); return }
    model.togglePlay()
  }

}

/// 勝率條（白方在下）
struct EvalBar: View {
  let white: Double
  var flipped = false
  var body: some View {
    GeometryReader { g in
      let h = g.size.height * (flipped ? 1 - white : white)
      ZStack(alignment: .bottom) {
        Rectangle().fill(flipped ? Color(hex: 0xF4EFE6) : Brand.ink)
        Rectangle().fill(flipped ? Brand.ink : Color(hex: 0xF4EFE6)).frame(height: h)
      }
    }
    .frame(width: 10)
    .clipShape(Capsule())
    .animation(.easeInOut(duration: 0.4), value: white)
    .accessibilityLabel("白方勝率 \(Int(white * 100))%")
  }
}

struct KeyMovesSheet: View {
  let model: ReviewModel
  let close: () -> Void
  var body: some View {
    NavigationStack {
      List(model.keyMoves, id: \.ply) { r in
        Button { model.go(r.ply + 1); close() } label: {
          VStack(alignment: .leading, spacing: 4) {
            HStack {
              GradeBadge(cls: r.cls, size: 20)
              Text("\(r.ply / 2 + 1)\(r.mover == .white ? "." : "…") \(r.san)").monospacedDigit()
              Spacer()
              Text(r.mover == model.me ? r.cls.zh : "對手\(r.cls.zh)").font(.caption).foregroundStyle(r.cls.color)
            }
            if let e = model.explanation(r.ply) {
              Text(e.headline).font(.caption.weight(.semibold)).foregroundStyle(r.cls.color)
              if let first = e.plainReasons.first { Text(first).font(.caption).foregroundStyle(.secondary).lineLimit(3) }
            }
          }
        }
        .foregroundStyle(Brand.ink)
      }
      .navigationTitle("這盤的關鍵步").navigationBarTitleDisplayMode(.inline)
    }
  }
}

/// 延伸棋局：先用白話講為什麼（網站解說），再比「你走的」和「該走的」兩條路各自的結果，
/// 最後是資料庫裡真人常見的接法。點一條在棋盤上播，每一步都有說明
struct LinesSheet: View {
  let key: String
  let record: MoveRecord
  let ply: Ply
  let me: Side
  let explanation: ExplainJS.Explanation?
  let before: [EngineLine]?
  let after: [EngineLine]?
  let pick: (LineOption) -> Void
  @State private var options: [LineOption]?

  /// 網站解說的兩條路（你走的、該走的），帶每一步的說明
  private var paths: [LineOption] {
    (explanation?.lines ?? []).compactMap { LineOption($0, base: $0.kind == "played" ? ply.index + 1 : ply.index) }
  }

  var body: some View {
    NavigationStack {
      List {
        Section {
          if let e = explanation {
            Text(e.headline).font(.headline).foregroundStyle(record.cls.isBad ? record.cls.color : Brand.ink)
            ForEach(Array(e.plainReasons.enumerated()), id: \.offset) { _, t in
              Label { Text(t).font(.subheadline) } icon: { Image(systemName: "circle.fill").font(.system(size: 5)) }
            }
          } else if let why = Explain.text(record, ply: ply, before: before, after: after) {
            Text(why).font(.subheadline)
          }
          Text(record.standingText(me: me)).font(.caption).foregroundStyle(.secondary)
        }
        if !paths.isEmpty {
          Section {
            ForEach(paths) { row($0) }
          } header: {
            Text("兩條路比一比")
          } footer: {
            Text("點一條在棋盤上播，每一步都會說明在做什麼。")
          }
        }
        let human = (options ?? []).filter { if case .database = $0.source { true } else { false } }
        let alt = (options ?? []).filter { $0.id == "alt" }
        if !alt.isEmpty { Section("也可以這樣走") { ForEach(alt) { row($0) } } }
        Section {
          if options == nil { HStack { ProgressView(); Text("找真人常見的接法…").foregroundStyle(.secondary) } }
          else if human.isEmpty { Text("資料庫裡這個局面的對局太少。").font(.footnote).foregroundStyle(.secondary) }
          ForEach(human) { row($0) }
        } header: {
          Text("真人常見的接法")
        } footer: {
          Text("每一步都走資料庫裡最多人走的那一步（Lichess 快棋以上的對局），比較接近對局中真的會發生的。")
        }
      }
      .navigationTitle("這一步怎麼了").navigationBarTitleDisplayMode(.inline)
    }
    .task {
      if let hit = Continuations.cached(key) { options = hit; return }
      options = await Continuations.get(key, record, ply: ply, before: before, after: after)
    }
  }

  private func row(_ o: LineOption) -> some View {
    Button { pick(o) } label: {
      VStack(alignment: .leading, spacing: 4) {
        HStack {
          Text(o.title).font(.subheadline.weight(.semibold)).foregroundStyle(Brand.ink)
          Spacer()
          Image(systemName: "play.circle.fill").foregroundStyle(Brand.orange)
        }
        if let out = o.outcome {
          Text(out).font(.caption).foregroundStyle(Brand.ink.opacity(0.8))
        } else if case let .database(games, share) = o.source {
          Text("\(games.formatted()) 局・\(share)% 的人走這步").font(.caption).foregroundStyle(.blue)
        }
        Text(o.preview).font(.caption2.monospaced()).foregroundStyle(.secondary).lineLimit(1)
      }
    }
  }
}

/// 對手投降：棋盤上舉白旗（揮動），寫「對手投降了」
struct ResignFlag: View {
  let name: String
  @State private var wave = false
  @State private var shown = true

  var body: some View {
    if shown {
      VStack(spacing: 8) {
        Image(systemName: "flag.fill")
          .font(.system(size: 64, weight: .bold))
          .foregroundStyle(.white)
          .shadow(color: .black.opacity(0.35), radius: 3)
          .overlay(Image(systemName: "flag").font(.system(size: 64, weight: .bold)).foregroundStyle(Brand.ink))
          .rotationEffect(.degrees(wave ? 10 : -10), anchor: .bottomLeading)
          .animation(.easeInOut(duration: 0.45).repeatForever(autoreverses: true), value: wave)
        Text("\(name) 投降了").font(.headline).foregroundStyle(Brand.ink)
        Text("你贏了這局").font(.subheadline).foregroundStyle(Brand.ink.opacity(0.75))
      }
      .padding(.horizontal, 24).padding(.vertical, 18)
      .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
      .onAppear { wave = true; Haptics.bump() }
      .onTapGesture { withAnimation { shown = false } }
      .task {
        try? await Task.sleep(nanoseconds: 3_000_000_000)
        withAnimation(.easeOut(duration: 0.4)) { shown = false }
      }
    }
  }
}
