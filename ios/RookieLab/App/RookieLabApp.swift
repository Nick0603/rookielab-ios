import BackgroundTasks
import SwiftUI
import UserNotifications

@main
struct RookieLabApp: App {
  @Environment(\.scenePhase) private var phase
  @UIApplicationDelegateAdaptor(PushAppDelegate.self) private var pushDelegate
  static let refreshId = "io.rookielab.refresh"

  init() {
    #if DEBUG
    if ProcessInfo.processInfo.arguments.contains("-usagePrivacyUITest") {
      UserDefaults.standard.set(true, forKey: UsagePrivacy.usageKey)
      UserDefaults.standard.set(false, forKey: UsagePrivacy.accountKey)
    }
    #endif
    Telemetry.start(); Premium.shared.start()
    UNUserNotificationCenter.current().delegate = NewGameNotificationDelegate.shared
  }

  var body: some Scene {
    WindowGroup {
      RootView()
        .onAppear { UsageSession.shared.change(active: true) }
        .preferredColorScheme(.light)
        .task { Sounds.preload(); try? await StockfishService.shared.prepareNets { _ in } }
    }
    .onChange(of: phase) { _, p in
      if p == .active {
        UsageSession.shared.change(active: true)
        Task { _ = await AccountLinkSync.shared.syncCurrent() }
        RemotePush.shared.register()
        Task { await RemotePush.shared.sync(seen: true) }
        Notifier.reschedule()
        Task { await Premium.shared.refresh(); await AppUpdateService.shared.refresh(); await NewGameMonitor.shared.reconcile() }
      }
      if p == .inactive || p == .background { UsageSession.shared.change(active: false) }
      if p == .background { Self.scheduleRefresh(); Telemetry.flush() }
    }
    .backgroundTask(.appRefresh(Self.refreshId)) { await Self.checkNewGames() }
  }

  @MainActor static func scheduleRefresh() {
    guard NewGameMonitor.shared.enabled else { BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: refreshId); return }
    let r = BGAppRefreshTaskRequest(identifier: refreshId)
    r.earliestBeginDate = ReminderClock().nextCheck(after: Date())
    try? BGTaskScheduler.shared.submit(r)
  }

  @MainActor static func checkNewGames() async {
    scheduleRefresh()
    await NewGameMonitor.shared.check()
  }
}
