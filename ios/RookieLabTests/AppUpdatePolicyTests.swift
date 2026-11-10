import CryptoKit
import XCTest
@testable import RookieLab

final class AppUpdatePolicyTests: XCTestCase {
  let now = Date(timeIntervalSince1970: 1_800_000_000)
  func envelope(key: Curve25519.Signing.PrivateKey, revision: Int = 3, enabled: Bool = true,
                min: String = "1.9.0", recommended: String = "1.10.0", expires: Double? = nil) throws -> Data {
    let channel: [String: Any] = ["enabled": enabled, "minimumVersion": min, "recommendedVersion": recommended, "minimumBuild": 100, "recommendedBuild": 200, "minimumOS": 18, "maximumOS": 25, "reason": ""]
    let payload: [String: Any] = ["schemaVersion": 1, "bundleID": "io.rookielab.app", "revision": revision, "effectiveAt": now.timeIntervalSince1970 - 60, "expiresAt": expires ?? now.timeIntervalSince1970 + 60, "channels": ["production": channel, "testflight": channel]]
    let bytes = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
    return try JSONEncoder().encode(AppUpdatePolicy.Envelope(payload: bytes.base64EncodedString(), signature: key.signature(for: bytes).base64EncodedString()))
  }
  func testNumericVersionComparisonAndInvalidVersions() {
    XCTAssertGreaterThan(AppVersion("1.10.0")!, AppVersion("1.9.0")!)
    XCTAssertEqual(AppVersion("1.1"), AppVersion("1.1.0"))
    for text in ["", "1..0", "1.x", "-1.0", "1.0-beta", "99999999999.0"] { XCTAssertNil(AppVersion(text)) }
  }
  func testSignedPolicyChannelBuildAndOSDecisions() throws {
    let key = Curve25519.Signing.PrivateKey()
    let policy = try XCTUnwrap(AppUpdatePolicy.verify(envelope(key: key), publicKey: key.publicKey.rawRepresentation.base64EncodedString(), now: now))
    XCTAssertEqual(policy.decision(channel: "production", version: "1.8.0", build: 999, os: 18, now: now), .required)
    XCTAssertEqual(policy.decision(channel: "production", version: "1.9.0", build: 1, os: 18, now: now), .recommended)
    XCTAssertEqual(policy.decision(channel: "testflight", version: "1.9.0", build: 1, os: 18, now: now), .required)
    XCTAssertEqual(policy.decision(channel: "production", version: "1.10.0", build: 1, os: 18, now: now), .none)
    XCTAssertEqual(policy.decision(channel: "testflight", version: "1.10.0", build: 199, os: 18, now: now), .recommended)
    XCTAssertEqual(policy.decision(channel: "production", version: "1.0.0", build: 0, os: 26, now: now), .none)
    XCTAssertEqual(policy.decision(channel: "production", version: "1.0.0", build: 0, os: 18, now: now.addingTimeInterval(61)), .none)
  }
  func testTamperingExpiryReplayAndInvalidRangeAreRejected() throws {
    let key = Curve25519.Signing.PrivateKey(), publicKey = key.publicKey.rawRepresentation.base64EncodedString()
    let data = try envelope(key: key)
    XCTAssertNil(AppUpdatePolicy.verify(data, publicKey: Curve25519.Signing.PrivateKey().publicKey.rawRepresentation.base64EncodedString(), now: now))
    XCTAssertNil(AppUpdatePolicy.verify(data, publicKey: publicKey, now: now, minimumRevision: 4))
    XCTAssertNil(AppUpdatePolicy.verify(try envelope(key: key, expires: now.timeIntervalSince1970), publicKey: publicKey, now: now))
    XCTAssertNil(AppUpdatePolicy.verify(try envelope(key: key, min: "2.0.0", recommended: "1.0.0"), publicKey: publicKey, now: now))
    var e = try JSONDecoder().decode(AppUpdatePolicy.Envelope.self, from: data)
    e = .init(payload: Data("tampered".utf8).base64EncodedString(), signature: e.signature)
    XCTAssertNil(AppUpdatePolicy.verify(try JSONEncoder().encode(e), publicKey: publicKey, now: now))
  }
  func testHigherRevisionCanDisableOrLowerMinimumForRescue() throws {
    let key = Curve25519.Signing.PrivateKey(), pub = key.publicKey.rawRepresentation.base64EncodedString()
    let disabled = try XCTUnwrap(AppUpdatePolicy.verify(envelope(key: key, revision: 4, enabled: false), publicKey: pub, now: now, minimumRevision: 3))
    XCTAssertEqual(disabled.decision(channel: "production", version: "1.0.0", build: 0, os: 18, now: now), .none)
    XCTAssertNotNil(AppUpdatePolicy.verify(try envelope(key: key, revision: 5, min: "1.0.0"), publicKey: pub, now: now, minimumRevision: 4))
  }
}

@MainActor final class AppUpdateServiceTests: XCTestCase {
  var suite: String!, defaults: UserDefaults!
  override func setUp() { suite = "AppUpdateServiceTests." + UUID().uuidString; defaults = UserDefaults(suiteName: suite)! }
  override func tearDown() { defaults.removePersistentDomain(forName: suite) }
  func testPublishedPolicyLoadsThroughNativeURLSession() async throws {
    let service = AppUpdateService(defaults: defaults)
    await service.refresh(force: true, channelOverride: "production")
    XCTAssertNotNil(defaults.data(forKey: "updatePolicyEnvelope.v1"), service.status)
    XCTAssertEqual(service.decision, .none, "Initial published policy must not force existing users to update")
  }
  func testOfflineUsesOnlyValidSignedCacheAndExpiryUnlocks() async throws {
    let key = Curve25519.Signing.PrivateKey(), now = Date()
    let c: [String: Any] = ["enabled": true, "minimumVersion": "2.0.0", "recommendedVersion": "2.0.0", "minimumBuild": 0, "recommendedBuild": 0, "minimumOS": 18, "maximumOS": 99, "reason": ""]
    let p: [String: Any] = ["schemaVersion": 1, "bundleID": "io.rookielab.app", "revision": 8, "effectiveAt": now.timeIntervalSince1970 - 1, "expiresAt": now.timeIntervalSince1970 + 10, "channels": ["production": c, "testflight": c]]
    let bytes = try JSONSerialization.data(withJSONObject: p)
    let data = try JSONEncoder().encode(AppUpdatePolicy.Envelope(payload: bytes.base64EncodedString(), signature: key.signature(for: bytes).base64EncodedString()))
    var clock = now
    let service = AppUpdateService(defaults: defaults, verificationKey: key.publicKey.rawRepresentation.base64EncodedString(), clock: { clock }, fetch: { data })
    await service.refresh(force: true, channelOverride: "production")
    XCTAssertEqual(service.decision, .required)
    let offline = AppUpdateService(defaults: defaults, verificationKey: key.publicKey.rawRepresentation.base64EncodedString(), clock: { clock }, fetch: { throw URLError(.notConnectedToInternet) })
    await offline.refresh(force: true, channelOverride: "production")
    XCTAssertEqual(offline.decision, .required)
    clock = now.addingTimeInterval(11)
    await offline.refresh(force: true, channelOverride: "production")
    XCTAssertEqual(offline.decision, .none)
    defaults.removeObject(forKey: "updatePolicyEnvelope.v1")
    await offline.refresh(force: true, channelOverride: "production")
    XCTAssertEqual(offline.decision, .none)
  }
}
