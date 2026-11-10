import XCTest
@testable import RookieLab

@MainActor final class AccountConnectionTests: XCTestCase {
  var saved: [Account] = []
  var current: Account?
  override func setUp() { saved = AccountStore.all(); current = AccountStore.current; AccountStore.save([]); AccountStore.current = nil }
  override func tearDown() { for a in AccountStore.all() { AccountHistory.forget(a) }; AccountStore.save(saved); AccountStore.current = current }
  let a = Account(platform: .chesscom, username: "Rookie_test")
  func testValidEmptyAccountIsRememberedAndInvalidInputIsNotRequested() async {
    var calls = 0
    let connector = AccountConnector { _ in calls += 1; throw SourceError.empty }
    let app = AppModel(restore: false, fetch: { _, _ in [] })
    let invalid = await connector.connect(Account(platform: .chesscom, username: "https://chess.com"), to: app)
    XCTAssertFalse(invalid); XCTAssertEqual(calls, 0)
    let valid = await connector.connect(a, to: app)
    XCTAssertTrue(valid); XCTAssertEqual(calls, 1); XCTAssertTrue(AccountHistory.verified(a))
    XCTAssertEqual(app.account, a); XCTAssertTrue(app.games.isEmpty); XCTAssertNil(app.error)
  }
  func testNetworkFailureDoesNotPolluteHistory() async {
    let connector = AccountConnector { _ in throw SourceError.network }
    let app = AppModel(restore: false, fetch: { _, _ in [] })
    let ok = await connector.connect(a, to: app)
    XCTAssertFalse(ok); XCTAssertNotNil(connector.error); XCTAssertTrue(app.accounts.isEmpty)
  }
  func testRemovingCurrentAccountLoadsNextSourceAndStaleLoadCannotWin() async {
    var waits: [String: CheckedContinuation<[GameSummary], Error>] = [:]
    let started = expectation(description: "initial request")
    let app = AppModel(restore: false, fetch: { account, _ in
      if account.username == "Rookie_test" { return try await withCheckedThrowingContinuation { waits[account.id] = $0; started.fulfill() } }
      return []
    })
    let other = Account(platform: .lichess, username: "Other_test")
    app.use(other, loaded: []); app.use(a)
    await fulfillment(of: [started], timeout: 2)
    app.remove(a)
    waits[a.id]?.resume(throwing: SourceError.notFound)
    await Task.yield(); await Task.yield()
    XCTAssertEqual(app.account, other); XCTAssertNil(app.error)
    XCTAssertFalse(app.usingImported); XCTAssertEqual(AccountStore.current, other)
  }
  func testRecentUsesSuccessfulDatesAndPlatformIdentity() {
    let other = Account(platform: .lichess, username: a.username)
    AccountHistory.mark(a, at: Date(timeIntervalSince1970: 10)); AccountHistory.mark(other, at: Date(timeIntervalSince1970: 20))
    XCTAssertEqual(AccountHistory.recent([a, other]), [other, a]); AccountHistory.forget(other)
    XCTAssertEqual(AccountHistory.normalized(Account(platform: .chesscom, username: " Rookie_test \n")), a)
  }
}

final class ReminderClockTests: XCTestCase {
  var calendar: Calendar { var c = Calendar(identifier: .gregorian); c.timeZone = TimeZone(identifier: "Asia/Taipei")!; return c }
  func date(_ hour: Int, _ minute: Int = 0) -> Date { calendar.date(from: DateComponents(year: 2026, month: 11, day: 6, hour: hour, minute: minute))! }
  func testQuietHoursAndNextCheckStayInDaytime() {
    let clock = ReminderClock(calendar: calendar)
    XCTAssertFalse(clock.allowsCheck(date(8))); XCTAssertFalse(clock.allowsCheck(date(22)))
    XCTAssertTrue(clock.allowsCheck(date(9))); XCTAssertTrue(clock.allowsCheck(date(21)))
    XCTAssertEqual(calendar.component(.hour, from: clock.nextCheck(after: date(21))), 9)
    XCTAssertEqual(calendar.component(.day, from: clock.nextCheck(after: date(21))), 7)
    XCTAssertEqual(calendar.component(.hour, from: clock.nextCheck(after: date(10))), 13)
  }
  func testNotificationDoesNotCross24HourCooldownAndRespectsPreferredWindow() {
    let clock = ReminderClock(calendar: calendar)
    XCTAssertEqual(clock.notificationDate(now: date(10), hour: 20, last: nil), date(20))
    let next = clock.notificationDate(now: date(20), hour: 20, last: date(21))
    XCTAssertGreaterThanOrEqual(next.timeIntervalSince(date(21)), 86_400)
    XCTAssertEqual(calendar.component(.hour, from: next), 20)
    let quiet = clock.notificationDate(now: date(23), hour: 20, last: nil)
    XCTAssertEqual(calendar.component(.hour, from: quiet), 20)
    XCTAssertEqual(calendar.component(.day, from: quiet), 7)
  }
}

@MainActor final class MultiAccountMonitorTests: XCTestCase {
  final class Delivery: NewGameNotificationDelivery {
    var allowed = true, pending = false, fail = false
    var scheduled: [Date] = []
    func requestPermission() async -> Bool { allowed }
    func authorized() async -> Bool { allowed }
    func hasPending() async -> Bool { pending }
    func schedule(at: Date, calendar: Calendar) async throws {
      if fail { throw URLError(.notConnectedToInternet) }
      scheduled.append(at); pending = true
    }
    func cancel() { pending = false }
  }
  var defaults: UserDefaults!, suite: String!, saved: [Account] = []
  var a = Account(platform: .chesscom, username: "Monitor_test_a")
  var b = Account(platform: .lichess, username: "Monitor_test_b")
  var now: Date { calendar.date(from: DateComponents(year: 2026, month: 11, day: 6, hour: 12))! }
  var calendar: Calendar { var c = Calendar(identifier: .gregorian); c.timeZone = TimeZone(identifier: "Asia/Taipei")!; return c }
  override func setUp() {
    suite = "MultiAccountMonitorTests." + UUID().uuidString; defaults = UserDefaults(suiteName: suite)!
    saved = AccountStore.all(); AccountStore.save([a, b]); AccountHistory.mark(a); AccountHistory.mark(b)
  }
  override func tearDown() { AccountHistory.forget(a); AccountHistory.forget(b); AccountStore.save(saved); defaults.removePersistentDomain(forName: suite) }
  func game(_ id: String, at date: Date) -> GameSummary {
    GameSummary(id: id, platform: .chesscom, endedAt: date, color: .white, opponent: "opponent", myRating: nil, opponentRating: nil, result: .win, timeClass: "blitz", timeControl: "180", pgn: "1. e4 e5", url: nil)
  }
  func testBaselineIsSilentThenTwoAccountsProduceOneNotificationWithoutSwitching() async {
    let delivery = Delivery(), monitor = NewGameMonitor(defaults: defaults, delivery: delivery, calendar: calendar)
    monitor.enabled = true
    let current = AccountStore.current
    await monitor.check(now: now) { [self] _ in [game("old", at: now.addingTimeInterval(-60))] }
    XCTAssertTrue(delivery.scheduled.isEmpty)
    let later = now.addingTimeInterval(4 * 3600)
    await monitor.check(now: later) { [self] account in [game(account.id, at: later.addingTimeInterval(-60))] }
    XCTAssertEqual(delivery.scheduled.count, 1)
    XCTAssertEqual(monitor.states[a.id]?.pending.count, 1); XCTAssertEqual(monitor.states[b.id]?.pending.count, 1)
    XCTAssertEqual(AccountStore.current, current)
    delivery.pending = false
    await monitor.reconcile(now: later.addingTimeInterval(25 * 3600))
    XCTAssertEqual(delivery.scheduled.count, 1, "Same games must not be notified again")
  }
  func testFailureDoesNotReserveNotificationAndQuietHoursDoNotFetch() async {
    let delivery = Delivery(), monitor = NewGameMonitor(defaults: defaults, delivery: delivery, calendar: calendar)
    monitor.enabled = true
    var requests = 0
    await monitor.check(now: now.addingTimeInterval(12 * 3600)) { _ in requests += 1; return [] }
    XCTAssertEqual(requests, 0)
    await monitor.check(now: now) { _ in [] }
    let later = now.addingTimeInterval(4 * 3600)
    delivery.fail = true
    await monitor.check(now: later) { [self] _ in [game("new", at: later.addingTimeInterval(-60))] }
    XCTAssertNil(defaults.object(forKey: "newGameReminderReservedAt"))
    delivery.fail = false
    await monitor.reconcile(now: later)
    XCTAssertEqual(delivery.scheduled.count, 1)
    monitor.enabled = false
    XCTAssertFalse(delivery.pending)
  }
  func testSingleAccountFailureDoesNotBlockOtherAccountAndExpiredTaskStops() async {
    let monitor = NewGameMonitor(defaults: defaults, delivery: Delivery(), calendar: calendar)
    monitor.enabled = true
    await monitor.check(now: now) { [self] account in if account == a { throw SourceError.network }; return [] }
    XCTAssertEqual(monitor.states[a.id]?.failures, 1); XCTAssertNotNil(monitor.states[b.id]?.checked)
    let task = Task { await monitor.check(now: now.addingTimeInterval(4 * 3600)) { _ in try await Task.sleep(nanoseconds: 10_000_000_000); return [] } }
    task.cancel(); await task.value
  }
}
