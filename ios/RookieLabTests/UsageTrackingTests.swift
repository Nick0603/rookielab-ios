import XCTest
@testable import RookieLab

final class UsageTrackingTests: XCTestCase {
  func testFirebaseNamesDoNotCollideWithAutomaticAdAndSessionEvents() {
    XCTAssertEqual(UsageEventPolicy.firebaseName("ad_impression"), "rl_ad_impression")
    XCTAssertEqual(UsageEventPolicy.firebaseName("session_start"), "rl_session_start")
    XCTAssertEqual(UsageEventPolicy.firebaseName("screen_view"), "screen_view")
    XCTAssertLessThanOrEqual(UsageEventPolicy.firebaseName(String(repeating: "a", count: 40)).count, 40)
  }
  func testRawAccountAndCredentialsCannotEnterEventParameters() {
    let input: [String: Any] = ["username": "a_player", "account_name": "a_player", "email": "a@example.com",
                               "link_token": "secret", "pgn": "1.e4 *", "fen": "position", "opponent": "name",
                               "screen_name": "home", "duration_ms": 123, "platform": "chesscom"]
    let clean = UsageEventPolicy.parameters(input)
    XCTAssertEqual(Set(clean.keys), ["screen_name", "duration_ms", "platform"])
  }
  func testEventBoundsAndUnsafeValues() {
    let clean = UsageEventPolicy.parameters(["bad-key": "x", "source": "https://example.com/private", "host": "a@example.com",
                                            "good": String(repeating: "a", count: 100), "value": Double.infinity])
    XCTAssertEqual(clean.keys.sorted(), ["good"])
    XCTAssertEqual((clean["good"] as? String)?.count, 64)
    XCTAssertLessThanOrEqual(UsageEventPolicy.parameters(Dictionary(uniqueKeysWithValues: (0..<20).map { ("key_\($0)", $0 as Any) })).count, 9)
  }
  func testOlderQueuedEventsStillDecodeAndNewIDsPersist() throws {
    let old = try JSONDecoder().decode(Events.Event.self, from: Data(#"{"n":"screen_view","t":1}"#.utf8))
    XCTAssertNil(old.id)
    let id = UUID().uuidString
    let current = Events.Event(n: "analysis_complete", p: ["duration_ms": .n(123)], t: 2, id: id)
    let decoded = try JSONDecoder().decode(Events.Event.self, from: JSONEncoder().encode(current))
    XCTAssertEqual(decoded.id, id)
    XCTAssertTrue(UsageEventPolicy.parameters(["duration_ms": 1])["duration_ms"] is Int)
  }
  func testAccountSharingOffByDefaultAndRequiresUsageCollection() {
    let defaults = UserDefaults.standard
    let oldUsage = defaults.object(forKey: UsagePrivacy.usageKey), oldAccount = defaults.object(forKey: UsagePrivacy.accountKey)
    defer {
      defaults.set(oldUsage, forKey: UsagePrivacy.usageKey); defaults.set(oldAccount, forKey: UsagePrivacy.accountKey)
    }
    defaults.removeObject(forKey: UsagePrivacy.accountKey)
    XCTAssertFalse(UsagePrivacy.shareAccounts)
    defaults.set(true, forKey: UsagePrivacy.accountKey); defaults.set(false, forKey: UsagePrivacy.usageKey)
    XCTAssertFalse(UsagePrivacy.shareAccounts)
  }
}
