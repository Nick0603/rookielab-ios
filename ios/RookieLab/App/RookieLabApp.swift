import BackgroundTasks
import SwiftUI
import UserNotifications

@main
struct RookieLabApp: App {
  @Environment(\.scenePhase) private var phase
  static let refreshId = "io.rookielab.refresh"

  init() { Telemetry.start() }

  var body: some Scene {
    WindowGroup {
      RootView()
        .preferredColorScheme(.light)
        .task { Sounds.preload(); try? await StockfishService.shared.prepareNets { _ in } }
    }
    .onChange(of: phase) { _, p in
      if p == .active { Notifier.reschedule() }
      if p == .background { Self.scheduleRefresh(); Telemetry.flush() }
    }
    .backgroundTask(.appRefresh(Self.refreshId)) { await Self.checkNewGames() }
  }

  /// 大約幾小時看一次有沒有新對局（系統決定實際時間）
  static func scheduleRefresh() {
    let r = BGAppRefreshTaskRequest(identifier: refreshId)
    r.earliestBeginDate = Date().addingTimeInterval(3 * 3600)
    try? BGTaskScheduler.shared.submit(r)
  }

  /// 背景：剛下完新對局就提醒一次（一天最多一則、提醒開著才發）
  static func checkNewGames() async {
    scheduleRefresh()
    let d = UserDefaults.standard
    guard d.bool(forKey: "remindOn"), let a = AccountStore.current,
          d.integer(forKey: "newGameNotified") != Day.number(),
          let games = try? await GameSources.recentGames(a, limit: 5) else { return }
    let seen = d.double(forKey: "lastSeenGame-\(a.id)")
    let fresh = games.filter { $0.endedAt.timeIntervalSince1970 > seen && AnalysisStore.load($0.id) == nil }
    guard !fresh.isEmpty else { return }
    d.set(games[0].endedAt.timeIntervalSince1970, forKey: "lastSeenGame-\(a.id)")
    d.set(Day.number(), forKey: "newGameNotified")
    let c = UNMutableNotificationContent()
    c.title = fresh.count == 1 ? "剛下完一局 vs \(fresh[0].opponent)" : "剛下完 \(fresh.count) 局"
    c.body = "打開看這局最該記住的一件事，失誤會自動變成複習題"
    c.sound = .default
    try? await UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: "newgame", content: c, trigger: nil))
  }
}
