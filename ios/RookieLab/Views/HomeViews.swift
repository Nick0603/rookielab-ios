import StoreKit
import SwiftUI

/// 整個 App 共用：目前的帳號與它的對局（對局、報告兩個分頁看同一份）
@MainActor @Observable
final class AppModel {
  var account: Account?
  private var loadGeneration = 0
  private let fetchGames: (Account, Int) async throws -> [GameSummary]
  private(set) var games: [GameSummary] = [] {
    didSet { if openLatestWhenLoaded, let g = games.first { openLatestWhenLoaded = false; openGame = g } }
  }
  private(set) var loading = false
  private(set) var error: String?
  /// 已分析過的局 → 我的準確率（列表上顯示）
  private(set) var accuracy: [String: Double] = [:]
  private(set) var analyzedIDs: Set<String> = []
  private(set) var analysisIndexReady = false
  private var accuracyGeneration = 0
  private var lastLoadAttempt: Date?
  var legacyRoute: AppTab?
  var tab: AppTab = .games {
    didSet {
      if tab != .games && tab != .me { legacyRoute = nil; tab = .games }
      UserDefaults.standard.set(tab.rawValue, forKey: "lastAppTab")
    }
  }
  var showReport = false
  private(set) var usingImported = false
  private var imported = ImportedGames.load()
  var reportGames: [GameSummary] { games.filter { $0.termination != "unfinished" && $0.termination != "unknown" } }
  var sourceID: String { usingImported ? "imported" : account?.id ?? "guest" }
  func useImported() { analyzedIDs = []; analysisIndexReady = false; accuracyGeneration += 1; loadGeneration += 1; loading = false; usingImported = true; UserDefaults.standard.set("imported", forKey: "gameSource"); games = imported; error = nil; refreshAccuracy() }
  func addImported(_ game: GameSummary) {
    legacyRoute = nil
    if !imported.contains(where: { $0.id == game.id }) { imported.insert(game, at: 0); ImportedGames.save(imported) }
    useImported(); showReport = false; tab = .games; openGame = game
  }
  /// 分享進來、要直接打開的那一局
  var openGame: GameSummary?
  /// Siri／捷徑、小工具要直接開始今天的練習（練習分頁看到就開始）
  var startPractice = false
  /// 對局還沒抓到時要打開最新一局：抓到就開
  var openLatestWhenLoaded = false

  /// Siri／捷徑、小工具點進來的動作
  func run(_ a: Router.Action) {
    switch a {
    case .practice:
      legacyRoute = nil
      tab = .games
      startPractice = false
    case .newGames:
      openGame = nil; tab = .games
      if let a = NewGameMonitor.shared.firstPendingAccount { use(a) }
    case .latestGame:
      legacyRoute = nil
      tab = .games; showReport = false
      if let g = games.first { openGame = g } else { openLatestWhenLoaded = true }
    }
  }
  var importing: ImportState?

  enum ImportState: Identifiable {
    case loading
    case pickSide(GameSources.Shared)
    case failed(String)
    var id: String {
      switch self {
      case .loading: "loading"
      case .pickSide: "pick"
      case .failed: "failed"
      }
    }
  }

  init(restore: Bool = true, fetch: @escaping (Account, Int) async throws -> [GameSummary] = { try await GameSources.recentGames($0, limit: $1) }) {
    fetchGames = fetch
    account = restore ? AccountStore.current : nil
    accounts = restore ? AccountStore.all() : []
    #if DEBUG
    let args = ProcessInfo.processInfo.arguments
    if let i = args.firstIndex(of: "-demo"), i + 1 < args.count {
      let parts = args[i + 1].split(separator: ":")
      if parts.count == 2, let p = Platform(rawValue: String(parts[0])) {
        let a = Account(platform: p, username: String(parts[1]))
        AccountStore.remember(a)
        AccountStore.current = a
        accounts = AccountStore.all()
        account = a
      }
    }
    #endif
    if restore, let saved = UserDefaults.standard.string(forKey: "lastAppTab"), let previous = AppTab(rawValue: saved) { tab = AppTab.primary(previous) }
    if account != nil && UserDefaults.standard.string(forKey: "gameSource") != "imported" { Task { await load() } } else { useImported() }
    #if DEBUG
    // 開發用：-tab report|practice|analysis|me 直接開那個分頁（練習的示範參數也會切過去）
    if let i = args.firstIndex(of: "-tab"), i + 1 < args.count, let t = ["games": AppTab.games, "report": .games, "openings": .openings, "practice": .practice, "analysis": .analysis, "me": .me][args[i + 1]] { tab = t; showReport = args[i + 1] == "report" }
    if args.contains("-demoPuzzle") || args.contains("-demoLesson") { tab = .practice }
    if let i = args.firstIndex(of: "-homeDemo"), let state = args[safe: i + 1], state != "first" {
      let a = Account(platform: .chesscom, username: "Home demo")
      let quiet = state == "no-highlights"
      let game = GameSummary(id: quiet ? "ui-home-demo-no-highlights" : "ui-home-demo", platform: .chesscom, endedAt: Date(), color: .white,
        opponent: "Demo opponent", myRating: nil, opponentRating: nil, result: .win, timeClass: "blitz", timeControl: "180",
        pgn: quiet ? "1. e4" : "1. e4 e5 2. Qh5 Nc6 3. Bc4 Nf6 4. Qxf7#", url: nil)
      use(a, loaded: [game])
    }

    // 開發用：-import <對局連結> 模擬從分享延伸打開
    if let i = args.firstIndex(of: "-import"), i + 1 < args.count {
      let link = args[i + 1]
      Task { await importLink(link) }
    }
    #endif
  }

  /// 存過的帳號（使用者排的順序）
  private(set) var accounts: [Account] = []

  func use(_ a: Account, loaded: [GameSummary]? = nil) {
    loadGeneration += 1; accuracyGeneration += 1; analyzedIDs = []; analysisIndexReady = false; lastLoadAttempt = nil
    usingImported = false; UserDefaults.standard.set(a.id, forKey: "gameSource")
    games = loaded ?? []; loading = false; error = nil
    AccountStore.remember(a); AccountStore.current = a
    accounts = AccountStore.all(); account = a
    Telemetry.log("source_selected", ["platform": a.platform.rawValue])
    Task { _ = await AccountLinkSync.shared.syncCurrent() }
    if let loaded {
      lastLoadAttempt = Date()
      GameCache.save(loaded, for: a); refreshAccuracy()
      NewGameMonitor.shared.observe(a, games: loaded, viewed: true)
    } else { Task { await load() } }
  }

  /// 刪掉一個帳號：刪的是目前用的就換到下一個，都沒了就回到第一次使用的畫面（分析過的棋局存檔不刪，別的帳號可能也用得到）
  func remove(_ a: Account) {
    AccountStore.remove(a)
    Task { _ = await AccountLinkSync.shared.syncCurrent() }
    AccountHistory.forget(a)
    NewGameMonitor.shared.remove(a)
    accounts = AccountStore.all()
    if account?.id == a.id {
      if let next = accounts.first { use(next) }
      else { account = nil; AccountStore.current = nil; useImported() }
    }
  }

  func move(from: IndexSet, to: Int) {
    accounts.move(fromOffsets: from, toOffset: to)
    AccountStore.save(accounts)
  }

  /// 對局列表：先顯示上次存的（馬上有東西），再到背景抓最新的；第一次用先抓 30 局，再補到 100 局
  func refreshIfNeeded(now: Date = Date()) async {
    guard !usingImported, account != nil, lastLoadAttempt.map({ now.timeIntervalSince($0) >= 60 }) ?? true else { return }
    await load()
  }

  func load() async {
    #if DEBUG
    if ProcessInfo.processInfo.arguments.contains("-homeDemo") || ProcessInfo.processInfo.arguments.contains("-accountDemo") { return }
    #endif
    guard !usingImported, let a = account, !loading else { return }
    loading = true; lastLoadAttempt = Date()
    let generation = loadGeneration
    if games.isEmpty, let cached = GameCache.load(a) {
      games = cached
      refreshAccuracy()
    }
    do {
      if games.isEmpty {
        let recent = try await fetchGames(a, 30)
        guard generation == loadGeneration, account == a, !usingImported else { return }
        games = recent; refreshAccuracy()
      }
      let all = try await fetchGames(a, 100)
      guard generation == loadGeneration, account == a, !usingImported else { return }
      games = all
      GameCache.save(all, for: a)
      WidgetBridge.update(latest: all.first)
      error = nil
      AccountHistory.mark(a)
      NewGameMonitor.shared.observe(a, games: all, viewed: true)
      refreshAccuracy()
      // 背景提醒只提醒這之後的新對局
      if let newest = games.first { UserDefaults.standard.set(newest.endedAt.timeIntervalSince1970, forKey: "lastSeenGame-\(a.id)") }
      // The single-game entry analyses only the game the learner chooses.
    } catch {
      guard generation == loadGeneration, account == a, !usingImported else { return }
      if case SourceError.empty = error {
        AccountHistory.mark(a); games = []; self.error = nil
        NewGameMonitor.shared.observe(a, games: [], viewed: true)
      } else { self.error = (error as? LocalizedError)?.errorDescription ?? String(localized: "暫時抓不到對局") }
      AppLog.add("error", "games: \(self.error ?? "")")
    }
    loading = false
  }

  // MARK: 分享進來的對局

  /// rookielab://import?url=…（分享延伸）或貼上的對局連結
  func handle(_ url: URL) {
    Telemetry.log("open_url", ["host": url.host ?? url.scheme ?? ""])
    // 小工具點進來：rookielab://practice、rookielab://latest
    if url.scheme == "rookielab", url.host == "report" { tab = .report; return }
    if url.scheme == "rookielab", url.host == "openings" { tab = .openings; return }
    if url.scheme == "rookielab", url.host == "practice" { run(.practice); return }
    if url.scheme == "rookielab", url.host == "latest" { run(.latestGame); return }
    guard url.scheme == "rookielab", url.host == "import",
          let link = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "url" })?.value else { return }
    Task { await importLink(link) }
  }

  /// 從對局連結認出帳號：存過的帳號裡有其中一方就用它；連結帶了 /white、/black 就用那一方；都沒有才問
  func importLink(_ text: String) async {
    legacyRoute = nil; tab = .games
    guard let link = GameLink.find(in: text) else { importing = .failed(String(localized: "這不是 Chess.com 或 Lichess 的對局連結。")); return }
    importing = .loading
    do {
      let s = try await GameSources.shared(link)
      let saved = ([account].compactMap { $0 } + accounts).filter { $0.platform == s.platform }.map { $0.username.lowercased() }
      if let me = saved.first(where: { $0 == s.white.lowercased() || $0 == s.black.lowercased() }) {
        await finishImport(s, user: me == s.white.lowercased() ? s.white : s.black)
      } else if let side = s.hint {
        // 新帳號也不用問：連結帶了分享的那一方
        await finishImport(s, user: side == .white ? s.white : s.black)
      } else {
        importing = .pickSide(s)
      }
    } catch {
      importing = .failed(String(localized: "找不到這局，可能是還沒結束的對局，或連結不完整。"))
    }
  }

  func finishImport(_ s: GameSources.Shared, user: String) async {
    importing = .loading
    do {
      let g = try await s.fetch(user)
      importing = nil
      addImported(g)
    } catch {
      importing = .failed(String(localized: "找到帳號了，但抓不到這局的棋譜，稍後再試。"))
    }
  }

  func refreshAccuracy() {
    if let g = games.first { WidgetBridge.update(latest: g) }
    let gs = games
    accuracyGeneration += 1
    let token = accuracyGeneration
    Task.detached(priority: .utility) {
      var out: [String: Double] = [:]
      var completed = Set<String>()
      for g in gs {
        guard let a = AnalysisStore.load(g.id) else { continue }
        completed.insert(g.id)
        let mine = a.records.compactMap { $0 }.filter { $0.mover == g.color }.map(\.accuracy)
        if !mine.isEmpty { out[g.id] = Grading.gameAccuracy(mine) }
      }
      await MainActor.run { [out, completed] in
        guard self.accuracyGeneration == token else { return }
        self.accuracy = out; self.analyzedIDs = completed; self.analysisIndexReady = true
      }
    }
  }
}

enum AppTab: String, Hashable, Identifiable {
  case games, report, openings, practice, analysis, me
  var id: String { rawValue }
  static func primary(_ previous: Self) -> Self { previous == .me ? .me : .games }
}

struct RootView: View {
  private var coursePreview: OpeningCourse? {
    #if DEBUG
    let args = ProcessInfo.processInfo.arguments
    if let i = args.firstIndex(of: "-course"), let id = args[safe: i + 1] { return OpeningCourse.all.first { $0.id == id } }
    #endif
    return nil
  }
  private var openingPreview: Bool {
    #if DEBUG
    ProcessInfo.processInfo.arguments.contains("-openingBoard")
    #else
    false
    #endif
  }
  @State private var app = AppModel()
  @State private var splash = true
  @State private var updates = AppUpdateService.shared


  var body: some View {
    ZStack {
      if let coursePreview {
        NavigationStack {
          if ProcessInfo.processInfo.arguments.contains("-courseRecall"), let stage = coursePreview.stages.last { OpeningCourseLessonView(course: coursePreview, stage: stage, recall: true) }
          else if ProcessInfo.processInfo.arguments.contains("-courseLesson") { OpeningCourseLessonView(course: coursePreview, stage: coursePreview.stages[0]) }
          else { OpeningCourseView(course: coursePreview) }
        }
      } else if ProcessInfo.processInfo.arguments.contains("-courseCatalog") && _isDebugAssertConfiguration() {
        NavigationStack { OpeningCoursesView() }
      } else if openingPreview {
        NavigationStack { OpeningAnalysisView(account: "local") }
      } else {
        TabView(selection: $app.tab) {
          Tab("復盤", systemImage: "list.bullet.rectangle.portrait", value: .games) {
            NavigationStack { GamesHubView() }
          }
          Tab("設定", systemImage: "person.crop.circle", value: .me) {
            NavigationStack { MeView() }
          }
        }
        .tabViewStyle(.sidebarAdaptable)
      }
      if splash {
        SplashView { withAnimation(.easeOut(duration: 0.35)) { splash = false } }
          .transition(.opacity.combined(with: .scale(scale: 1.08)))
          .zIndex(10)
      }
    }
    .environment(app)
    .tint(Brand.orange)
    .fullScreenCover(isPresented: Binding(get: {
      updates.decision == .required && app.openGame == nil && app.tab == .games && !AnalysisActivity.shared.running && !AnalysisActivity.shared.reviewing
    }, set: { _ in })) { RequiredAppUpdateView().interactiveDismissDisabled() }
    .onOpenURL { app.handle($0) }
    // Siri／捷徑、小工具：冷啟動時在 task 接，App 開著時在 onChange 接
    .task { if let a = Router.shared.pending { Router.shared.pending = nil; app.run(a) } }
    .onChange(of: Router.shared.pending) { _, a in if let a { Router.shared.pending = nil; app.run(a) } }
    .onChange(of: app.tab) { _, t in
      AppLog.add("tab", "\(t)")
    }
    .task {
      app.tab = AppTab.primary(app.tab)
      app.legacyRoute = nil
      app.showReport = false
    }
    .overlay(alignment: .top) {
      if case .loading = app.importing {
        Label("讀取分享的對局…", systemImage: "arrow.down.circle").font(.subheadline.weight(.medium))
          .padding(.horizontal, 16).padding(.vertical, 10).background(.regularMaterial, in: Capsule())
          .padding(.top, 8).transition(.move(edge: .top).combined(with: .opacity))
      }
    }
    .sheet(item: Binding(get: { if case .pickSide = app.importing { app.importing } else { nil } }, set: { app.importing = $0 })) { st in
      if case let .pickSide(s) = st { PickSideSheet(shared: s) { u in Task { await app.finishImport(s, user: u) } } }
    }
    .alert("沒辦法打開這局", isPresented: Binding(get: { if case .failed = app.importing { true } else { false } }, set: { if !$0 { app.importing = nil } })) {
      Button("好") { app.importing = nil }
    } message: {
      if case let .failed(m) = app.importing { Text(m) }
    }
  }
}

/// 分享進來的對局：看不出哪一方是你時，讓你選（之後會記住這個帳號）
struct PickSideSheet: View {
  let shared: GameSources.Shared
  let pick: (String) -> Void
  var body: some View {
    VStack(spacing: 14) {
      Text("這局哪一方是你？").font(.title3.bold()).padding(.top, 24)
      Text("這次只用來決定分析哪一方，不需要加入棋站帳號。").font(.footnote).foregroundStyle(.secondary).multilineTextAlignment(.center)
      ForEach([(Side.white, shared.white), (Side.black, shared.black)], id: \.1) { side, name in
        Button { pick(name) } label: {
          HStack {
            Circle().fill(side == .white ? Color.white : Brand.ink).overlay(Circle().stroke(Color.gray.opacity(0.5))).frame(width: 16, height: 16)
            Text(name).font(.headline)
            Spacer()
            Text(side == .white ? String(localized: "執白") : String(localized: "執黑")).font(.subheadline).foregroundStyle(.secondary)
          }
          .padding(.horizontal, 16).frame(minHeight: 52)
        }
        .buttonStyle(.bordered).buttonBorderShape(.roundedRectangle(radius: 12)).tint(Brand.ink)
      }
      Spacer()
    }
    .padding(.horizontal, 20)
    .presentationDetents([.height(300)])
  }
}

/// 對局連結（跟分享延伸的 ShareLink.find 同一組規則）
enum GameLink {
  static func find(in text: String) -> String? {
    let patterns = [
      #"https?://(www\.)?chess\.com/(analysis/)?game/(live|daily)/\d+[^\s]*"#,
      #"https?://(www\.)?chess\.com/(live|daily)/game/\d+[^\s]*"#,
      #"https?://(www\.)?lichess\.org/(game/|embed/game/)?(?!(training|analysis|practice|streamer|tutorial|features|settings|tourname|broadcas|insights)\b)[A-Za-z0-9]{8}([A-Za-z0-9]{4})?(?![A-Za-z0-9])[^\s]*"#,
    ]
    for p in patterns {
      if let r = text.range(of: p, options: .regularExpression) { return String(text[r]) }
    }
    return nil
  }
}

/// 開啟動畫：標誌跳出來點個頭、名字升上來，接著淡出到主畫面（約 1.2 秒）
struct SplashView: View {
  let done: () -> Void
  @State private var pop = false
  @State private var nod = false
  @State private var title = false

  var body: some View {
    ZStack {
      Color("LaunchBackground").ignoresSafeArea()
      VStack(spacing: 18) {
        Image("AppLogo").resizable().scaledToFit()
          .frame(width: 120, height: 120)
          .clipShape(RoundedRectangle(cornerRadius: 28, style: .continuous))
          .shadow(color: Brand.teal.opacity(0.22), radius: 16, y: 8)
          .scaleEffect(pop ? 1 : 0.4)
          .rotationEffect(.degrees(nod ? -6 : 0), anchor: .bottom)
          .opacity(pop ? 1 : 0)
        VStack(spacing: 4) {
          Text("Rookie Lab").font(.largeTitle.bold()).foregroundStyle(Brand.ink)
          Text("每一盤棋，都讓你更強").font(.subheadline).foregroundStyle(.secondary)
        }
        .offset(y: title ? 0 : 16)
        .opacity(title ? 1 : 0)
      }
    }
    .task {
      withAnimation(.spring(response: 0.45, dampingFraction: 0.55)) { pop = true }
      try? await Task.sleep(nanoseconds: 300_000_000)
      withAnimation(.easeInOut(duration: 0.16).repeatCount(3, autoreverses: true)) { nod = true }
      withAnimation(.easeOut(duration: 0.35)) { title = true }
      Haptics.bump()
      try? await Task.sleep(nanoseconds: 500_000_000)
      nod = false
      try? await Task.sleep(nanoseconds: 350_000_000)
      done()
    }
  }
}

/// 第一次打開：輸入帳號
struct OnboardingView: View {
  @Environment(AppModel.self) private var app
  let submit: (Account) -> Void
  @State private var showOpenings = false
  @State private var platform: Platform = .chesscom
  @State private var username = ""
  @FocusState private var focused: Bool

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 22) {
        HStack(spacing: 12) {
          Image("AppLogo").resizable().scaledToFit().frame(width: 56, height: 56).clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
          VStack(alignment: .leading) {
            Text("Rookie Lab").font(.title2.bold()).foregroundStyle(Brand.ink)
            Text("西洋棋對局分析").font(.subheadline).foregroundStyle(.secondary)
          }
        }
        .padding(.top, 24)
        Text("每一盤棋，\n都讓你更強").font(.largeTitle.bold()).foregroundStyle(Brand.ink)
        VStack(alignment: .leading, spacing: 10) {
          point("star.circle.fill", String(localized: "每一步評級，關鍵步標出該走的"))
          point("chart.xyaxis.line", String(localized: "跨局看出你最常在哪裡丟分"))
          point("person.2.fill", String(localized: "看同分數的人，這一步怎麼走"))
        }
        AccountForm(platform: $platform, username: $username, focused: $focused) { submit($0) }
        Button { focused = false; showOpenings = true } label: {
          Label("先探索開局，不用帳號", systemImage: "square.grid.3x3")
            .frame(maxWidth: .infinity, minHeight: 44)
        }.buttonStyle(.bordered).tint(Brand.orange)
        VStack(alignment: .leading, spacing: 8) {
          Text("或者，直接分享一局過來").font(.subheadline.weight(.semibold)).foregroundStyle(Brand.ink)
          Text("在 Chess.com、Lichess 的對局頁點分享，選 Rookie Lab，會自動認出你的帳號。也可以貼上對局連結：").font(.footnote).foregroundStyle(.secondary)
          PasteButton(payloadType: String.self) { texts in Task { await app.importLink(texts.joined(separator: " ")) } }
            .tint(Brand.orange)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Brand.cream, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
      }
      .padding(20)
    }
    .scrollDismissesKeyboard(.interactively)
    .background(Brand.paper)
    .fullScreenCover(isPresented: $showOpenings) {
      NavigationStack {
        OpeningPracticeView()
          .toolbar { ToolbarItem(placement: .cancellationAction) { Button("關閉") { showOpenings = false } } }
      }
    }
  }

  private func point(_ icon: String, _ s: String) -> some View {
    HStack(spacing: 12) {
      Image(systemName: icon).font(.title3).foregroundStyle(Brand.orange).frame(width: 28)
      Text(s).font(.body).foregroundStyle(Brand.ink)
    }
  }
}

struct AccountForm: View {
  @Binding var platform: Platform
  @Binding var username: String
  var focused: FocusState<Bool>.Binding
  let submit: (Account) -> Void

  var body: some View {
    VStack(spacing: 10) {
      Picker("平台", selection: $platform) {
        ForEach(Platform.allCases) { Text($0.name).tag($0) }
      }
      .pickerStyle(.segmented)
      TextField("輸入 \(platform.name) 帳號", text: $username)
        .textInputAutocapitalization(.never).autocorrectionDisabled()
        .focused(focused)
        .padding(14).background(.background, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(Color.gray.opacity(0.25)))
        .submitLabel(.go).onSubmit(go)
      Button(action: go) {
        Text("載入最近對局").font(.headline).frame(maxWidth: .infinity, minHeight: 50)
      }
      .buttonStyle(.borderedProminent).buttonBorderShape(.roundedRectangle(radius: 12)).tint(Brand.orange)
      .disabled(username.trimmingCharacters(in: .whitespaces).isEmpty)
    }
  }

  private func go() {
    let u = username.trimmingCharacters(in: .whitespaces)
    guard !u.isEmpty else { return }
    submit(Account(platform: platform, username: u))
  }
}

/// 對局列表：上面一排依時間類型篩（10 分鐘快棋、3+2 閃電棋…）
struct GamesView: View {
  @Environment(AppModel.self) private var app
  @Environment(\.dynamicTypeSize) private var dynamicTypeSize
  @Environment(\.scenePhase) private var scenePhase
  @State private var filter: String?
  @State private var importPGN = false
  @State private var importMethods = false
  @State private var accountPage = false
  #if DEBUG
  @State private var autoOpen: GameSummary?
  #endif

  private func updatesRefresh() async { await AppUpdateService.shared.refresh() }
  private var homeSummary: SingleGameHomeSummary {
    #if DEBUG
    if let i = ProcessInfo.processInfo.arguments.firstIndex(of: "-homeDemo"), let state = ProcessInfo.processInfo.arguments[safe: i + 1] {
      if state == "first" { return .init(kind: .firstUse) }
      let kind: SingleGameHomeSummary.Kind = state == "reviewed" ? .reviewed : state == "pending" ? .unreviewed : .newGames
      return .init(kind: kind, target: app.games.first, count: kind == .reviewed ? 0 : 1)
    }
    #endif
    let fresh = !app.usingImported ? Set(NewGameMonitor.shared.states[app.account?.id ?? ""]?.pending.map(\.id) ?? []) : []
    return .make(hasSources: !app.accounts.isEmpty, games: app.games, analyzed: app.analyzedIDs,
      indexReady: app.analysisIndexReady, fresh: fresh, loading: app.loading, failed: app.error != nil)
  }

  private var firstUseIntroduction: some View {
    VStack(alignment: .leading, spacing: 16) {
      Text("看懂剛下完的一局").font(.title2.bold())
      if !dynamicTypeSize.isAccessibilitySize {
        Text("選平台、輸入使用者名稱，再選一局開始分析。")
          .font(.body).foregroundStyle(.secondary)
      }
      Button { accountPage = true } label: {
        Text("輸入棋站帳號").font(.headline).multilineTextAlignment(.center)
          .fixedSize(horizontal: false, vertical: true).frame(maxWidth: .infinity, minHeight: 48)
      }.buttonStyle(.borderedProminent).tint(Brand.orange).accessibilityIdentifier("single-game-account")
      Button { importPGN = true } label: {
        Text("貼上 PGN 棋譜").frame(maxWidth: .infinity, minHeight: 44)
      }.buttonStyle(.bordered).tint(Brand.orange).accessibilityIdentifier("single-game-import")
    }.padding(.vertical, 16).accessibilityElement(children: .contain).accessibilityIdentifier("single-game-first-use")
  }

  private var returningHome: some View {
    VStack(alignment: .leading, spacing: 14) {
      Menu {
        Button("匯入的對局") { app.useImported() }
        ForEach(app.accounts) { a in Button("\(a.platform.name) · \(a.username)") { app.use(a) } }
      } label: {
        Label(app.usingImported ? String(localized: "匯入的對局") : app.account.map { "\($0.platform.name) · \($0.username)" } ?? String(localized: "對局來源"), systemImage: "person.crop.circle")
          .font(.subheadline).fixedSize(horizontal: false, vertical: true)
      }
      nextGameContent
      ViewThatFits(in: .horizontal) {
        HStack(spacing: 20) { sourceActions }
        VStack(alignment: .leading, spacing: 12) { sourceActions }
      }.font(.subheadline)
      if app.loading && !app.games.isEmpty {
        ProgressView("檢查新對局…").font(.caption)
      } else if app.error != nil && !app.games.isEmpty {
        Text("暫時無法更新，顯示上次載入的對局。").font(.caption).foregroundStyle(.secondary)
      }
    }.buttonStyle(.borderless).tint(Brand.orange)
      .padding(.vertical, 8).accessibilityElement(children: .contain).accessibilityIdentifier("single-game-returning-home")
  }

  @ViewBuilder private var sourceActions: some View {
    Button("管理棋站帳號") { accountPage = true }.accessibilityIdentifier("single-game-account")
    Button("貼上 PGN 棋譜") { importPGN = true }.accessibilityIdentifier("single-game-import")
  }

  @ViewBuilder private var nextGameContent: some View {
    let summary = homeSummary
    switch summary.kind {
    case .newGames, .unreviewed:
      Text(summary.kind == .newGames ? String(localized: "偵測到新對局") : String(localized: "最近有尚未分析的對局"))
        .font(.headline).accessibilityIdentifier("single-game-next-status")
      if let game = summary.target {
        Text(game.versusTitle).font(.subheadline)
        Text(game.dateText).font(.caption).foregroundStyle(.secondary)
        Button { app.openGame = game } label: {
          Text(game.id == app.reportGames.sorted(by: { $0.endedAt > $1.endedAt }).first?.id ? String(localized: "分析最新一局") : String(localized: "分析這一局")).font(.headline).multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true).frame(maxWidth: .infinity, minHeight: 44)
        }.buttonStyle(.borderedProminent).tint(Brand.orange).accessibilityIdentifier("single-game-analyze-latest")
      }
    case .reviewed:
      Text("最近的對局都已分析").font(.headline).accessibilityIdentifier("single-game-next-status")
      if let game = summary.target {
        Button("查看最近復盤") { app.openGame = game }.accessibilityIdentifier("single-game-view-latest")
      }
      if !app.usingImported { Button("檢查新對局") { Task { await app.load() } }.disabled(app.loading) }
    case .checking:
      ProgressView("檢查新對局…")
    case .empty:
      Text(app.usingImported ? String(localized: "目前沒有匯入的棋局") : String(localized: "這個帳號目前沒有可分析的棋局"))
        .font(.headline)
      if !app.usingImported { Button("檢查新對局") { Task { await app.load() } }.disabled(app.loading) }
    case .unavailable:
      Text("暫時無法更新對局").font(.headline)
      Button("重新載入對局") { Task { await app.load() } }.disabled(app.loading)
    case .firstUse: EmptyView()
    }
  }

  private var types: [GameType] { GameType.types(app.games) }
  private var shown: [GameSummary] {
    if homeSummary.kind == .firstUse { return [] }
    return filter.map { f in app.games.filter { GameType.key($0) == f } } ?? app.games }

  var body: some View {
    @Bindable var app = app
    ScrollViewReader { proxy in
      List {
        if AppUpdateService.shared.shouldRecommend {
          Section {
            Link("有新版本，前往更新", destination: AppUpdateService.shared.updateURL)
            Button("稍後提醒") { AppUpdateService.shared.deferRecommendation() }
          }
        }
        Section {
          if homeSummary.kind == .firstUse { firstUseIntroduction }
          else { returningHome }
        }.listRowSeparator(.hidden)
        if SingleGameAdvertising.shared.banner != nil && !Premium.shared.active && Premium.shared.entitlementReady {
          Section { SingleGameAdSlot() }
        }
        // 篩選列放在區段標題：往下滑時固定在導覽列下面，大標題收合時不會互相蓋住
        Section {
          if app.loading && app.games.isEmpty {
            HStack { ProgressView(); Text("載入對局…").foregroundStyle(.secondary) }
          }
          if let e = app.error {
            Text(e).foregroundStyle(.secondary)
            if homeSummary.kind != .unavailable && homeSummary.kind != .reviewed {
              Button("重新載入對局") { Task { await app.load() } }
            }
          }
          ForEach(shown) { g in
            NavigationLink(value: g) { GameRow(game: g, accuracy: app.accuracy[g.id]) }.id(g.id)
          }
        } header: {
          Text("最近對局").textCase(nil)
          if types.count > 1 {
            TypeFilter(types: types, total: app.games.count, selected: $filter)
              .listRowInsets(EdgeInsets())
              .textCase(nil)
          }
        }
      }
      .listStyle(.plain)
      #if DEBUG
      // 開發用：-scrollDemo 捲到第 15 局（截圖看捲動後的樣子）
      .onChange(of: app.games.count) {
        if ProcessInfo.processInfo.arguments.contains("-scrollDemo"), app.games.count > 15 {
          Task { try? await Task.sleep(nanoseconds: 800_000_000); withAnimation { proxy.scrollTo(app.games[15].id, anchor: .top) } }
        }
      }
      #endif
    }
    .trackedScreen("home")
    .navigationTitle("復盤")
    .task(id: "\(Premium.shared.active):\(Premium.shared.entitlementReady)") {
      SingleGameAdvertising.shared.update(adFree: Premium.shared.active, entitlementReady: Premium.shared.entitlementReady)
    }
    .sheet(isPresented: $importPGN) { ImportPGNView() }
    .sheet(isPresented: $importMethods) { SingleGameImportMethods() }
    // 點標題切換帳號（iOS 原生的標題選單）
    .toolbarTitleMenu {
      ForEach(app.accounts) { a in
        Button { app.use(a) } label: {
          if a.id == app.account?.id { Label("\(a.username)・\(a.platform.name)", systemImage: "checkmark") } else { Text("\(a.username)・\(a.platform.name)") }
        }
      }
      Divider()
      Button { app.tab = .me } label: { Label("管理帳號", systemImage: "person.2") }
    }
    .navigationDestination(isPresented: $accountPage) { OpeningAccountView() }
    .navigationDestination(for: GameSummary.self) { ReviewView(game: $0) }
    .navigationDestination(item: $app.openGame) { ReviewView(game: $0) }
    .toolbar {
      ToolbarItem(placement: .topBarTrailing) {
        Button("匯入方式") { importMethods = true }
          .accessibilityIdentifier("single-game-import-methods")
      }
    }
    .refreshable { await app.load() }
    .onAppear { app.refreshAccuracy() }
    .task { await updatesRefresh(); await app.refreshIfNeeded() }
    .onChange(of: scenePhase) { _, phase in if phase == .active { Task { await app.refreshIfNeeded() } } }
    #if DEBUG
    .onChange(of: app.games.count) {
      let args = ProcessInfo.processInfo.arguments
      if let i = args.firstIndex(of: "-demoReview"), autoOpen == nil {
        let n = args[safe: i + 1].flatMap { Int($0) } ?? 0
        autoOpen = app.games[safe: n] ?? app.games.first
      }
    }
    .navigationDestination(item: $autoOpen) { ReviewView(game: $0) }
    #endif
  }
}

/// 時間類型篩選：系統膠囊按鈕，只能左右滑，放手後對齊到某一顆
struct TypeFilter: View {
  let types: [GameType]
  let total: Int
  @Binding var selected: String?

  var body: some View {
    ScrollView(.horizontal, showsIndicators: false) {
      HStack(spacing: 8) {
        chip(String(localized: "全部"), short: nil, n: total, key: nil)
        ForEach(types) { t in chip(t.label, short: t.short, n: t.games, key: t.key) }
      }
      .scrollTargetLayout()
    }
    .scrollTargetBehavior(.viewAligned)
    .scrollBounceBehavior(.basedOnSize, axes: .vertical)
    .contentMargins(.horizontal, 16, for: .scrollContent)
    .frame(height: 52)
    .background(.bar)
    .overlay(alignment: .bottom) { Divider() }
  }

  @ViewBuilder private func chip(_ label: String, short: String?, n: Int, key: String?) -> some View {
    let on = selected == key
    let action = {
      Haptics.tick()
      withAnimation(.snappy) { selected = key }
    }
    let text = HStack(spacing: 5) {
      Text(label)
      if let short, !label.hasPrefix(short) { Text(short).monospacedDigit().opacity(0.75) }
      Text("\(n)").monospacedDigit().opacity(0.6)
    }
    .font(.subheadline.weight(on ? .semibold : .regular))
    if on {
      Button(action: action) { text }.buttonStyle(.borderedProminent).buttonBorderShape(.capsule).tint(Brand.orange)
    } else {
      Button(action: action) { text }.buttonStyle(.bordered).buttonBorderShape(.capsule).tint(.secondary)
    }
  }
}

/// 分享教學：在 Chess.com、Lichess 的對局按分享 → Rookie Lab。看過可以收起來
struct ShareGuideCard: View {
  @AppStorage("shareGuideHidden") private var hidden = false
  @State private var detail = false

  var body: some View {
    if !hidden {
      VStack(alignment: .leading, spacing: 10) {
        HStack {
          Label("分享對局，直接打開", systemImage: "square.and.arrow.up").font(.subheadline.weight(.semibold)).foregroundStyle(Brand.orange)
          Spacer()
          Button { withAnimation { hidden = true } } label: { Image(systemName: "xmark").font(.caption.weight(.bold)).foregroundStyle(.secondary) }
            .buttonStyle(.plain).accessibilityLabel("收起教學")
        }
        step(1, String(localized: "在 Chess.com 或 Lichess 的對局頁，點分享"))
        step(2, String(localized: "選 Rookie Lab"))
        step(3, String(localized: "選擇你執哪一方，打開這局的復盤"))
        Button("第一次在分享選單找不到？") { detail = true }.font(.footnote)
      }
      .padding(14)
      .background(Brand.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
      .listRowSeparator(.hidden)
      .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
      .sheet(isPresented: $detail) { ShareGuideDetail().presentationDetents([.medium, .large]) }
    }
  }

  private func step(_ n: Int, _ s: String) -> some View {
    HStack(alignment: .firstTextBaseline, spacing: 10) {
      Text("\(n)").font(.caption.bold()).frame(width: 20, height: 20).background(Brand.orange, in: Circle()).foregroundStyle(.white)
      Text(s).font(.subheadline).foregroundStyle(Brand.ink)
    }
  }
}

struct ShareGuideDetail: View {
  var body: some View {
    NavigationStack {
      List {
        Section("把 Rookie Lab 加進分享選單") {
          Label("在分享選單的 App 那一排滑到最右邊，點「更多」", systemImage: "ellipsis.circle")
          Label("點右上角「編輯」，把 Rookie Lab 加到「喜好項目」，之後會排在前面", systemImage: "star")
        }
        Section("Chess.com") {
          Label("打開一局（對局結束畫面，或對局紀錄裡的一局），點分享圖示", systemImage: "square.and.arrow.up")
          Label("分享「連結」，不是分享圖片或 GIF", systemImage: "link")
        }
        Section("Lichess") {
          Label("打開一局，點分享（或選單裡的分享），分享對局連結", systemImage: "square.and.arrow.up")
        }
        Section("也可以貼上") {
          Label("複製對局連結，到「對局」頁點右上角的貼上按鈕", systemImage: "doc.on.clipboard")
        }
      }
      .navigationTitle("分享對局").navigationBarTitleDisplayMode(.inline)
    }
  }
}

struct GameRow: View {
  let game: GameSummary
  var accuracy: Double?

  var body: some View {
    HStack(spacing: 12) {
      Text(game.termination == "unfinished" || game.termination == "unknown" ? "—" : game.result == .win ? String(localized: "勝") : game.result == .loss ? String(localized: "負") : String(localized: "和"))
        .font(.subheadline.bold()).frame(width: 32, height: 32)
        .background(resultColor.opacity(0.15), in: Circle())
        .foregroundStyle(resultColor)
      VStack(alignment: .leading, spacing: 3) {
        HStack(spacing: 4) {
          Circle().fill(game.color == .white ? Color.white : Brand.ink).overlay(Circle().stroke(Color.gray.opacity(0.5))).frame(width: 9, height: 9)
          Text(game.opponent).foregroundStyle(Brand.ink).lineLimit(1)
          if let r = game.opponentRating { Text("\(r)").font(.subheadline).foregroundStyle(.secondary) }
        }
        Text("\(game.dateText) · \(GameType.label(GameType.key(game))) · \(Openings.family(game.openingRaw))")
          .font(.caption).foregroundStyle(.secondary).lineLimit(1)
      }
      Spacer(minLength: 4)
      if let accuracy {
        Text(String(format: "%.0f", accuracy)).font(.subheadline.bold().monospacedDigit()).foregroundStyle(Brand.orange)
          .accessibilityLabel("準確率 \(Int(accuracy))")
      }
    }
    .padding(.vertical, 2)
  }

  private var resultColor: Color { game.result == .win ? .green : game.result == .loss ? .red : .gray }
}

/// 我的：帳號切換、設定、關於
struct MeView: View {
  @Environment(AppModel.self) private var app
  @State private var adding = false
  @State private var platform: Platform = .chesscom
  @State private var username = ""
  @FocusState private var focused: Bool
  @AppStorage(Sounds.key) private var sound = Sounds.Theme.soft.rawValue
  @State private var confirm: Account?
  @State private var feedback = false
  @State private var remind = Notifier.enabled
  @State private var remindHour = Notifier.hour
  @State private var autoAdd = AutoAnalyzer.autoAdd
  @State private var showPaywall = false

  var body: some View {
    List {
      Section {
        ForEach(app.accounts) { a in
          Button { app.use(a); app.tab = .games; Haptics.tick() } label: {
            HStack(spacing: 12) {
              Image(systemName: a.platform == .chesscom ? "c.circle.fill" : "l.circle.fill")
                .font(.title2).foregroundStyle(a.platform == .chesscom ? Color(hex: 0x81B64C) : Brand.ink)
              VStack(alignment: .leading, spacing: 1) {
                Text(a.username).foregroundStyle(Brand.ink)
                Text(a.platform.name).font(.caption).foregroundStyle(Color.gray)
              }
              Spacer()
              if a.id == app.account?.id { Image(systemName: "checkmark").font(.body.weight(.semibold)).foregroundStyle(Brand.orange) }
            }
          }
          .swipeActions(edge: .trailing) {
            Button(role: .destructive) { confirm = a } label: { Label("刪除", systemImage: "trash") }
          }
        }
        .onMove { app.move(from: $0, to: $1) }
        .onDelete { idx in idx.map { app.accounts[$0] }.forEach { app.remove($0) } }
        Button { adding = true } label: { Label("加一個帳號", systemImage: "plus") }
      } header: {
        Text("帳號")
      } footer: {
        Text("點一下切換；往左滑刪除；右上角「編輯」可以調整順序。刪除只是從這支手機移除，不影響你的 Chess.com、Lichess 帳號。")
      }
      Section {
        if Premium.shared.active {
          Label("Premium 使用中", systemImage: "checkmark.seal.fill").foregroundStyle(Brand.orange)
          Button("管理訂閱") { Task { if let w = UIApplication.shared.connectedScenes.first as? UIWindowScene { try? await AppStore.showManageSubscriptions(in: w) } } }
        } else {
          Button { showPaywall = true } label: { Label("訂閱與移除廣告", systemImage: "rectangle.badge.checkmark") }
          Button("恢復購買") { Task { await Premium.shared.restore() } }
        }
      } header: {
        Text("Premium")
      }
      Section {
        NavigationLink("分享對局說明") { SingleGameShareHelp() }
        NavigationLink("新棋局提醒") { NewGameReminderSettings() }
        #if canImport(GoogleMobileAds) && canImport(UserMessagingPlatform)
        Button("廣告隱私選項") { Task { try? await AdMobPilot.shared.privacyOptions() } }
        #endif
        NavigationLink("App 版本與更新") { AppUpdateSettings() }
        NavigationLink("使用統計與隱私") { UsagePrivacySettings() }
      }
      Section {
        Picker("走子聲音", selection: $sound) {
          ForEach(Sounds.Theme.allCases) { Text($0.zh).tag($0.rawValue) }
        }
        .onChange(of: sound) { _, v in
          if let t = Sounds.Theme(rawValue: v), t != .off { Sounds.play("move", theme: t) }
        }
      } header: {
        Text("設定")
      } footer: {
        Text("走子聲音選了會先播一次給你聽。")
      }
      Section {
        Button { feedback = true } label: { Label("給我們回饋", systemImage: "bubble.left.and.text.bubble.right") }
      } footer: {
        Text("遇到問題、想要的功能、哪裡看不懂，兩分鐘填完。每一則都會看。")
      }
      Section("關於") {
        Text("Rookie Lab 幫你看懂每一盤棋：每一步評級，關鍵步標出該走的，跟同分數的玩家比較。")
        Link("網站版 rookielab.io", destination: URL(string: "https://rookielab.io")!)
        Text("引擎：Stockfish 17，在手機上運算，不用網路也能分析。").font(.footnote).foregroundStyle(.secondary)
      }
      Section("授權與致謝") {
        Text("Stockfish（GPLv3）· stockfishchess.org")
        Text("ChessKit、ChessKitEngine（MIT）· chesskit-app")
        Text("棋子圖：cburnett（CC BY-SA 3.0）")
        Text("走法資料庫：Lichess 開放資料（CC0）")
      }
      .font(.footnote)
    }
    .trackedScreen("settings")
    .navigationTitle("設定")
    // sheet 掛在 List 上；掛在 Section 上不會彈出
    .sheet(isPresented: $showPaywall) { PaywallView(from: "ads") }
    .sheet(isPresented: $feedback) { FeedbackForm(trigger: "menu", task: "other") }
    #if DEBUG
    .task { if ProcessInfo.processInfo.arguments.contains("-openFeedback") { try? await Task.sleep(nanoseconds: 1_500_000_000); feedback = true } }
    #endif
    .toolbar { if app.accounts.count > 1 { EditButton() } }
    .confirmationDialog("刪除 \(confirm?.username ?? "") ？", isPresented: Binding(get: { confirm != nil }, set: { if !$0 { confirm = nil } }), titleVisibility: .visible) {
      Button("從這支手機移除", role: .destructive) { if let c = confirm { withAnimation { app.remove(c) } }; confirm = nil }
    } message: {
      Text(confirm?.id == app.account?.id ? String(localized: "這是目前用的帳號，刪除後會換到下一個帳號。") : String(localized: "之後可以再加回來。"))
    }
    .sheet(isPresented: $adding) {
      NavigationStack {
        OpeningAccountView()
          .toolbar { ToolbarItem(placement: .cancellationAction) { Button("取消") { adding = false } } }
      }
    }
  }
}

/// 對局列表存在手機上（每個帳號一份），打開 App 先顯示，不用等網路
enum GameCache {
  private static func file(_ a: Account) -> URL {
    FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
      .appendingPathComponent("games-\(a.id.replacingOccurrences(of: "[^A-Za-z0-9_-]", with: "_", options: .regularExpression)).json")
  }
  static func load(_ a: Account) -> [GameSummary]? {
    guard let d = try? Data(contentsOf: file(a)), let g = try? JSONDecoder().decode([GameSummary].self, from: d), !g.isEmpty else { return nil }
    return g
  }
  static func save(_ g: [GameSummary], for a: Account) {
    try? JSONEncoder().encode(g).write(to: file(a), options: .atomic)
  }
}
