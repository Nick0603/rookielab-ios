import XCTest
import UIKit
@testable import RookieLab

final class SubscriptionAccessTests: XCTestCase {
  let now = Date(timeIntervalSince1970: 1_800_000_000)
  func testActiveAndCancelledButUnexpiredRemainAdFree() {
    let result = SubscriptionAccess.resolve(records: [.init(expiration: now.addingTimeInterval(60), revoked: false, current: false)], cachedUntil: nil, uncertain: false, now: now)
    XCTAssertTrue(result.active); XCTAssertTrue(result.ready)
  }
  func testExpiredAndRefundedOverrideStaleCache() {
    for record in [SubscriptionAccessRecord(expiration: now, revoked: false, current: false), .init(expiration: now.addingTimeInterval(60), revoked: true, current: false)] {
      let result = SubscriptionAccess.resolve(records: [record], cachedUntil: now.addingTimeInterval(60), uncertain: false, now: now)
      XCTAssertFalse(result.active); XCTAssertTrue(result.ready)
    }
  }
  func testOfflineGrantExpiresAndUnverifiedNeverEnablesAdvertising() {
    XCTAssertTrue(SubscriptionAccess.resolve(records: [], cachedUntil: now.addingTimeInterval(60), uncertain: true, now: now).active)
    let expired = SubscriptionAccess.resolve(records: [], cachedUntil: now, uncertain: true, now: now)
    XCTAssertFalse(expired.active); XCTAssertFalse(expired.ready)
    XCTAssertTrue(SubscriptionAccess.resolve(records: [], cachedUntil: nil, uncertain: false, now: now).ready)
  }
  func testVerificationFailurePreservesPreviousSubscriberWithoutEnablingAds() {
    let result = SubscriptionAccess.resolve(records: [], cachedUntil: nil, uncertain: true, previousActive: true, now: now)
    XCTAssertTrue(result.active); XCTAssertFalse(result.ready)
  }
  func testStoreKitCurrentEntitlementIncludesBillingGracePeriod() {
    XCTAssertTrue(SubscriptionAccess.resolve(records: [.init(expiration: now.addingTimeInterval(-10), revoked: false, current: true)], cachedUntil: nil, uncertain: false, now: now).active)
  }
}

@MainActor final class SingleGameAdvertisingTests: XCTestCase {
  final class Provider: SingleGameAdProvider {
    var requests = 0
    let view = UIView()
    func bannerView(for advertisement: SingleGameAdvertisement) -> UIView? { view }
    var continuation: CheckedContinuation<SingleGameAdvertisement?, Error>?
    var requested: (() -> Void)?
    func load() async throws -> SingleGameAdvertisement? {
      requests += 1
      return try await withCheckedThrowingContinuation { continuation = $0; requested?() }
    }
  }
  func testNoRequestsForSubscriberOrUnresolvedEntitlement() async {
    let provider = Provider(), ads = SingleGameAdvertising(provider: provider)
    ads.update(adFree: true, entitlementReady: true)
    ads.update(adFree: false, entitlementReady: false)
    await Task.yield()
    XCTAssertEqual(provider.requests, 0); XCTAssertNil(ads.advertisement)
    XCTAssertFalse(SingleGameAdvertising().configured)
  }
  func testUpgradeDiscardsLateProviderCallback() async {
    let provider = Provider(), ads = SingleGameAdvertising(provider: provider)
    let requested = expectation(description: "request started")
    provider.requested = { requested.fulfill() }
    ads.update(adFree: false, entitlementReady: true)
    let request = ads.pendingLoad
    await fulfillment(of: [requested], timeout: 2)
    ads.update(adFree: true, entitlementReady: true)
    provider.continuation?.resume(returning: .init(id: "sponsor", sponsor: "Sponsor", message: "Message", destination: URL(string: "https://example.com")!))
    await request?.value
    XCTAssertNil(ads.advertisement); XCTAssertEqual(provider.requests, 1)
  }
  func testValidCreativeAndRestoredSubscriptionRemoveImmediately() async {
    let provider = Provider(), ads = SingleGameAdvertising(provider: provider)
    let requested = expectation(description: "request started")
    provider.requested = { requested.fulfill() }
    ads.update(adFree: false, entitlementReady: true)
    let request = ads.pendingLoad
    await fulfillment(of: [requested], timeout: 2)
    provider.continuation?.resume(returning: .init(id: "sponsor", sponsor: "Sponsor", message: "Message", destination: URL(string: "https://example.com")!))
    await request?.value
    XCTAssertNotNil(ads.advertisement)
    XCTAssertTrue(ads.banner === provider.view)
    ads.update(adFree: true, entitlementReady: true)
    XCTAssertNil(ads.advertisement); XCTAssertNil(ads.banner)
  }
  func testProviderFailureDoesNotBlockContent() async {
    let provider = Provider(), ads = SingleGameAdvertising(provider: provider)
    let requested = expectation(description: "request started")
    provider.requested = { requested.fulfill() }
    ads.update(adFree: false, entitlementReady: true)
    let request = ads.pendingLoad
    await fulfillment(of: [requested], timeout: 2)
    provider.continuation?.resume(throwing: URLError(.notConnectedToInternet))
    await request?.value
    XCTAssertNil(ads.advertisement)
    XCTAssertFalse(SingleGameAdvertisement(id: "a", sponsor: "Sponsor", message: "Message", destination: URL(string: "http://example.com")!).valid)
  }
  func testLegacyTabValuesHaveSafePrimaryDestination() {
    XCTAssertEqual(AppTab.primary(.me), .me)
    for tab in [AppTab.games, .openings, .practice, .report, .analysis] { XCTAssertEqual(AppTab.primary(tab), .games) }
  }
  func testHiddenFeatureDeepLinksReturnToSingleGameHome() {
    let app = AppModel(restore: false)
    app.handle(URL(string: "rookielab://openings")!)
    XCTAssertEqual(app.tab, .games); XCTAssertNil(app.legacyRoute)
    app.handle(URL(string: "rookielab://practice")!)
    XCTAssertEqual(app.tab, .games); XCTAssertNil(app.legacyRoute); XCTAssertFalse(app.startPractice)
    app.handle(URL(string: "rookielab://report")!)
    XCTAssertEqual(app.tab, .games); XCTAssertNil(app.legacyRoute)
    app.run(.latestGame)
    XCTAssertNil(app.legacyRoute); XCTAssertEqual(app.tab, .games)
  }

}

@MainActor final class DailyAnalysisAdsTests: XCTestCase {
  var defaults: UserDefaults!
  var suite: String!
  let now = Date(timeIntervalSince1970: 1_800_000_000)
  override func setUp() { suite = "DailyAnalysisAdsTests." + UUID().uuidString; defaults = UserDefaults(suiteName: suite)! }
  override func tearDown() { defaults.removePersistentDomain(forName: suite) }
  func testEveryThirdUniqueGameAndPersistsAttempt() {
    let rule = DailyAnalysisAds(defaults: defaults)
    XCTAssertFalse(rule.reserveThirdGame("first", at: now))
    rule.completed("first", at: now); rule.completed("first", at: now)
    XCTAssertFalse(rule.reserveThirdGame("first", at: now))
    rule.completed("another", at: now)
    XCTAssertTrue(rule.reserveThirdGame("second", at: now))
    XCTAssertFalse(DailyAnalysisAds(defaults: defaults).reserveThirdGame("second", at: now))
    rule.completed("second", at: now)
    XCTAssertFalse(rule.reserveThirdGame("third", at: now))
  }
  func testNextLocalDayResetsAndFailureDoesNotCount() {
    var calendar = Calendar(identifier: .gregorian); calendar.timeZone = TimeZone(secondsFromGMT: 8 * 3600)!
    let rule = DailyAnalysisAds(defaults: defaults, calendar: calendar)
    rule.completed("one", at: now)
    rule.completed("two", at: now)
    XCTAssertTrue(rule.reserveThirdGame("failed", at: now))
    XCTAssertFalse(rule.reserveThirdGame("retry", at: now))
    let tomorrow = calendar.date(byAdding: .day, value: 1, to: now)!
    XCTAssertFalse(rule.reserveThirdGame("first", at: tomorrow))
    rule.completed("first", at: tomorrow)
    rule.completed("another", at: tomorrow)
    XCTAssertTrue(rule.reserveThirdGame("second", at: tomorrow))
  }
  func testRollingWindowDoesNotResetAtMidnight() {
    var calendar = Calendar(identifier: .gregorian); calendar.timeZone = TimeZone(secondsFromGMT: 0)!
    let late = calendar.startOfDay(for: now).addingTimeInterval(23 * 3600)
    let rule = DailyAnalysisAds(defaults: defaults, calendar: calendar)
    rule.completed("one", at: late); rule.completed("two", at: late)
    XCTAssertTrue(rule.reserveThirdGame("three", at: late.addingTimeInterval(2 * 3600)))
    XCTAssertFalse(rule.reserveThirdGame("retry", at: late.addingTimeInterval(3 * 3600)))
    XCTAssertFalse(rule.reserveThirdGame("first-after-expiry", at: late.addingTimeInterval(86401)))
  }
  func testSixthAndNinthWithDailyCapAndCooldown() {
    let rule = DailyAnalysisAds(defaults: defaults)
    for i in 1...2 { rule.completed("g\(i)", at: now) }
    XCTAssertTrue(rule.reserveThirdGame("g3", at: now))
    for i in 3...5 { rule.completed("g\(i)", at: now) }
    XCTAssertFalse(rule.reserveThirdGame("g6", at: now.addingTimeInterval(599)))
    XCTAssertTrue(rule.reserveThirdGame("g6", at: now.addingTimeInterval(600)))
    for i in 6...8 { rule.completed("g\(i)", at: now) }
    XCTAssertTrue(rule.reserveThirdGame("g9", at: now.addingTimeInterval(1200)))
    for i in 9...11 { rule.completed("g\(i)", at: now) }
    XCTAssertFalse(rule.reserveThirdGame("g12", at: now.addingTimeInterval(1800)))
  }
  final class Provider: SingleGameInterstitialProvider {
    var ready = true
    var presentations = 0
    func present() async { presentations += 1 }
  }
  func testSubscriberUnknownAndNoFillNeverPresentOrBlock() async {
    let rule = DailyAnalysisAds(defaults: defaults), provider = Provider()
    rule.completed("first", at: now); rule.completed("another", at: now)
    for access in [(true, true), (false, false)] {
      await SingleGameInterstitial(provider: provider, frequency: rule, entitlement: { access }).beforeAnalysis(gameID: "second", at: now)
    }
    XCTAssertEqual(provider.presentations, 0)
    provider.ready = false
    let gate = SingleGameInterstitial(provider: provider, frequency: rule, entitlement: { (false, true) })
    await gate.beforeAnalysis(gameID: "second", at: now)
    provider.ready = true
    await gate.beforeAnalysis(gameID: "second", at: now)
    XCTAssertEqual(provider.presentations, 0)
  }
  func testReadyProviderPresentsOnlyOnce() async {
    let rule = DailyAnalysisAds(defaults: defaults), provider = Provider()
    rule.completed("first", at: now); rule.completed("another", at: now)
    let gate = SingleGameInterstitial(provider: provider, frequency: rule, entitlement: { (false, true) })
    await gate.beforeAnalysis(gameID: "second", at: now)
    await gate.beforeAnalysis(gameID: "second", at: now)
    XCTAssertEqual(provider.presentations, 1)
  }
}
