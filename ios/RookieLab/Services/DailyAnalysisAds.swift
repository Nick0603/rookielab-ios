import Foundation
import CryptoKit

/// Device-local frequency control. Reopening cached results never calls this gate.
@MainActor final class DailyAnalysisAds {
  static let shared = DailyAnalysisAds()
  private struct Window: Codable {
    var games: [String: Date] = [:]
    var reservations: [String: Date] = [:]
  }
  private let defaults: UserDefaults
  private let key = "singleGameAds.rolling24.v2"
  private var window: Window

  init(defaults: UserDefaults = .standard, calendar: Calendar = .current) {
    self.defaults = defaults
    window = defaults.data(forKey: key).flatMap { try? JSONDecoder().decode(Window.self, from: $0) } ?? Window()
  }
  private func prune(_ date: Date) {
    window.games = window.games.filter { date.timeIntervalSince($0.value) < 86400 }
    window.reservations = window.reservations.filter { date.timeIntervalSince($0.value) < 86400 }
  }
  func completed(_ gameID: String, at date: Date = Date()) {
    prune(date)
    if window.games[gameID] == nil { window.games[gameID] = date }
    save()
  }
  /// Every third new game in a rolling 24h window. Failed attempts/no-fill reserve
  /// the threshold too, so retries cannot repeatedly trigger the same placement.
  func reserveThirdGame(_ gameID: String, at date: Date = Date()) -> Bool {
    prune(date)
    let next = window.games.count + 1
    let population = window.games.keys.sorted().joined(separator: "\n")
    let threshold = SHA256.hash(data: Data(population.utf8)).map { String(format: "%02x", $0) }.joined()
    guard window.games[gameID] == nil, next % 3 == 0,
          window.reservations[threshold] == nil,
          window.reservations.count < 3,
          window.reservations.values.allSatisfy({ date.timeIntervalSince($0) >= 600 }) else { save(); return false }
    window.reservations[threshold] = date
    save()
    return true
  }
  private func save() {
    if let data = try? JSONEncoder().encode(window) { defaults.set(data, forKey: key) }
  }
}

/// The adapter must present only an already loaded ad at this natural navigation break.
/// It must return on dismissal/failure and must never schedule a later presentation.
@MainActor protocol SingleGameInterstitialProvider {
  var ready: Bool { get }
  func present() async
}

@MainActor final class SingleGameInterstitial {
  private let provider: (any SingleGameInterstitialProvider)?
  private let frequency: DailyAnalysisAds
  private let entitlement: @MainActor () -> (active: Bool, ready: Bool)
  private var presenting = false
  init(provider: (any SingleGameInterstitialProvider)? = nil,
       frequency: DailyAnalysisAds = .shared,
       entitlement: @escaping @MainActor () -> (active: Bool, ready: Bool) = { (Premium.shared.active, Premium.shared.entitlementReady) }) {
    self.provider = provider; self.frequency = frequency; self.entitlement = entitlement
  }
  func beforeAnalysis(gameID: String, at date: Date = Date()) async {
    let access = entitlement()
    func skip(_ reason: String) { Telemetry.log("ad_skipped", ["ad_format": "interstitial", "placement": "review_entry", "reason": reason]) }
    guard !Task.isCancelled, !presenting else { return }
    guard !access.active else { skip("subscriber"); return }
    guard access.ready else { skip("entitlement_unknown"); return }
    guard let provider else { skip("not_configured"); return }
    guard frequency.reserveThirdGame(gameID, at: date) else { skip("frequency"); return }
    guard provider.ready else { skip("not_loaded"); return }
    Telemetry.log("ad_show_requested", ["ad_format": "interstitial", "placement": "review_entry"])
    presenting = true
    defer { presenting = false }
    await provider.present()
  }
}
