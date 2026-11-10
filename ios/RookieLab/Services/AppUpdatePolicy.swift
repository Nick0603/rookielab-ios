import CryptoKit
import Foundation

struct AppVersion: Comparable, Equatable {
  let parts: [Int]
  init?(_ value: String) {
    let items = value.split(separator: ".", omittingEmptySubsequences: false)
    guard (1...4).contains(items.count), items.allSatisfy({ !$0.isEmpty && $0.allSatisfy(\.isNumber) && $0.count <= 9 }),
          items.compactMap({ Int($0) }).count == items.count else { return nil }
    parts = items.compactMap { Int($0) } + Array(repeating: 0, count: 4 - items.count)
  }
  static func < (lhs: Self, rhs: Self) -> Bool { lhs.parts.lexicographicallyPrecedes(rhs.parts) }
}

struct AppUpdatePolicy: Decodable {
  struct Channel: Decodable {
    let enabled: Bool
    let minimumVersion: String
    let recommendedVersion: String
    let minimumBuild: Int64
    let recommendedBuild: Int64
    let minimumOS: Int
    let maximumOS: Int
    let reason: String
  }
  let schemaVersion: Int
  let bundleID: String
  let revision: Int
  let effectiveAt: Double
  let expiresAt: Double
  let channels: [String: Channel]
  struct Envelope: Codable { let payload: String; let signature: String }
  enum Decision: Equatable { case none, recommended, required }
  static func verify(_ data: Data, publicKey: String, now: Date, minimumRevision: Int = 0) -> Self? {
    guard data.count < 32_768,
          let envelope = try? JSONDecoder().decode(Envelope.self, from: data),
          let bytes = Data(base64Encoded: envelope.payload), let signature = Data(base64Encoded: envelope.signature),
          let rawKey = Data(base64Encoded: publicKey), let key = try? Curve25519.Signing.PublicKey(rawRepresentation: rawKey),
          key.isValidSignature(signature, for: bytes),
          let policy = try? JSONDecoder().decode(Self.self, from: bytes),
          policy.schemaVersion == 1, policy.bundleID == "io.rookielab.app", policy.revision >= minimumRevision,
          policy.effectiveAt <= now.timeIntervalSince1970, policy.expiresAt > now.timeIntervalSince1970,
          policy.expiresAt > policy.effectiveAt, policy.expiresAt - policy.effectiveAt <= 86_400,
          Set(policy.channels.keys) == ["production", "testflight"],
          policy.channels.values.allSatisfy({ c in
            guard let min = AppVersion(c.minimumVersion), let recommended = AppVersion(c.recommendedVersion) else { return false }
            return min <= recommended && c.minimumBuild >= 0 && c.recommendedBuild >= 0
              && c.minimumOS >= 18 && c.maximumOS >= c.minimumOS && c.reason.count <= 200
          }) else { return nil }
    return policy
  }
  func decision(channel: String, version: String, build: Int64, os: Int, now: Date) -> Decision {
    guard now.timeIntervalSince1970 >= effectiveAt, now.timeIntervalSince1970 < expiresAt,
          let c = channels[channel], c.enabled, (c.minimumOS...c.maximumOS).contains(os),
          let current = AppVersion(version), let min = AppVersion(c.minimumVersion), let recommended = AppVersion(c.recommendedVersion) else { return .none }
    if current < min || (channel == "testflight" && current == min && build < c.minimumBuild) { return .required }
    if current < recommended || (channel == "testflight" && current == recommended && build < c.recommendedBuild) { return .recommended }
    return .none
  }
}
