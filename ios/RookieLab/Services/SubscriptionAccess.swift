import Foundation

struct SubscriptionAccessRecord {
  let expiration: Date?
  let revoked: Bool
  /// StoreKit's current entitlements also covers a subscription's billing grace period.
  let current: Bool
}

struct SubscriptionAccess {
  let active: Bool
  let ready: Bool
  let validUntil: Date?

  static func resolve(records: [SubscriptionAccessRecord], cachedUntil: Date?, uncertain: Bool, previousActive: Bool = false, now: Date = Date()) -> Self {
    let valid = records.filter { !$0.revoked && ($0.current || ($0.expiration.map { $0 > now } ?? false)) }
    if !valid.isEmpty { return .init(active: true, ready: true, validUntil: valid.compactMap(\.expiration).max()) }
    if uncertain { return .init(active: previousActive || (cachedUntil.map { $0 > now } ?? false), ready: false, validUntil: cachedUntil.flatMap { $0 > now ? $0 : nil }) }
    // Explicit expired/revoked records override an older cached grant. Unknown verification never enables ads.
    if !records.isEmpty { return .init(active: false, ready: !uncertain, validUntil: nil) }
    if let cachedUntil, cachedUntil > now { return .init(active: true, ready: true, validUntil: cachedUntil) }
    return .init(active: false, ready: !uncertain, validUntil: nil)
  }
}
