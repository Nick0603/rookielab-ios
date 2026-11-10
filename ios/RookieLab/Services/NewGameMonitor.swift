import Foundation
import Observation
import UserNotifications

struct ReminderClock {
  var calendar = Calendar.autoupdatingCurrent
  func allowsCheck(_ date: Date) -> Bool { (9..<22).contains(calendar.component(.hour, from: date)) }
  func nextCheck(after date: Date) -> Date {
    let next = date.addingTimeInterval(3 * 3600)
    if allowsCheck(next) { return next }
    return calendar.nextDate(after: next, matching: DateComponents(hour: 9, minute: 0), matchingPolicy: .nextTime) ?? next.addingTimeInterval(12 * 3600)
  }
  func notificationDate(now: Date, hour: Int, last: Date?) -> Date {
    let h = min(21, max(9, hour))
    let earliest = max(now, last?.addingTimeInterval(24 * 3600) ?? now)
    let start = calendar.date(bySettingHour: h, minute: 0, second: 0, of: earliest) ?? earliest
    // A known new game may be delivered inside the preferred one-hour window.
    if earliest >= start && earliest < start.addingTimeInterval(3600) { return earliest.addingTimeInterval(2) }
    if start > earliest { return start }
    return calendar.nextDate(after: earliest, matching: DateComponents(hour: h, minute: 0), matchingPolicy: .nextTime) ?? earliest.addingTimeInterval(86_400)
  }
}

struct MonitoredAccount: Codable {
  var baseline: Date?
  var checked: Date?
  var retryAfter: Date?
  var failures = 0
  var pending: [GameSummary] = []
  var notified: Set<String> = []
  mutating func observe(_ games: [GameSummary], now: Date) {
    if let baseline {
      let fresh = games.filter { $0.endedAt > baseline && $0.endedAt > now.addingTimeInterval(-3 * 86_400) && $0.termination != "unfinished" }
      for game in fresh where !pending.contains(where: { $0.id == game.id }) { pending.append(game) }
    }
    baseline = max(baseline ?? .distantPast, games.map(\.endedAt).max() ?? now)
    checked = now; retryAfter = nil; failures = 0
  }
}

@MainActor protocol NewGameNotificationDelivery {
  func requestPermission() async -> Bool
  func authorized() async -> Bool
  func hasPending() async -> Bool
  func schedule(at: Date, calendar: Calendar) async throws
  func cancel()
}

@MainActor final class SystemNewGameNotificationDelivery: NewGameNotificationDelivery {
  private let center = UNUserNotificationCenter.current()
  func requestPermission() async -> Bool { (try? await center.requestAuthorization(options: [.alert, .sound, .badge])) ?? false }
  func authorized() async -> Bool {
    let settings = await center.notificationSettings()
    return settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional
  }
  func hasPending() async -> Bool { await center.pendingNotificationRequests().contains { $0.identifier == "new-game-summary" } }
  func schedule(at: Date, calendar: Calendar) async throws {
    let content = UNMutableNotificationContent()
    content.title = String(localized: "有新棋局可以復盤")
    content.body = String(localized: "打開選一局，看看關鍵局面與當時可以走的選擇。")
    content.sound = .default; content.userInfo = ["route": "newGames"]
    let components = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: at)
    try await center.add(UNNotificationRequest(identifier: "new-game-summary", content: content, trigger: UNCalendarNotificationTrigger(dateMatching: components, repeats: false)))
  }
  func cancel() {
    center.removePendingNotificationRequests(withIdentifiers: ["new-game-summary"])
    center.removeDeliveredNotifications(withIdentifiers: ["new-game-summary"])
  }
}

@MainActor @Observable final class NewGameMonitor {
  static let shared = NewGameMonitor()
  private let defaults: UserDefaults
  private let delivery: any NewGameNotificationDelivery
  private let clock: ReminderClock
  private var resetPending = false
  private var checking = false
  private var generation = 0
  private var reconciling = false
  private var reconcileAgain = false
  private(set) var states: [String: MonitoredAccount]
  var enabled: Bool {
    didSet { defaults.set(enabled, forKey: "newGameReminderEnabled"); generation += 1; if !enabled { cancel() }; Task { await RemotePush.shared.sync() } }
  }
  var hour: Int {
    didSet { defaults.set(hour, forKey: "newGameReminderHour"); generation += 1; resetPending = true; Task { await reconcile() } }
  }
  var excluded: Set<String> {
    didSet { defaults.set(Array(excluded), forKey: "newGameReminderExcluded"); generation += 1; Task { await reconcile(); await RemotePush.shared.sync() } }
  }
  var firstPendingAccount: Account? {
    AccountStore.all().first { !excluded.contains($0.id) && !(states[$0.id]?.pending.isEmpty ?? true) }
  }
  init(defaults: UserDefaults = .standard, delivery: (any NewGameNotificationDelivery)? = nil, calendar: Calendar = .autoupdatingCurrent) {
    self.defaults = defaults; self.delivery = delivery ?? SystemNewGameNotificationDelivery(); self.clock = ReminderClock(calendar: calendar)
    states = defaults.data(forKey: "newGameMonitor.v1").flatMap { try? JSONDecoder().decode([String: MonitoredAccount].self, from: $0) } ?? [:]
    enabled = defaults.bool(forKey: "newGameReminderEnabled")
    hour = defaults.object(forKey: "newGameReminderHour") as? Int ?? 20
    excluded = Set(defaults.stringArray(forKey: "newGameReminderExcluded") ?? [])
  }
  func requestPermission() async {
    enabled = await delivery.requestPermission()
    if enabled { RookieLabApp.scheduleRefresh(); RemotePush.shared.register(); await reconcile() }
  }
  func observe(_ a: Account, games: [GameSummary], viewed: Bool = false) {
    generation += 1
    var state = states[a.id] ?? MonitoredAccount()
    state.observe(games, now: Date()); states[a.id] = state; save()
    Task { await reconcile(); await RemotePush.shared.sync() }
  }
  func remove(_ a: Account) {
    generation += 1; states.removeValue(forKey: a.id); excluded.remove(a.id); save()
    Task { await reconcile(); await RemotePush.shared.sync() }
  }
  func status(_ a: Account) -> String {
    guard let state = states[a.id], let at = state.checked else { return String(localized: "尚未檢查") }
    if state.failures > 0 { return String(localized: "暫時無法更新，稍後重試") }
    return at.formatted(date: .abbreviated, time: .shortened)
  }
  func check(now: Date = Date(), fetch: @escaping (Account) async throws -> [GameSummary] = { try await GameSources.recentGames($0, limit: 5) }) async {
    guard enabled, !checking, clock.allowsCheck(now) else { return }
    checking = true
    defer { checking = false }
    let accounts = AccountStore.all().filter { AccountHistory.verified($0) && !excluded.contains($0.id) }
      .sorted { (states[$0.id]?.checked ?? .distantPast) < (states[$1.id]?.checked ?? .distantPast) }
    let began = Date(), token = generation
    for a in accounts {
      guard !Task.isCancelled, enabled, generation == token, Date().timeIntervalSince(began) < 20 else { break }
      let old = states[a.id] ?? MonitoredAccount()
      guard (old.checked ?? .distantPast).addingTimeInterval(3 * 3600) <= now,
            (old.retryAfter ?? .distantPast) <= now else { continue }
      do {
        let games: [GameSummary]
        do {
          let remaining = min(8, max(0.1, 20 - Date().timeIntervalSince(began)))
          games = try await withThrowingTaskGroup(of: [GameSummary].self) { group in
            group.addTask { try await fetch(a) }
            group.addTask { try await Task.sleep(nanoseconds: UInt64(remaining * 1_000_000_000)); throw URLError(.timedOut) }
            defer { group.cancelAll() }
            return try await group.next() ?? []
          }
        } catch SourceError.empty { games = [] }
        guard !Task.isCancelled, generation == token, AccountStore.all().contains(a) else { continue }
        // Read current state after await, preserving a newer foreground observation.
        var state = states[a.id] ?? MonitoredAccount()
        if (state.checked ?? .distantPast) > now { continue }
        state.observe(games, now: now); states[a.id] = state
      } catch {
        guard generation == token, AccountStore.all().contains(a) else { continue }
        var state = states[a.id] ?? MonitoredAccount()
        state.checked = now; state.failures += 1
        state.retryAfter = now.addingTimeInterval(min(24, pow(2, Double(min(state.failures, 4)))) * 3600)
        states[a.id] = state
      }
      save()
    }
    await reconcile(now: now)
  }
  func reconcile(now: Date = Date()) async {
    if reconciling { generation += 1; reconcileAgain = true; return }
    reconciling = true
    repeat {
      reconcileAgain = false
      await reconcileOnce(now: now)
    } while reconcileAgain
    reconciling = false
  }
  private func reconcileOnce(now: Date) async {
    if resetPending {
      resetPending = false
      if let reservation = defaults.object(forKey: "newGameReminderReservedAt") as? Date, reservation > now {
        cancel()
        let past = (defaults.array(forKey: "newGameReminderReservations") as? [Date] ?? []).filter { $0 <= now }
        defaults.set(past, forKey: "newGameReminderReservations")
        if let last = past.max() { defaults.set(last, forKey: "newGameReminderReservedAt") }
        else { defaults.removeObject(forKey: "newGameReminderReservedAt") }
        for key in Array(states.keys) {
          let pendingIDs = Set(states[key]?.pending.map(\.id) ?? [])
          states[key]?.notified.subtract(pendingIDs)
        }
      }
    }
    let accounts = AccountStore.all(), ids = Set(accounts.map(\.id))
    for key in Array(states.keys) {
      guard ids.contains(key) else { states.removeValue(forKey: key); continue }
      let remainingNotified = states[key]?.notified.intersection(Set(states[key]?.pending.map(\.id) ?? [])) ?? []
      states[key]?.notified = remainingNotified
      states[key]?.pending.removeAll { AnalysisStore.load($0.id) != nil || $0.endedAt < now.addingTimeInterval(-3 * 86_400) }
    }
    save()
    guard enabled else { cancel(); return }
    // 伺服器即時推播已生效：只保留首頁的新棋局標記，不另排本機提醒，避免同一局提醒兩次。
    if RemotePush.shared.active { cancel(); return }
    let eligible = states.filter { ids.contains($0.key) && !excluded.contains($0.key) }
    let games = eligible.values.flatMap(\.pending)
    guard !games.isEmpty else { cancel(); return }
    let token = generation
    let authorized = await delivery.authorized()
    guard generation == token, enabled else { return }
    guard authorized else { cancel(); return }
    let last = defaults.object(forKey: "newGameReminderReservedAt") as? Date
    let pending = await delivery.hasPending()
    guard generation == token, enabled else { return }
    // Preserve a previously queued single summary instead of creating one per account.
    if pending { return }
    guard eligible.values.contains(where: { state in state.pending.contains { !state.notified.contains($0.id) } }) else { return }
    let at = clock.notificationDate(now: now, hour: hour, last: last)
    do {
      try await delivery.schedule(at: at, calendar: clock.calendar)
      guard generation == token, enabled else { cancel(); return }
      // Reserve only after the notification center accepts the request.
      defaults.set(at, forKey: "newGameReminderReservedAt")
      var reservations = defaults.array(forKey: "newGameReminderReservations") as? [Date] ?? []
      reservations = reservations.filter { $0 > now.addingTimeInterval(-7 * 86_400) }; reservations.append(at)
      defaults.set(reservations, forKey: "newGameReminderReservations")
      for key in eligible.keys { states[key]?.notified.formUnion(eligible[key]!.pending.map(\.id)) }
      save()
    } catch { AppLog.add("notification", "new-game scheduling failed") }
  }
  private func cancel() { delivery.cancel() }
  private func save() { if let data = try? JSONEncoder().encode(states) { defaults.set(data, forKey: "newGameMonitor.v1") } }
}

final class NewGameNotificationDelegate: NSObject, UNUserNotificationCenterDelegate {
  static let shared = NewGameNotificationDelegate()
  func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
    guard response.notification.request.content.userInfo["route"] as? String == "newGames" else { return }
    await MainActor.run { Router.shared.pending = .newGames }
  }
  func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async -> UNNotificationPresentationOptions { [] }
}
