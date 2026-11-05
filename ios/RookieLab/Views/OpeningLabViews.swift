import SwiftUI

struct OpeningPracticeView: View {
  @Environment(AppModel.self) private var app
  @State private var count = 20
  @State private var profiles: [OpeningProfile] = []
  @State private var scanning = false
  @State private var review = OpeningReviewStore.shared
  private var account: String { OpeningRoute.learner }

  var body: some View {
    List {
      Section {
        NavigationLink { OpeningAnalysisView(account: account) } label: {
          Label { VStack(alignment: .leading, spacing: 4) {
            Text("開局分析板").font(.headline)
            Text("從第一步探索理論、比較不同變化").font(.caption).foregroundStyle(.secondary)
          } } icon: { Image(systemName: "square.grid.3x3.fill").foregroundStyle(Brand.orange) }
        }
      }
      Section {
        if let current = app.account, !app.usingImported {
          Picker("帳號", selection: Binding(get: { current }, set: { app.use($0) })) {
            ForEach(app.accounts) { a in Text("\(a.platform.name) · \(a.username)").tag(a) }
          }
          Picker("最近對局", selection: $count) { Text("10 局").tag(10); Text("20 局").tag(20) }.pickerStyle(.segmented)
          if app.loading || scanning { ProgressView("整理開局中…") }
          if let error = app.error {
            Text(error).font(.caption).foregroundStyle(.secondary)
            Button("重新載入") { Task { await app.load() } }
          }
          if !scanning && profiles.isEmpty { Text("目前沒有可整理的對局，仍可從分析板開始探索。").font(.subheadline).foregroundStyle(.secondary) }
        } else {
          NavigationLink("新增 Chess.com／Lichess 帳號") { OpeningAccountView() }
          Text(app.games.isEmpty ? String(localized: "不用帳號也可以學習開局。") : String(localized: "目前整理的是匯入的對局。")).font(.caption).foregroundStyle(.secondary)
          Picker("最近對局", selection: $count) { Text("10 局").tag(10); Text("20 局").tag(20) }.pickerStyle(.segmented)
        }
      } header: { Text("你的開局") } footer: { Text("使用同一種時間制的最近對局。熟悉度只描述理論走法，不代表棋力；離開理論不等於走錯。") }
      if let suggested = profiles.first(where: { $0.games >= 3 && $0.leftByMe * 2 >= $0.games }) {
        Section("值得先練") {
          NavigationLink { OpeningDetailView(profile: suggested, account: account) } label: {
            VStack(alignment: .leading, spacing: 4) {
              Text(suggested.family).font(.headline)
              Text("\(suggested.games) 局裡有 \(suggested.leftByMe) 局是你先離開理論，先練常遇到的前幾步。").font(.subheadline).foregroundStyle(.secondary)
            }
          }
        }
      }
      ForEach([Side.white, .black], id: \.rawValue) { side in
        let rows = profiles.filter { $0.side == side }
        if !rows.isEmpty {
          Section(side == .white ? String(localized: "執白") : String(localized: "執黑")) {
            ForEach(rows) { profile in
              NavigationLink { OpeningDetailView(profile: profile, account: account) } label: {
                VStack(alignment: .leading, spacing: 5) {
                  Text(profile.family).font(.headline)
                  Text("\(profile.games) 局 · 理論平均 \(profile.average, specifier: "%.1f") 步").font(.caption).foregroundStyle(.secondary)
                  Text(profile.status).font(.caption).foregroundStyle(profile.leftByMe > 0 ? Brand.orange : .secondary)
                }
              }
            }
          }
        }
      }
      Section {
        ForEach(review.active(account: account)) { card in
          NavigationLink { OpeningExerciseView(route: card.route, review: true) } label: {
            VStack(alignment: .leading, spacing: 4) {
              Text(card.route.name)
              Text(card.mastered ? String(localized: "已熟練") : card.due <= Day.number() ? String(localized: "可以複習了") : String(localized: "下次複習：\(Day.date(card.due).formatted(date: .abbreviated, time: .omitted))")).font(.caption).foregroundStyle(.secondary)
            }
          }
          .swipeActions { Button("移除", role: .destructive) { review.remove(card.id) } }
        }
        if review.active(account: account).isEmpty { Text("在分析板走出一條理論路線，就能加入每日複習。").font(.subheadline).foregroundStyle(.secondary) }
      } header: { Text("我的開局複習") }
      Section { Text("開局理論：Lichess chess-openings（CC0）。已隨 App 下載，離線也能探索與練習。").font(.caption).foregroundStyle(.secondary) }
    }
    .navigationTitle("開局練習")
    .task(id: "\(account):\(count):\(app.games.hashValue)") {
      scanning = true; profiles = []
      let key = GameType.pick(app.games)
      let games = Array(app.games.filter { GameType.key($0) == key }.prefix(count))
      let result = await Task.detached(priority: .userInitiated) { OpeningProfile.build(games: games) }.value
      guard !Task.isCancelled else { return }
      profiles = result; scanning = false
    }
  }
}

struct OpeningDetailView: View {
  let profile: OpeningProfile
  let account: String
  var body: some View {
    List {
      Section {
        Text(profile.status).foregroundStyle(Brand.orange)
        if let course = OpeningCourse.all.first(where: { $0.side == profile.side && ($0.family.text == profile.family || profile.family.contains($0.family.text)) }) {
          NavigationLink { OpeningCourseView(course: course) } label: { Label("學這個開局", systemImage: "graduationcap.fill").foregroundStyle(Brand.orange) }
        }
        Text("\(profile.games) 局：\(profile.wins) 勝、\(profile.draws) 和、\(profile.games - profile.wins - profile.draws) 負")
        Text("你先離開理論 \(profile.leftByMe) 次，對手先離開 \(profile.leftByOpponent) 次。").font(.subheadline).foregroundStyle(.secondary)
        NavigationLink { OpeningAnalysisView(line: profile.line, side: profile.side, account: account) } label: { Label("探索這個開局", systemImage: "square.grid.3x3") }
        if route.valid {
          NavigationLink { OpeningExerciseView(route: route, review: false) } label: { Label("練這條路線", systemImage: "play.circle.fill") }
          OpeningAddButton(route: route)
        }
      } footer: { Text("勝負是整局結果，不直接代表開局表現。可練路線取自最近的實戰理論，最多 6 手。") }
      Section("你離開理論的地方") {
        ForEach(profile.departures) { departure in
          NavigationLink { OpeningAnalysisView(line: departure.line, side: profile.side, account: account, played: departure.played) } label: {
            VStack(alignment: .leading, spacing: 4) {
              Text("第 \(departure.played.moveNumber) 手 · 你走了 \(departure.played.san)")
              Text("\(departure.game.dateText) · vs \(departure.game.opponent)").font(.caption).foregroundStyle(.secondary)
            }
          }
        }
        if profile.departures.isEmpty { Text("這些對局沒有你先離開理論的局面。").foregroundStyle(.secondary) }
      }
    }
    .navigationTitle(profile.family).navigationBarTitleDisplayMode(.inline)
  }
  private var route: OpeningRoute { .init(account: account, name: profile.family, side: profile.side, moves: profile.line.map(\.uci)) }
}

struct OpeningAnalysisView: View {
  @State private var model: AnalysisModel
  @State private var flipped: Bool
  @State private var side: Side
  @State private var candidates: [OpeningBook.Candidate] = []
  @State private var promotion: (String, String)?
  private let account: String
  private let played: Ply?
  init(line: [Ply] = [], side: Side = .white, account: String, played: Ply? = nil, at: Int? = nil) {
    _model = State(initialValue: AnalysisModel(plies: line, at: at))
    _side = State(initialValue: side); _flipped = State(initialValue: side == .black)
    self.account = account; self.played = played
  }
  private var path: [Ply] { Array(model.plies.prefix(model.cursor)) }
  private var canPractice: Bool {
    !path.isEmpty && path.count <= 24 && path.contains { $0.mover == side } && (OpeningBook.shared.isTheory(path) || OpeningCourse.contains(path.map(\.uci)))
  }
  private var route: OpeningRoute {
    .init(account: account, name: OpeningBook.shared.position(model.fen).map { Openings.name($0.name) } ?? String(localized: "我的開局路線"), side: side, moves: path.map(\.uci))
  }
  var body: some View {
    GeometryReader { geo in
      VStack(spacing: 8) {
        HStack(spacing: 6) {
          EvalBar(white: model.whiteWin, flipped: flipped)
          ZStack {
            BoardView(fen: model.fen, flipped: flipped, highlight: model.last.map { [$0.from, $0.to] } ?? [], legalTargets: { model.targets($0) }, onMove: { from, to in
              if model.needsPromotion(from, to) { promotion = (from, to) } else { model.move(from, to) }
            })
            if let promotion { PromotionPicker(white: FEN.sideToMove(model.fen) == .white) { choice in
              if let choice { model.move(promotion.0, promotion.1, promotion: choice) }; self.promotion = nil
            } }
          }
          .frame(width: min(geo.size.width - 44, geo.size.height * 0.49), height: min(geo.size.width - 44, geo.size.height * 0.49))
        }
        .frame(height: min(geo.size.width - 44, geo.size.height * 0.49))
        ScrollView {
          VStack(alignment: .leading, spacing: 12) {
            HStack {
              Text(OpeningBook.shared.position(model.fen).map { Openings.name($0.name) } ?? (model.cursor == 0 ? String(localized: "起始局面") : String(localized: "已離開收錄的開局理論"))).font(.headline)
              Spacer()
              if let line = model.lines.first { Text(model.evalText(line)).monospacedDigit().font(.subheadline.bold()) }
              else if model.thinking { ProgressView().controlSize(.small) }
            }
            Text("引擎分數以白方為準；＋是白方較好。非理論走法不一定是壞棋。").font(.caption).foregroundStyle(.secondary)
            if let played, OpeningBook.key(played.fenBefore) == OpeningBook.key(model.fen) { Text("你當時走了 \(played.san)").font(.subheadline).foregroundStyle(Brand.orange) }
            ScrollView(.horizontal) {
              HStack {
                Button("開始") { model.cursor = 0 }
                ForEach(Array(model.plies.enumerated()), id: \.offset) { i, ply in
                  Button("\(ply.moveNumber)\(ply.mover == .white ? "." : "…") \(ply.san)") { model.cursor = i + 1 }
                    .foregroundStyle(model.cursor == i + 1 ? Brand.orange : Brand.ink)
                }
              }.font(.caption.monospaced()).buttonStyle(.bordered)
            }
            if model.branches.count > 1 {
              Text("這裡試過的變化").font(.subheadline.bold())
              HStack { ForEach(model.branches, id: \.uci) { ply in Button(ply.san) { model.play(uci: ply.uci) }.buttonStyle(.bordered) } }
            }
            Text("理論候選步").font(.subheadline.bold())
            ForEach(candidates) { candidate in
              Button { model.play(uci: candidate.uci) } label: {
                HStack {
                  Text(candidate.san).font(.headline.monospaced()).frame(width: 56, alignment: .leading)
                  VStack(alignment: .leading, spacing: 3) {
                    Text(Openings.name(candidate.name)).font(.subheadline)
                    Text("後續 \(candidate.lines) 條變化").font(.caption).foregroundStyle(.secondary)
                  }
                  Spacer()
                  if let evaluation = model.candidates.first(where: { $0.uci == candidate.uci })?.eval { Text(evaluation).font(.caption.monospaced()) }
                  Image(systemName: "chevron.right").font(.caption)
                }.padding(10).background(Brand.cream, in: RoundedRectangle(cornerRadius: 10))
              }.buttonStyle(.plain)
            }
            if candidates.isEmpty { Text("目前沒有收錄的理論續步，可以繼續自由走子，或退回前一步比較。").font(.subheadline).foregroundStyle(.secondary) }
            Text("引擎建議").font(.subheadline.bold())
            CandidateStrip(items: model.candidates, thinking: model.thinking) { model.play(uci: $0) }
            Picker("練習顏色", selection: $side) { Text("執白").tag(Side.white); Text("執黑").tag(Side.black) }.pickerStyle(.segmented)
            if canPractice {
              NavigationLink { OpeningExerciseView(route: route, review: false) } label: { Label("練這條路線", systemImage: "play.fill").frame(maxWidth: .infinity) }.buttonStyle(.borderedProminent).tint(Brand.orange)
              OpeningAddButton(route: route, validated: true)
            } else {
              Text("先走出一條完整的理論路線（最多 12 手），就能自己練並加入每日複習。").font(.caption).foregroundStyle(.secondary)
            }
          }.padding(.horizontal, 14).padding(.bottom, 8)
        }
      }
      .frame(maxWidth: .infinity)
    }
    .safeAreaInset(edge: .bottom) {
      HStack {
        Button { model.cursor = 0 } label: { Image(systemName: "backward.end").frame(minWidth: 44, minHeight: 44) }.accessibilityLabel("回到開始")
        Button { model.step(-1) } label: { Image(systemName: "chevron.left").frame(minWidth: 44, minHeight: 44) }.disabled(model.cursor == 0).accessibilityLabel("上一步")
        Button { model.step(1) } label: { Image(systemName: "chevron.right").frame(minWidth: 44, minHeight: 44) }.accessibilityLabel("下一步")
        Spacer()
        Button { flipped.toggle() } label: { Image(systemName: "arrow.up.arrow.down").frame(minWidth: 44, minHeight: 44) }.accessibilityLabel("翻轉棋盤")
      }.padding(.horizontal).background(.bar)
    }
    .background(Brand.paper)
    .navigationTitle("開局分析板").navigationBarTitleDisplayMode(.inline).toolbar(.hidden, for: .tabBar)
    .task(id: model.fen) {
      let fen = model.fen; candidates = []
      let result = await Task.detached(priority: .userInitiated) { OpeningBook.shared.candidates(fen) }.value
      guard !Task.isCancelled, model.fen == fen else { return }; candidates = result
    }
    .onAppear { model.analyse() }.onDisappear { model.stop() }
  }
}

struct OpeningAddButton: View {
  let route: OpeningRoute
  var validated = false
  var recalled: Bool? = nil
  @State private var store = OpeningReviewStore.shared
  var body: some View {
    Button {
      if store.has(route) { store.remove(route.id) }
      else if store.add(route), let recalled { store.answer(route.id, clean: recalled) }
    } label: {
      Label(store.has(route) ? String(localized: "已加入每日複習（點一下取消）") : String(localized: "加入每日複習"), systemImage: store.has(route) ? "checkmark.circle.fill" : "plus.circle")
    }.disabled(!validated && !route.valid).tint(Brand.orange)
  }
}

struct OpeningExerciseView: View {
  @State private var exercise: OpeningExercise
  @State private var recorded = false
  @State private var evaluation: EngineLine?
  @State private var evaluatedFen: String?
  @State private var evaluating = false
  @State private var showAnalysis = false
  @State private var promotion: (String, String)?
  @Environment(\.dismiss) private var dismiss
  private let review: Bool
  private let completion: (() -> Void)?
  private let title: String?
  private let onResult: ((OpeningRoute, Bool) -> Void)?
  private let onProgress: ((OpeningRoute, Int, Bool) -> Void)?
  init(route: OpeningRoute, review: Bool, completion: (() -> Void)? = nil, alternatives: [OpeningRoute] = [], at: Int = 0, clean: Bool = true,
       title: String? = nil, onResult: ((OpeningRoute, Bool) -> Void)? = nil, onProgress: ((OpeningRoute, Int, Bool) -> Void)? = nil) {
    _exercise = State(initialValue: OpeningExercise(route: route, alternatives: alternatives, at: at, clean: clean))
    self.review = review; self.completion = completion; self.title = title; self.onResult = onResult; self.onProgress = onProgress
  }
  private var whiteWin: Double {
    guard evaluatedFen == exercise.fen, let evaluation else { return 0.5 }
    let win = Grading.winProb(evaluation)
    return FEN.sideToMove(exercise.fen) == .white ? win : 1 - win
  }
  var body: some View {
    GeometryReader { geo in
      VStack(spacing: 12) {
        ProgressView(value: Double(exercise.completed), total: Double(max(1, exercise.total))).tint(Brand.orange).padding(.horizontal)
        Text("已走 \(exercise.completed)／\(exercise.total) 步").font(.caption).foregroundStyle(.secondary)
        HStack(spacing: 6) {
          EvalBar(white: whiteWin, flipped: exercise.route.side == .black)
          ZStack {
            BoardView(fen: exercise.fen, flipped: exercise.route.side == .black,
              arrows: exercise.hint && !exercise.finished ? exercise.expected.map { [Arrow(from: $0.from, to: $0.to, color: Brand.orange)] } ?? [] : [],
              legalTargets: { exercise.finished ? [] : FEN.targets(fen: exercise.fen, from: $0) },
              onMove: { from, to in
                if FEN.pieces(exercise.fen)[from]?.last == "P" && (to.hasSuffix("8") || to.hasSuffix("1")) { promotion = (from, to) }
                else { exercise.move(from + to) }
              })
            if let promotion { PromotionPicker(white: FEN.sideToMove(exercise.fen) == .white) { choice in
              if let choice { exercise.move(promotion.0 + promotion.1 + choice) }; self.promotion = nil
            } }
          }.frame(width: min(geo.size.width - 44, geo.size.height * 0.55), height: min(geo.size.width - 44, geo.size.height * 0.55))
        }
        .frame(height: min(geo.size.width - 44, geo.size.height * 0.55))
        HStack(spacing: 6) {
          if let evaluation, evaluatedFen == exercise.fen {
            let sign = FEN.sideToMove(exercise.fen) == .white ? 1 : -1
            Text(Grading.evalText(cp: evaluation.cp.map { $0 * sign }, mate: evaluation.mate.map { $0 * sign })).monospacedDigit().bold()
          } else if evaluating { ProgressView().controlSize(.mini) }
          else { Text("—") }
          Text("白方視角・＋是白方較好").foregroundStyle(.secondary)
        }.font(.caption)
        ScrollView {
          VStack(spacing: 12) {
            if exercise.finished {
              Label("這條路線走完了", systemImage: "checkmark.circle.fill").font(.title3.bold()).foregroundStyle(.green)
              Text(exercise.clean ? String(localized: "這次自己走完了，下次換個時間再練。") : String(localized: "這次有參考提示或重新嘗試，下次再自己走一遍。")).font(.subheadline)
              OpeningAddButton(route: exercise.route, recalled: exercise.clean)
            } else if let feedback = exercise.feedback { Text(feedback).font(.subheadline).foregroundStyle(Brand.orange) }
            else { Text("輪到你，走出這條路線的下一步。").font(.subheadline) }
          }.padding(.horizontal)
        }
        Spacer(minLength: 0)
      }.frame(maxWidth: .infinity)
    }
    .safeAreaInset(edge: .bottom) {
      HStack {
        if exercise.finished {
          Button(completion == nil ? String(localized: "完成") : String(localized: "繼續今天的練習")) { if let completion { completion() } else { dismiss() } }.buttonStyle(.borderedProminent).tint(Brand.orange)
        } else {
          Button("提示") { exercise.showHint() }.buttonStyle(.bordered)
          Button("到分析板看看") { exercise.explored(); showAnalysis = true }.buttonStyle(.bordered)
        }
      }.frame(maxWidth: .infinity).padding(12).background(.bar)
    }
    .background(Brand.paper).navigationTitle(title ?? exercise.route.name).navigationBarTitleDisplayMode(.inline).toolbar(.hidden, for: .tabBar)
    .sheet(isPresented: $showAnalysis) {
      NavigationStack {
        OpeningAnalysisView(line: exercise.plies, side: exercise.route.side, account: exercise.route.account, at: exercise.cursor)
          .toolbar { ToolbarItem(placement: .confirmationAction) { Button("回到練習") { showAnalysis = false } } }
      }
    }
    .task(id: "\(exercise.fen):\(showAnalysis)") {
      evaluation = nil; evaluatedFen = nil; evaluating = false
      guard !showAnalysis else { return }
      let fen = exercise.fen; evaluating = true
      try? await Task.sleep(for: .milliseconds(100))
      guard !Task.isCancelled else { return }
      let lines = await StockfishService.shared.analyse(fen: fen, nodes: 150_000, multipv: 1, priority: .interactive)
      guard !Task.isCancelled, fen == exercise.fen, !showAnalysis else { return }
      evaluation = lines.first; evaluatedFen = fen; evaluating = false
    }
    .onChange(of: exercise.finished, initial: true) { _, finished in
      guard finished, !recorded else { return }; recorded = true
      if review || OpeningReviewStore.shared.has(exercise.route) { OpeningReviewStore.shared.answer(exercise.route.id, clean: exercise.clean) }
      onResult?(exercise.route, exercise.clean)
      ReviewStore.shared.markPracticed()
    }
    .onChange(of: exercise.cursor) { _, value in onProgress?(exercise.route, value, exercise.clean) }
    .onChange(of: exercise.clean) { _, value in onProgress?(exercise.route, exercise.cursor, value) }
  }
}

struct OpeningDailyView: View {
  let routes: [OpeningRoute]
  let completion: (Bool) -> Void
  @State private var index = 0
  var body: some View {
    NavigationStack {
      if routes.indices.contains(index) {
        OpeningExerciseView(route: routes[index], review: true) {
          if index + 1 < routes.count { index += 1 } else { completion(true) }
        }.id(index)
          .toolbar { ToolbarItem(placement: .cancellationAction) { Button("結束") { completion(false) } } }
      }
    }
  }
}

/// 報告指定開局：以同一帳號的實戰線直接進詳情，不必重新搜尋。
struct OpeningReportEntryView: View {
  @Environment(AppModel.self) private var app
  let family: String
  let side: Side
  @State private var profile: OpeningProfile?
  @State private var loading = true
  var body: some View {
    Group {
      if let profile { OpeningDetailView(profile: profile, account: app.account?.id ?? "local") }
      else if loading { ProgressView("整理開局中…") }
      else {
        ContentUnavailableView {
          Label(family, systemImage: "square.grid.3x3")
        } description: {
          Text("這次沒有找到對應的理論路線，仍可從開局分析板開始探索。")
        } actions: {
          NavigationLink("開局分析板") { OpeningAnalysisView(side: side, account: app.account?.id ?? "local") }
          NavigationLink("查看全部開局") { OpeningPracticeView() }
        }
      }
    }
    .task(id: "\(app.account?.id ?? "local"):\(app.games.hashValue)") {
      loading = true; profile = nil
      let games = app.games.filter { $0.color == side && (Openings.family($0.openingRaw) == family || Openings.name($0.openingRaw) == family) }
      let result = await Task.detached(priority: .userInitiated) { OpeningProfile.build(games: games) }.value
      guard !Task.isCancelled else { return }; profile = result.first; loading = false
    }
  }
}

struct OpeningAccountView: View {
  @Environment(AppModel.self) private var app
  @Environment(\.dismiss) private var dismiss
  @State private var platform = Platform.chesscom
  @State private var username = ""
  @FocusState private var focused: Bool
  var body: some View {
    AccountForm(platform: $platform, username: $username, focused: $focused) { account in app.use(account); dismiss() }
      .padding().navigationTitle("新增帳號")
  }
}
