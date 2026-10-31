import SwiftUI

/// 一題：從 fen 開始照 moves 走（autoFirst 時第一步是對手先走），我方要走對每一步
struct PuzzleItem: Identifiable, Hashable {
  let id: String
  let fen: String
  let moves: [String]
  let autoFirst: Bool
  /// 我方第一步也算對的走法（複習卡：跟最佳步差不多好的）
  var accept: [String] = []
  let title: String
  var subtitle: String = ""
  /// 複習卡的 id（答完要排下次）
  var cardId: String?
  var headline: String?
  var why: [String] = []
  /// 出自哪一局的第幾手（可以回到那局看）
  var gameId: String?
  var ply: Int?
  /// 這一輪剛剛沒走到、隔幾題再出一次的（不重複排複習）
  var again = false
  /// 開頭的提示：這題是機會還是風險（跟單局快速復盤一樣）
  var risk = false

  var lead: (title: String, detail: String?) {
    risk ? ("這一步要小心。", headline) : ("這裡有個機會！", headline ?? (subtitle.isEmpty ? nil : subtitle))
  }

  init(card c: ReviewCard) {
    id = c.id; fen = c.fen; moves = c.moves; autoFirst = false; accept = c.accept ?? []
    title = "\(c.date.formatted(.dateTime.month().day()))・vs \(c.opponent)・第 \(c.moveNumber) 手"
    subtitle = "這局你走了 \(c.played)，錯過了更好的一步"
    cardId = c.id; headline = c.headline; why = c.why ?? []
    gameId = c.gameId; ply = c.ply
    // 舊規則收的題（不一定是錯失的機會）多半是失誤：提示要小心
    risk = c.v == nil
  }

  init(id: String, fen: String, moves: [String], autoFirst: Bool, title: String, subtitle: String = "") {
    self.id = id; self.fen = fen; self.moves = moves; self.autoFirst = autoFirst; self.title = title; self.subtitle = subtitle
  }
}

/// 主題題庫：網站從 Lichess 題庫（CC0）依主題篩出來的題（rookielab.io/puzzles/<主題>.json）
enum PuzzleBank {
  struct Theme: Identifiable, Hashable { let key: String; let name: String; let goal: String; var id: String { key } }

  static let themes: [Theme] = [
    .init(key: "hanging", name: "白吃的子", goal: "有子沒人保護，把它吃下來"),
    .init(key: "fork", name: "捉雙", goal: "找一步同時攻擊兩個子"),
    .init(key: "pin", name: "牽制", goal: "讓對手的子動不了，或利用被牽制的子"),
    .init(key: "skewer", name: "串打", goal: "攻擊前面的大子，逼它讓開後吃後面的"),
    .init(key: "discovered", name: "閃擊", goal: "移開一個子，讓後面的子打出去"),
    .init(key: "mate1", name: "一步殺", goal: "找出一步將死"),
    .init(key: "mate2", name: "兩步殺", goal: "兩步之內將死"),
    .init(key: "backrank", name: "底線殺", goal: "對手的王被自己的兵關在底線"),
    .init(key: "trapped", name: "困子", goal: "把對手的子困住再吃掉"),
    .init(key: "promotion", name: "升變", goal: "把兵送到底升后"),
    .init(key: "pawnEnd", name: "兵殘局", goal: "王要主動上前；算清楚誰先升變"),
    .init(key: "rookEnd", name: "車殘局", goal: "車放在兵的後面、車要主動"),
    .init(key: "minorEnd", name: "輕子殘局", goal: "象怕兵卡在同色格，馬怕邊兵"),
    .init(key: "queenEnd", name: "后殘局", goal: "先顧好自己的王，小心長將"),
  ]

  private struct Raw: Decodable { let id: String; let fen: String; let moves: [String]; let rating: Int? }

  /// 做過的題（下一組不再出，讓人一直有新題目）
  static var seen: Set<String> {
    get { Set(UserDefaults.standard.stringArray(forKey: "seenPuzzles") ?? []) }
    set { UserDefaults.standard.set(Array(newValue.suffix(3000)), forKey: "seenPuzzles") }
  }

  /// 本週重點（報告的「先學的一件事」對到的主題）
  static var focus: Theme? {
    get { UserDefaults.standard.string(forKey: "focusTheme").flatMap { k in themes.first { $0.key == k } } }
    set { UserDefaults.standard.set(newValue?.key, forKey: "focusTheme") }
  }
  static var focusLabel: String? {
    get { UserDefaults.standard.string(forKey: "focusLabel") }
    set { UserDefaults.standard.set(newValue, forKey: "focusLabel") }
  }

  /// 挑 n 題：難度在你的分數附近（Lichess 題的分數，chess.com 分數先換算）
  static func fetch(_ t: Theme, rating: Int?, platform: Platform, n: Int = 10) async -> [PuzzleItem] {
    guard let url = URL(string: "https://rookielab.io/puzzles/\(t.key).json"),
          let (d, r) = try? await URLSession.shared.data(from: url), (r as? HTTPURLResponse)?.statusCode == 200,
          let all = try? JSONDecoder().decode([Raw].self, from: d) else { return [] }
    let target = rating.map { Explorer.lichessRating($0, platform: platform) } ?? 1200
    let seen = Self.seen
    let fresh = all.filter { !seen.contains("\(t.key):\($0.id)") }
    let src = fresh.count >= n ? fresh : all
    let near = src.filter { abs(($0.rating ?? target) - target) <= 350 }
    let pool = near.count >= n ? near : src.sorted { abs(($0.rating ?? 0) - target) < abs(($1.rating ?? 0) - target) }
    return pool.shuffled().prefix(n).map {
      PuzzleItem(id: "\(t.key):\($0.id)", fen: $0.fen, moves: $0.moves, autoFirst: true, title: t.name, subtitle: t.goal)
    }
  }
}

/// 殘局基本功（網站 src/lib/endgameBasics.ts）：從固定局面跟引擎下
struct EndgameBasic: Identifiable, Hashable {
  let key: String, name: String, goal: String, fen: String
  let side: Side
  /// 守住這麼多步就算過（守和的題）
  var limit: Int? = nil
  var id: String { key }

  static let all: [EndgameBasic] = [
    .init(key: "kq", name: "后殺單王", goal: "用后和王把對方的王逼到邊上將死", fen: "8/8/8/4k3/8/8/8/4K2Q w - - 0 1", side: .white),
    .init(key: "kr", name: "車殺單王", goal: "用車一排一排縮小王的空間", fen: "8/8/8/4k3/8/8/8/R3K3 w - - 0 1", side: .white),
    .init(key: "kp", name: "王兵對王", goal: "王走在兵前面，把兵送到底升后", fen: "4k3/8/4K3/4P3/8/8/8/8 w - - 0 1", side: .white),
    .init(key: "lucena", name: "Lucena 局面", goal: "車兵對車要贏：用車「搭橋」擋住將軍", fen: "1K6/1P1k4/8/8/8/8/r7/2R5 w - - 0 1", side: .white),
    .init(key: "philidor", name: "Philidor 局面", goal: "少一個兵要守和：車守第六排，兵上來就從後面將軍", fen: "4k3/8/r7/4PK2/8/8/8/7R b - - 0 1", side: .black, limit: 30),
  ]
}

// MARK: - 練習分頁

struct PracticeView: View {
  /// 每天預設練幾題（一組幾題）
  static let daily = 5

  @Environment(AppModel.self) private var app
  @State private var store = ReviewStore.shared
  @State private var session: Session?
  @State private var loadingTheme: String?
  @State private var endgame: EndgameBasic?
  @State private var loadError: String?
  @State private var preparing = false

  /// 今天：目標 10 題、本週重點、繼續練（到期的複習＋重點主題的新題目）
  private var todayCard: some View {
    let goal = PracticeView.daily
    let done = store.todayCount
    return VStack(alignment: .leading, spacing: 12) {
      HStack(spacing: 14) {
        ZStack {
          Circle().stroke(Color(.secondarySystemFill), lineWidth: 7)
          Circle().trim(from: 0, to: min(Double(done) / Double(goal), 1)).stroke(done >= goal ? Color.green : Brand.orange, style: StrokeStyle(lineWidth: 7, lineCap: .round))
            .rotationEffect(.degrees(-90)).animation(.easeOut(duration: 0.5), value: done)
          VStack(spacing: 0) {
            Text("\(min(done, goal))").font(.title3.bold().monospacedDigit())
            Text("/\(goal)").font(.caption2).foregroundStyle(.secondary)
          }
        }
        .frame(width: 64, height: 64)
        VStack(alignment: .leading, spacing: 4) {
          Text(done >= goal ? "今天的練習完成了" : "今天的練習").font(.headline)
          if let f = PuzzleBank.focusLabel { Label("本週重點：\(f)", systemImage: "scope").font(.subheadline).foregroundStyle(Brand.orange) }
          Text("\(store.dueCards.count) 題複習到期・\(done) 題已完成").font(.caption).foregroundStyle(.secondary)
        }
        Spacer(minLength: 0)
      }
      Button {
        preparing = true
        Task { let s = await todaySession(); preparing = false; if !s.items.isEmpty { session = s } else { loadError = "題目載入失敗，檢查網路後再試一次" } }
      } label: {
        HStack {
          if preparing { ProgressView().tint(.white) } else { Image(systemName: "play.fill") }
          Text(done >= goal ? "再練一組" : done > 0 ? "繼續練" : "開始今天的練習")
        }
        .font(.headline).frame(maxWidth: .infinity, minHeight: 48)
      }
      .buttonStyle(.borderedProminent).tint(Brand.orange).disabled(preparing)
    }
    .padding(.vertical, 4)
  }

  /// 題庫進度：今天已練幾題／共幾題，下面是各狀態的題數
  private var poolCard: some View {
    let p = store.todayProgress
    return VStack(alignment: .leading, spacing: 10) {
      HStack(alignment: .firstTextBaseline) {
        Text("今天已練").font(.subheadline).foregroundStyle(.secondary)
        Text("\(p.done)").font(.title2.bold().monospacedDigit()).foregroundStyle(p.total > 0 && p.done >= p.total ? .green : Brand.ink)
        Text("/ \(p.total) 題").font(.subheadline.monospacedDigit()).foregroundStyle(.secondary)
        Spacer()
      }
      ProgressView(value: Double(p.done), total: Double(max(p.total, 1))).tint(p.total > 0 && p.done >= p.total ? .green : Brand.orange)
      HStack(spacing: 0) {
        poolStat("今天待練", store.dueCards.count, Brand.orange)
        poolStat("複習中", store.waiting.count, Brand.ink)
        poolStat("已熟練", store.masteredCards.count, Color(hex: 0x15803D))
        poolStat("未開始", store.unstarted.count, .secondary)
      }
    }
    .padding(.vertical, 4)
  }

  private func poolStat(_ label: String, _ n: Int, _ color: Color) -> some View {
    VStack(spacing: 1) {
      Text("\(n)").font(.headline.monospacedDigit()).foregroundStyle(color)
      Text(label).font(.caption2).foregroundStyle(.secondary)
    }
    .frame(maxWidth: .infinity)
  }

  struct Session: Identifiable {
    let id = UUID(); let title: String; let items: [PuzzleItem]
    var more: (() async -> [PuzzleItem])? = nil
  }

  /// 今天的一組：到期的複習題先，不滿 10 題就補本週重點的新題目；做完還可以再來一組
  private func todaySession() async -> Session {
    var items = store.session(size: Self.daily).map(PuzzleItem.init(card:))
    let rating = app.games.first?.myRating, platform = app.account?.platform ?? .chesscom
    let theme = PuzzleBank.focus ?? PuzzleBank.themes[0]
    if items.count < Self.daily { items += await PuzzleBank.fetch(theme, rating: rating, platform: platform, n: Self.daily - items.count) }
    return Session(title: "今天的練習", items: items) { await PuzzleBank.fetch(theme, rating: rating, platform: platform, n: Self.daily) }
  }

  var body: some View {
    List {
      Section { todayCard }
      Section {
        NavigationLink { ReviewPoolView() } label: { poolCard }
      } header: {
        Text("複習題庫")
      } footer: {
        Text("從你的對局裡挑出錯過的好機會。練過的進「複習中」，自己連續走對 \(ReviewStore.graduate) 次就「已熟練」")
      }
      Section { StreakCard(store: store) }
      Section { WeeklyCard(store: store) }
      Section {
        let due = store.dueCards.count
        Button {
          session = Session(title: "今日複習", items: store.session().map(PuzzleItem.init(card:)))
        } label: {
          HStack {
            Image(systemName: due > 0 ? "play.circle.fill" : "checkmark.circle.fill").font(.title2)
            VStack(alignment: .leading, spacing: 2) {
              Text(due > 0 ? "開始今日複習" : store.cards.isEmpty ? "還沒有複習題" : "今天的複習完成了").font(.headline)
              Text(due > 0 ? "\(min(due, Self.daily)) 題到期，大約 \(max(1, min(due, Self.daily) / 2)) 分鐘" : store.cards.isEmpty ? "分析完一局，你錯過的好機會就會變成複習題" : "做一組主題練習，維持手感")
                .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
          }
          .foregroundStyle(due > 0 ? Brand.orange : store.cards.isEmpty ? Brand.ink : .green)
        }
        .disabled(due == 0)
      }
      if !store.cards.isEmpty {
        Section {
          ForEach(ReviewCard.Kind.allCases, id: \.self) { k in
            let cs = store.cards.filter { $0.kinds.contains(k) && !$0.mastered }
            if !cs.isEmpty {
              Button {
                let items = cs.sorted { $0.due < $1.due }.prefix(Self.daily).map(PuzzleItem.init(card:))
                session = Session(title: k.zh, items: Array(items))
              } label: {
                HStack {
                  Label(k.zh, systemImage: k.icon).foregroundStyle(Brand.ink)
                  Spacer()
                  Text("\(cs.count) 張").font(.subheadline.monospacedDigit()).foregroundStyle(.secondary)
                }
              }
            }
          }
        } header: {
          Text("我的失誤")
        } footer: {
          Text("共 \(store.cards.count) 張，學會 \(store.masteredCount) 張（連續答對 \(ReviewStore.graduate) 次）。答對的隔 1 天、3 天，之後越來越久才再出。")
        }
      }
      Section("主題練習") {
        ForEach(PuzzleBank.themes) { t in
          Button {
            loadingTheme = t.key
            Task {
              let rating = app.games.first?.myRating, platform = app.account?.platform ?? .chesscom
              let items = await PuzzleBank.fetch(t, rating: rating, platform: platform)
              loadingTheme = nil
              if items.isEmpty { loadError = "題目載入失敗，檢查網路後再試一次" }
              else { session = Session(title: t.name, items: items) { await PuzzleBank.fetch(t, rating: rating, platform: platform) } }
            }
          } label: {
            HStack {
              VStack(alignment: .leading, spacing: 1) {
                Text(t.name).foregroundStyle(Brand.ink)
                Text(t.goal).font(.caption).foregroundStyle(Color.gray)
              }
              Spacer()
              if loadingTheme == t.key { ProgressView() }
            }
          }
        }
      }
      Section {
        ForEach(EndgameBasic.all) { e in
          Button { endgame = e } label: {
            VStack(alignment: .leading, spacing: 1) {
              Text(e.name).foregroundStyle(Brand.ink)
              Text(e.goal).font(.caption).foregroundStyle(Color.gray)
            }
          }
        }
      } header: {
        Text("殘局基本功")
      } footer: {
        Text("先看要領和一步一步的示範，再跟引擎練（引擎會用最好的防守）。也可以按「跳過」直接練。")
      }
    }
    .navigationTitle("練習")
    #if DEBUG
    // 開發用：-demoPuzzle <主題> 直接開一組主題練習
    .task {
      let args = ProcessInfo.processInfo.arguments
      if let i = args.firstIndex(of: "-demoLesson"), i + 1 < args.count { endgame = EndgameBasic.all.first { $0.key == args[i + 1] } }
      if let i = args.firstIndex(of: "-demoPuzzle"), i + 1 < args.count, let t = PuzzleBank.themes.first(where: { $0.key == args[i + 1] }) {
        let items = await PuzzleBank.fetch(t, rating: 500, platform: .chesscom)
        session = Session(title: t.name, items: items)
      }
    }
    #endif
    .fullScreenCover(item: $session) { s in PuzzleSessionView(title: s.title, items: s.items, more: s.more) }
    .alert(loadError ?? "", isPresented: Binding(get: { loadError != nil }, set: { if !$0 { loadError = nil } })) { Button("好") { loadError = nil } }
    .navigationDestination(item: $endgame) { EndgameLessonView(basic: $0) }
  }
}

/// 連續天數＋最近五週的練習日曆（有練的那天塗滿）
struct StreakCard: View {
  let store: ReviewStore

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      HStack(alignment: .firstTextBaseline, spacing: 8) {
        Image(systemName: "flame.fill").font(.title).foregroundStyle(store.streak > 0 ? Brand.orange : .gray.opacity(0.5))
        Text("\(store.streak)").font(.system(size: 34, weight: .bold, design: .rounded)).monospacedDigit()
        Text("天連續練習").font(.subheadline).foregroundStyle(.secondary)
        Spacer()
        Text(store.practicedToday ? "今天做了 \(store.todayCount) 題" : "今天還沒練").font(.caption)
          .foregroundStyle(store.practicedToday ? .green : Brand.orange)
      }
      let today = Day.number()
      // 這週的星期幾（日＝0）對齊最右邊一欄
      let weekday = Calendar.current.component(.weekday, from: Date()) - 1
      let start = today - weekday - 28
      VStack(spacing: 4) {
        HStack(spacing: 4) {
          ForEach(["日", "一", "二", "三", "四", "五", "六"], id: \.self) { Text($0).font(.caption2).foregroundStyle(.secondary).frame(maxWidth: .infinity) }
        }
        ForEach(0..<5, id: \.self) { w in
          HStack(spacing: 4) {
            ForEach(0..<7, id: \.self) { d in
              let n = start + w * 7 + d
              let done = (store.days[n] ?? 0) > 0
              RoundedRectangle(cornerRadius: 4, style: .continuous)
                .fill(n > today ? Color.clear : done ? Brand.orange : Color(.secondarySystemFill))
                .overlay(RoundedRectangle(cornerRadius: 4).stroke(n == today ? Brand.orange : .clear, lineWidth: 1.5))
                .frame(maxWidth: .infinity).frame(height: 22)
                .accessibilityLabel(done ? "有練習" : "沒練習")
            }
          }
        }
      }
    }
    .padding(.vertical, 4)
  }
}

// MARK: - 解題

struct PuzzleSessionView: View {
  @Environment(AppModel.self) private var app: AppModel?
  let title: String
  @State var items: [PuzzleItem]
  /// 做完一組可以「再來一組」（主題題、本週重點）
  var more: (() async -> [PuzzleItem])? = nil
  @Environment(\.dismiss) private var dismiss
  @State private var index = 0
  @State private var fen = ""
  @State private var step = 0
  @State private var wrongs = 0
  @State private var state: Phase = .thinking
  @State private var showAnswer = false
  @State private var showHintPiece = false
  /// 對手的那一步還沒走完：先不讓點（點了會動到對手的子）
  @State private var waiting = false
  /// 正在請引擎檢查你走的這步（不在答案裡、但可能一樣好）
  @State private var checking = false
  /// 你走的不是答案、但引擎說一樣好
  @State private var alsoGood: String?
  @State private var correct = 0
  /// 每一題的結果（答對、沒答對、還沒做）：最上面的圓點
  @State private var results: [Bool?] = []
  @State private var burst = false
  @State private var loadingMore = false
  @State private var last: (from: String, to: String)?
  /// 這一次作答的編號：引擎檢查、對手自動走都是非同步的，回來時題目已經換了（跳過、下一題、再試一次）就丟掉，
  /// 不然上一題的檢查結果會記到這一題，照答案走也算沒答對
  @State private var attempt = UUID()
  @State private var revisit: GameSummary?
  /// 對手剛走的那一步（題目開頭先走給你看）
  @State private var oppMove: String?
  /// 沒走到的題，隔幾題再出一次
  static let againAfter = 3

  enum Phase { case thinking, solved, failed, finished }

  init(title: String, items: [PuzzleItem], more: (() async -> [PuzzleItem])? = nil) {
    self.title = title
    _items = State(initialValue: items)
    self.more = more
  }

  /// 這一題我方要走幾步、現在第幾步
  private var myTotal: Int { item.map { $0.autoFirst ? $0.moves.count / 2 : ($0.moves.count + 1) / 2 } ?? 1 }
  private var myStep: Int { min(myTotal, step / 2 + 1) }

  private var item: PuzzleItem? { items[safe: index] }
  private var mySide: Side { item.map { FEN.sideToMove($0.fen) == .white ? ($0.autoFirst ? .black : .white) : ($0.autoFirst ? .white : .black) } ?? .white }

  var body: some View {
    NavigationStack {
      VStack(spacing: 12) {
        if state == .finished {
          finished
        } else if let item {
          // 總共幾題、對了幾題：每題一個圓點（綠＝答對、紅＝沒答對、灰＝還沒做）
          HStack(spacing: 5) {
            ForEach(items.indices, id: \.self) { i in
              Circle().fill(results[safe: i].flatMap { $0 }.map { $0 ? Color.green : Color.red } ?? (i == index ? Brand.orange : Color(.secondarySystemFill)))
                .frame(width: i == index ? 12 : 9, height: i == index ? 12 : 9)
            }
            Spacer()
            Text("第 \(index + 1)/\(items.count) 題・對 \(correct)").font(.caption.monospacedDigit().weight(.semibold)).foregroundStyle(.secondary)
          }
          VStack(alignment: .leading, spacing: 2) {
            HStack {
              Text(item.title).font(.headline)
              Spacer()
              if myTotal > 1 { Text("第 \(min(myStep, myTotal))/\(myTotal) 步").font(.caption.weight(.semibold)).padding(.horizontal, 8).padding(.vertical, 3).background(Brand.cream, in: Capsule()) }
            }
            if !item.subtitle.isEmpty { Text(item.subtitle).font(.caption).foregroundStyle(.secondary) }
          }
          .frame(maxWidth: .infinity, alignment: .leading)
          BoardView(fen: fen, flipped: mySide == .black, arrows: hint,
                    highlight: last.map { [$0.from, $0.to] } ?? [],
                    pulse: showHintPiece && !showAnswer && state == .thinking ? item.moves[safe: step].map { String($0.prefix(2)) } : nil,
                    legalTargets: state == .thinking && !waiting && !checking ? { sq in
                      // 只能動自己這一方的子
                      guard let code = FEN.pieces(fen)[sq], (code.first == "w") == (mySide == .white) else { return [] }
                      return FEN.targets(fen: fen, from: sq)
                    } : nil,
                    onMove: state == .thinking ? { tryMove($0, $1) } : nil)
            .overlay {
              // 答對：大大的綠勾跳出來
              if state == .solved {
                Image(systemName: "checkmark.circle.fill").font(.system(size: 96)).foregroundStyle(.white, .green)
                  .shadow(radius: 8).scaleEffect(burst ? 1 : 0.3).opacity(burst ? 1 : 0)
                  .onAppear { withAnimation(.spring(response: 0.35, dampingFraction: 0.5)) { burst = true } }
                  .onDisappear { burst = false }
              }
            }
          prompt(item)
          Spacer(minLength: 0)
        }
      }
      .padding(.horizontal, 14)
      .padding(.top, 6)
      .background(Brand.paper)
      .navigationTitle(title).navigationBarTitleDisplayMode(.inline)
      .toolbar { ToolbarItem(placement: .cancellationAction) { Button("結束") { dismiss() } } }
      .navigationDestination(item: $revisit) { g in ReviewView(game: g, startAt: item?.ply ?? 0) }
    }
    .onAppear { load() }
  }

  private var hint: [Arrow] {
    guard let item, let u = item.moves[safe: step] else { return [] }
    if showAnswer { return [Arrow(from: String(u.prefix(2)), to: String(u.dropFirst(2).prefix(2)), color: Brand.bestArrow)] }
    return []
  }

  @ViewBuilder private func prompt(_ item: PuzzleItem) -> some View {
    VStack(spacing: 10) {
      switch state {
      case .thinking:
        if checking {
          HStack(spacing: 6) { ProgressView().controlSize(.small); Text("檢查這步…").font(.subheadline) }
        } else {
          if waiting {
            Text("對手先走…").font(.subheadline.weight(.semibold)).foregroundStyle(Brand.ink)
          } else {
            let lead = item.lead
            HStack(alignment: .top, spacing: 10) {
              Image(wrongs == 0 ? "coach-think" : "coach-sad").resizable().scaledToFit().frame(width: 48, height: 48)
              VStack(alignment: .leading, spacing: 3) {
                Text(wrongs == 0 ? "\(lead.title)找出最好的一步（\(mySide == .white ? "白" : "黑")方）" : "不是這步，再想想")
                  .font(.subheadline.weight(.semibold)).foregroundStyle(wrongs == 0 ? Brand.ink : Brand.orange)
                if wrongs == 0, let m = oppMove { Text("對手剛走了 \(m)").font(.caption.weight(.semibold)).foregroundStyle(Brand.ink) }
                if wrongs == 0, let d = lead.detail { Text(d).font(.caption).foregroundStyle(Brand.ink.opacity(0.75)) }
              }
              .padding(10)
              .frame(maxWidth: .infinity, alignment: .leading)
              .background(Brand.cream, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
          }
        }
        HStack(spacing: 10) {
          if !showHintPiece && !showAnswer { Button("提示") { showHintPiece = true }.buttonStyle(.bordered) }
          if (wrongs >= 1 || showHintPiece) && !showAnswer { Button("看答案") { showAnswer = true }.buttonStyle(.bordered) }
          Button("跳過") { skip() }.buttonStyle(.bordered).tint(.secondary)
        }

      case .solved, .failed:
        Label(alsoGood != nil ? "這步也可以！" : showAnswer ? "完成了！" : "答對了！", systemImage: "checkmark.seal.fill")
          .font(.title3.bold()).foregroundStyle(state == .solved ? .green : Brand.orange)
        if let a = alsoGood { Text("引擎最推薦的是 \(a)，你走的一樣好。").font(.subheadline).foregroundStyle(.secondary) }
        if !item.why.isEmpty {
          VStack(alignment: .leading, spacing: 4) {
            ForEach(item.why, id: \.self) { Text($0).font(.caption).foregroundStyle(Brand.ink.opacity(0.85)).fixedSize(horizontal: false, vertical: true) }
          }
          .frame(maxWidth: .infinity, alignment: .leading)
        } else if let h = item.headline { Text("當時的問題：\(h)").font(.subheadline).foregroundStyle(.secondary) }
        if showAnswer, item.cardId != nil, !item.again { Text("過 \(Self.againAfter) 題再走一次這題，讓它更熟").font(.caption).foregroundStyle(.secondary) }
        if let id = item.gameId, let g = app?.games.first(where: { $0.id == id }) {
          Button { revisit = g } label: { Label("回到這局看看", systemImage: "arrow.uturn.backward.circle") }.font(.subheadline)
        }
        HStack(spacing: 10) {
          if state == .failed {
            Button { load() } label: { Label("再試一次", systemImage: "arrow.counterclockwise").font(.headline).frame(maxWidth: .infinity, minHeight: 46) }
              .buttonStyle(.bordered).tint(Brand.orange)
          }
          Button { next() } label: { Text(index + 1 < items.count ? "下一題" : "完成").font(.headline).frame(maxWidth: .infinity, minHeight: 46) }
            .buttonStyle(.borderedProminent).tint(state == .solved ? .green : Brand.orange)
        }
      case .finished:
        EmptyView()
      }
    }
    .frame(maxWidth: .infinity)
    .padding(12)
    .background(Brand.cream, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
  }

  private var finished: some View {
    VStack(spacing: 14) {
      Spacer()
      Image(systemName: "flame.fill").font(.system(size: 56)).foregroundStyle(Brand.orange)
      Text("連續 \(ReviewStore.shared.streak) 天").font(.title.bold())
      Text("答對 \(correct)/\(items.count) 題").font(.title3.weight(.semibold)).foregroundStyle(correct == items.count ? .green : Brand.ink)
      HStack(spacing: 5) {
        ForEach(results.indices, id: \.self) { i in Circle().fill(results[i] == true ? Color.green : Color.red).frame(width: 10, height: 10) }
      }
      if ReviewStore.shared.dueCards.count > 0 { Text("還有 \(ReviewStore.shared.dueCards.count) 題到期").font(.footnote).foregroundStyle(.secondary) }
      FeedbackPromptCard(trigger: "review_done", task: items.first?.cardId == nil ? "puzzles" : "daily").padding(.top, 8)
      if !Notifier.enabled {
        Button { Task { _ = await Notifier.requestAndEnable() } } label: { Label("每天提醒我複習", systemImage: "bell") }
          .buttonStyle(.bordered).padding(.top, 8)
      }
      Spacer()
      if let more {
        Button {
          loadingMore = true
          Task {
            let next = await more()
            loadingMore = false
            guard !next.isEmpty else { return }
            items = next; index = 0; correct = 0; results = []; load()
          }
        } label: {
          Label(loadingMore ? "準備新題目…" : "再來一組", systemImage: "arrow.clockwise").font(.headline).frame(maxWidth: .infinity, minHeight: 50)
        }
        .buttonStyle(.borderedProminent).tint(Brand.orange).disabled(loadingMore)
      }
      Button { Notifier.reschedule(); dismiss() } label: { Text(more == nil ? "好" : "今天先到這裡").font(.headline).frame(maxWidth: .infinity, minHeight: 50) }
        .buttonStyle(.bordered).tint(Brand.ink)
    }
  }

  private func load() {
    attempt = UUID()
    waiting = false
    guard let item else { state = .finished; return }
    fen = item.fen
    step = 0
    wrongs = 0
    showAnswer = false
    showHintPiece = false
    alsoGood = nil
    checking = false
    last = nil
    oppMove = nil
    state = .thinking
    if item.autoFirst { playOpponent(after: 0.6) } else { showPrevious(item) }
  }

  /// 從對局來的題：先擺在對手走之前，把對手剛走的那一步走出來，再換你（看得懂局面是怎麼來的）
  private func showPrevious(_ item: PuzzleItem) {
    guard let id = item.gameId, let k = item.ply, k > 0, let g = app?.games.first(where: { $0.id == id }),
          let line = ChessLine(pgn: g.pgn), let prev = line.plies[safe: k - 1], prev.fenAfter == item.fen else { return }
    fen = prev.fenBefore
    waiting = true
    let a = attempt
    Task {
      try? await Task.sleep(nanoseconds: 700_000_000)
      guard a == attempt else { return }
      withAnimation { fen = prev.fenAfter }
      last = (prev.from, prev.to)
      oppMove = prev.san
      Sounds.play(for: prev)
      waiting = false
    }
  }

  /// 對手的那一步自動走
  private func playOpponent(after delay: Double) {
    guard let item, let u = item.moves[safe: step] else { return }
    waiting = true
    let a = attempt
    Task {
      try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
      guard a == attempt else { return }
      defer { waiting = false }
      guard let p = ChessLine.ply(fen: fen, uci: u, index: 0) else { return }
      withAnimation { fen = p.fenAfter }
      last = (p.from, p.to)
      if step == 0 { oppMove = p.san }
      Sounds.play(for: p)
      step += 1
    }
  }

  private func tryMove(_ from: String, _ to: String) {
    guard let item, let want = item.moves[safe: step] else { return }
    // 升變一律升后（題目要升別的子時照答案）
    let promo = FEN.pieces(fen)[from]?.last == "P" && (to.hasSuffix("8") || to.hasSuffix("1")) ? (want.count == 5 ? String(want.suffix(1)) : "q") : ""
    let uci = from + to + promo
    let mine = step == (item.autoFirst ? 1 : 0)
    let ok = uci == want || (mine && item.accept.contains(uci))
    guard let p = ChessLine.ply(fen: fen, uci: uci, index: 0) else { return }
    if !ok {
      // 將殺題：別的將殺也算對
      if p.isCheckmate { finish(fen: p.fenAfter, ply: p); return }
      // 不在答案裡：請引擎看一下，跟最佳步差不多好（3% 以內）就算對（題目只存了最佳步，同樣好的步不該判錯）
      let before = fen, at = attempt
      checking = true
      Task {
        let bestLines = await StockfishService.shared.analyse(fen: before, nodes: 150_000, multipv: 1, priority: .interactive)
        let afterLines = await StockfishService.shared.analyse(fen: p.fenAfter, nodes: 150_000, multipv: 1, priority: .interactive)
        guard at == attempt, state == .thinking, fen == before else { return }
        checking = false
        guard let b = bestLines.first, let a = afterLines.first else { wrongs += 1; Haptics.bump(); return }
        let gap = Grading.winProb(b) - (1 - Grading.winProb(a))
        if gap <= 0.03, mine, item.moves.count <= (item.autoFirst ? 2 : 1) {
          alsoGood = FEN.san(fen: before, uci: want) ?? want
          Sounds.play(for: p)
          finish(fen: p.fenAfter, ply: p)
        } else {
          wrongs += 1
          Haptics.bump()
        }
      }
      return
    }
    Haptics.tick()
    Sounds.play(for: p)
    withAnimation { fen = p.fenAfter }
    last = (p.from, p.to)
    step += 1
    if step >= item.moves.count || uci != want { finish(fen: p.fenAfter, ply: p) } else { playOpponent(after: 0.45) }
  }

  private func finish(fen f: String, ply p: Ply) {
    withAnimation { fen = f }
    last = (p.from, p.to)
    // 完成就是完成（畫面只說答對了）；熟悉度在系統裡記：一次走對、有幫忙、看了答案，排下次的間隔不同
    let recall: ReviewStore.Recall = showAnswer ? .shown : (wrongs > 0 || showHintPiece) ? .helped : .clean
    Telemetry.log("puzzle_done", ["recall": "\(recall)", "source": item?.cardId == nil ? "theme" : "review"])
    // 只有第一次作答算數、排複習（「再試一次」不重複算）
    let first = results[safe: index] == nil
    if first {
      if recall != .shown { correct += 1 }
      setResult(recall != .shown)
      if let id = item?.id, item?.cardId == nil { PuzzleBank.seen.insert(id) }
      if let id = item?.cardId, item?.again == false { ReviewStore.shared.answer(id, recall: recall) } else { ReviewStore.shared.markPracticed() }
      if recall == .shown { requeue() }
    }
    Haptics.bump()
    state = .solved
  }

  private func setResult(_ ok: Bool) {
    while results.count <= index { results.append(nil) }
    if results[index] == nil { results[index] = ok }
  }

  private func skip() {
    let first = results[safe: index] == nil
    setResult(false)
    if first, let id = item?.cardId, item?.again == false { ReviewStore.shared.answer(id, ok: false); requeue() }
    next()
  }

  /// 複習題沒走到：這一輪隔幾題再出一次（跟 Anki 的「重新學習」一樣，趁還記得再走一遍）
  private func requeue() {
    guard var again = item, again.cardId != nil, !again.again else { return }
    again.again = true
    again.subtitle = "剛剛這題再走一次"
    items.insert(again, at: min(index + 1 + Self.againAfter, items.count))
  }

  private func next() {
    index += 1
    if index >= items.count { state = .finished } else { load() }
  }
}

// MARK: - 殘局基本功：跟引擎下

struct EndgamePlayView: View {
  let basic: EndgameBasic
  @State private var fen: String
  @State private var myMoves = 0
  @State private var thinking = false
  @State private var result: String?
  @State private var last: (from: String, to: String)?
  /// 開始時引擎看幾步能將死（讓人知道大概還要幾步，不會覺得永無止境）
  @State private var mateIn: Int?

  init(basic: EndgameBasic) {
    self.basic = basic
    _fen = State(initialValue: basic.fen)
  }

  private var progressText: String {
    if let l = basic.limit { return "守住 \(l) 步：已經 \(myMoves) 步" }
    if let m = mateIn { return "引擎看是 \(m) 步殺・你已經走了 \(myMoves) 步" }
    return "已經走了 \(myMoves) 步"
  }

  var body: some View {
    VStack(spacing: 12) {
      Text(basic.goal).font(.subheadline).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading)
      BoardView(fen: fen, flipped: basic.side == .black, highlight: last.map { [$0.from, $0.to] } ?? [],
                legalTargets: result == nil && !thinking && FEN.sideToMove(fen) == basic.side ? { FEN.targets(fen: fen, from: $0) } : nil,
                onMove: { play($0, $1) })
      HStack {
        if thinking { ProgressView().controlSize(.small); Text("引擎思考中…").font(.caption).foregroundStyle(.secondary) }
        else if let r = result { Text(r).font(.headline).foregroundStyle(r.hasPrefix("過關") ? .green : Brand.orange) }
        else { Text(progressText).font(.subheadline).monospacedDigit() }
        Spacer()
        Button { restart() } label: { Label("重來", systemImage: "arrow.counterclockwise") }
          .buttonStyle(.bordered).tint(Brand.orange)
      }
      Spacer()
    }
    .padding(14)
    .background(Brand.paper)
    .navigationTitle(basic.name).navigationBarTitleDisplayMode(.inline)
    .toolbar { ToolbarItem(placement: .topBarTrailing) { SoundToggle() } }
    .toolbar(.hidden, for: .tabBar)
    .overlay {
      if let r = result, r.hasPrefix("過關") { SuccessBurst(text: r) { restart() } }
    }
    .task {
      guard basic.limit == nil else { return }
      let l = await StockfishService.shared.analyse(fen: basic.fen, nodes: 400_000, multipv: 1, priority: .interactive)
      if let m = l.first?.mate, m > 0 { mateIn = m }
    }
  }

  private func restart() {
    fen = basic.fen; myMoves = 0; result = nil; last = nil
    if FEN.sideToMove(fen) != basic.side { reply() }
  }

  private func play(_ from: String, _ to: String) {
    let promo = FEN.pieces(fen)[from]?.last == "P" && (to.hasSuffix("8") || to.hasSuffix("1")) ? "q" : ""
    guard let p = ChessLine.ply(fen: fen, uci: from + to + promo, index: 0) else { return }
    apply(p)
    myMoves += 1
    if check(p) { return }
    if let l = basic.limit, myMoves >= l { done("過關！守住了 \(l) 步") ; return }
    reply()
  }

  private func reply() {
    thinking = true
    let f = fen
    Task {
      let lines = await StockfishService.shared.analyse(fen: f, nodes: 200_000, multipv: 1, priority: .interactive)
      thinking = false
      guard fen == f, let u = lines.first?.best, let p = ChessLine.ply(fen: f, uci: u, index: 0) else { return }
      apply(p)
      _ = check(p)
    }
  }

  private func apply(_ p: Ply) {
    withAnimation { fen = p.fenAfter }
    last = (p.from, p.to)
    Sounds.play(for: p)
  }

  /// 局面結束了嗎：將死、逼和、只剩王（子力不足）
  private func check(_ p: Ply) -> Bool {
    let mine = p.mover == basic.side
    if p.isCheckmate { done(mine ? "過關！將死了" : "被將死了，再試一次"); return true }
    if !FEN.hasMoves(p.fenAfter) { done(basic.limit != nil ? "過關！逼和了" : "逼和了：要留給對方的王走的格子"); return true }
    let rest = FEN.pieces(p.fenAfter).values.filter { $0.last != "K" }
    if rest.isEmpty { done(basic.limit != nil ? "過關！守和了" : "子都換光了，再試一次"); return true }
    return false
  }

  private func done(_ r: String) {
    result = r
    if r.hasPrefix("過關") { ReviewStore.shared.markPracticed(); Haptics.bump() }
  }
}

// MARK: - 殘局教材：要領 → 一步一步的示範（每步講解）→ 練習；可以跳過直接練

struct EndgameLessonView: View {
  let basic: EndgameBasic
  private let lesson: EndgameLesson?
  @State private var cursor = 0
  @State private var playing = false
  @State private var practice = false
  @State private var task: Task<Void, Never>?

  init(basic: EndgameBasic) {
    self.basic = basic
    lesson = EndgameLesson.of(basic.key)
  }

  /// 示範走到第 cursor 步的局面
  private var plies: [Ply] {
    guard let lesson else { return [] }
    var out: [Ply] = []
    var f = basic.fen
    for s in lesson.steps {
      guard let p = ChessLine.ply(fen: f, uci: s.uci, index: out.count) else { break }
      out.append(p)
      f = p.fenAfter
    }
    return out
  }

  var body: some View {
    if practice || lesson == nil {
      EndgamePlayView(basic: basic)
    } else if let lesson {
      let ps = plies
      let fen = cursor == 0 ? basic.fen : ps[cursor - 1].fenAfter
      VStack(spacing: 10) {
        // 同一個位置：還沒開始看要領，開始之後換成這一步的講解（棋盤和講解都在一個畫面裡）
        VStack(alignment: .leading, spacing: 6) {
          if cursor == 0 {
            Text("要領").font(.caption.weight(.semibold)).foregroundStyle(Brand.orange)
            ForEach(Array(lesson.points.enumerated()), id: \.offset) { i, t in
              HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("\(i + 1)").font(.caption2.bold()).frame(width: 16, height: 16).background(Brand.orange, in: Circle()).foregroundStyle(.white)
                Text(t).font(.footnote).fixedSize(horizontal: false, vertical: true)
              }
            }
          } else {
            Text("第 \(cursor)/\(ps.count) 步・\(ps[cursor - 1].san)").font(.caption.weight(.semibold)).foregroundStyle(Brand.orange)
            Text(lesson.steps[cursor - 1].caption).font(.headline).foregroundStyle(Brand.ink).fixedSize(horizontal: false, vertical: true)
          }
        }
        .padding(12).frame(maxWidth: .infinity, minHeight: 116, alignment: .topLeading)
        .background(Brand.cream, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .animation(.snappy, value: cursor)
        BoardView(fen: fen, flipped: basic.side == .black, highlight: cursor > 0 ? [ps[cursor - 1].from, ps[cursor - 1].to] : [])
        Spacer(minLength: 0)
      }
      .padding(.horizontal, 14).padding(.top, 8)
      .safeAreaInset(edge: .bottom, spacing: 0) {
        VStack(spacing: 8) {
          HStack(spacing: 8) {
            Button { step(-1) } label: { Image(systemName: "chevron.left").font(.title3.weight(.semibold)).frame(width: 48, height: 46) }
              .buttonStyle(.bordered).tint(Brand.ink)
            Button { playing ? pause() : play(ps.count) } label: {
              Label(playing ? "暫停" : cursor >= ps.count ? "重看一次" : "播放示範", systemImage: playing ? "pause.fill" : "play.fill")
                .font(.headline).frame(maxWidth: .infinity, minHeight: 46)
            }
            .buttonStyle(.bordered).tint(Brand.orange)
            Button { step(1) } label: { Image(systemName: "chevron.right").font(.title3.weight(.semibold)).frame(width: 48, height: 46) }
              .buttonStyle(.bordered).tint(Brand.ink)
          }
          Button { pause(); practice = true } label: {
            Text(cursor >= ps.count ? "看完了，開始練習" : "開始練習").font(.headline).frame(maxWidth: .infinity, minHeight: 48)
          }
          .buttonStyle(.borderedProminent).tint(Brand.orange)
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
        .background(.bar)
      }
      .background(Brand.paper)
      .toolbar(.hidden, for: .tabBar)
      .navigationTitle(basic.name).navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .topBarTrailing) { Button("跳過") { pause(); practice = true } }
      }
      .onDisappear { pause() }
    }
  }

  private func step(_ d: Int) {
    pause()
    let n = min(max(0, cursor + d), plies.count)
    guard n != cursor else { return }
    let forward = n == cursor + 1
    cursor = n
    Haptics.tick()
    if forward, n > 0 { Sounds.play(for: plies[n - 1]) }
  }

  private func play(_ total: Int) {
    if cursor >= total { cursor = 0 }
    playing = true
    task = Task {
      while playing, cursor < total {
        try? await Task.sleep(nanoseconds: cursor == 0 ? 600_000_000 : 1_600_000_000)
        guard playing else { return }
        cursor += 1
        Sounds.play(for: plies[cursor - 1])
      }
      playing = false
    }
  }

  private func pause() { playing = false; task?.cancel() }
}


/// 過關：明顯的成功畫面（大勾、震動），可以再來一次或返回
struct SuccessBurst: View {
  let text: String
  let again: () -> Void
  @Environment(\.dismiss) private var dismiss
  @State private var pop = false

  var body: some View {
    ZStack {
      Color.black.opacity(0.35).ignoresSafeArea()
      VStack(spacing: 14) {
        Image(systemName: "checkmark.seal.fill").font(.system(size: 72)).foregroundStyle(.green)
          .scaleEffect(pop ? 1 : 0.3).rotationEffect(.degrees(pop ? 0 : -30))
        Text(text).font(.title2.bold()).multilineTextAlignment(.center)
        HStack(spacing: 10) {
          Button { again() } label: { Label("再來一次", systemImage: "arrow.counterclockwise").frame(maxWidth: .infinity, minHeight: 44) }
            .buttonStyle(.bordered).tint(Brand.orange)
          Button { dismiss() } label: { Text("完成").frame(maxWidth: .infinity, minHeight: 44) }
            .buttonStyle(.borderedProminent).tint(.green)
        }
      }
      .padding(24)
      .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
      .padding(32)
      .scaleEffect(pop ? 1 : 0.8).opacity(pop ? 1 : 0)
    }
    .onAppear {
      withAnimation(.spring(response: 0.4, dampingFraction: 0.55)) { pop = true }
      Haptics.bump()
    }
  }
}
