import Foundation
import Observation
import StoreKit

@MainActor @Observable final class AppUpdateService {
  static let shared = AppUpdateService()
  static let publicKey = "Iyrv2lkVb2+oDsVFJ/eddFgnxNsBlL5sL2Gm3Ix1mUs="
  private let verificationKey: String
  private let defaults: UserDefaults
  private let clock: () -> Date
  private let fetch: () async throws -> Data
  private var lastCheck: Date?
  private var checking = false
  private var policy: AppUpdatePolicy?
  private var expiryTask: Task<Void, Never>?
  private(set) var channel: String?
  private(set) var decision = AppUpdatePolicy.Decision.none
  private(set) var status = ""
  private(set) var busy = false
  var version: String { Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0" }
  var build: Int64 { Int64(Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "0") ?? 0 }
  var reason: String { channel.flatMap { policy?.channels[$0]?.reason } ?? "" }
  var minimum: String { channel.flatMap { policy?.channels[$0]?.minimumVersion } ?? "" }
  var updateURL: URL {
    URL(string: channel == "testflight" ? "https://testflight.apple.com/join/ghWhPtRH" : "https://apps.apple.com/app/id6829168144")!
  }
  var shouldRecommend: Bool {
    decision == .recommended && clock().timeIntervalSince1970 >= defaults.double(forKey: "updateRemindAfter.\(target)")
  }
  private var target: String { "\(channel ?? "unknown").\(policy?.channels[channel ?? ""]?.recommendedVersion ?? "").\(policy?.channels[channel ?? ""]?.recommendedBuild ?? 0)" }
  init(defaults: UserDefaults = .standard, verificationKey: String? = nil, clock: @escaping () -> Date = Date.init,
       fetch: @escaping () async throws -> Data = {
         var request = URLRequest(url: URL(string: "https://rookielab.io/app-config/ios-update-policy.json")!)
         request.timeoutInterval = 5; request.cachePolicy = .reloadIgnoringLocalCacheData
         let (data, response) = try await URLSession.shared.data(for: request)
         guard let http = response as? HTTPURLResponse, http.statusCode == 200,
               http.url?.scheme == "https", http.url?.host == "rookielab.io" else { throw URLError(.badServerResponse) }
         return data
       }) {
    self.verificationKey = verificationKey ?? Self.publicKey
    self.defaults = defaults; self.clock = clock; self.fetch = fetch
  }
  func deferRecommendation() {
    defaults.set(clock().addingTimeInterval(7 * 86_400).timeIntervalSince1970, forKey: "updateRemindAfter.\(target)")
    decision = .none
  }
  func refresh(force: Bool = false, channelOverride: String? = nil) async {
    #if DEBUG
    if let i = ProcessInfo.processInfo.arguments.firstIndex(of: "-updateDemo"),
       let mode = ProcessInfo.processInfo.arguments[safe: i + 1] {
      channel = "testflight"
      let c = AppUpdatePolicy.Channel(enabled: true, minimumVersion: mode == "required" ? "999.0.0" : "1.0.0", recommendedVersion: "999.0.0", minimumBuild: 0, recommendedBuild: 0, minimumOS: 18, maximumOS: 99, reason: "")
      policy = AppUpdatePolicy(schemaVersion: 1, bundleID: "io.rookielab.app", revision: 1, effectiveAt: clock().timeIntervalSince1970 - 1, expiresAt: clock().timeIntervalSince1970 + 600, channels: ["testflight": c])
      apply(now: clock()); return
    }
    #endif
    guard !checking else { return }
    checking = true; busy = true
    defer { checking = false; busy = false }
    if let override = channelOverride { channel = override }
    else {
      #if DEBUG
      channel = "development"
      #else
      if case let .verified(transaction) = try? await AppTransaction.shared {
        channel = transaction.environment == .production ? "production" : transaction.environment == .sandbox ? "testflight" : nil
      }
      #endif
    }
    guard channel == "production" || channel == "testflight" else { decision = .none; status = String(localized: "開發版本，不套用更新門檻"); return }
    let now = clock(), revision = defaults.integer(forKey: "updatePolicyRevision.v1")
    // Revalidate cached signature and expiry even when network checks are throttled.
    policy = defaults.data(forKey: "updatePolicyEnvelope.v1").flatMap { AppUpdatePolicy.verify($0, publicKey: verificationKey, now: now, minimumRevision: revision) }
    apply(now: now)
    if !force, let lastCheck, now.timeIntervalSince(lastCheck) < 3600 { return }
    lastCheck = now
    do {
      let data = try await fetch()
      guard let received = AppUpdatePolicy.verify(data, publicKey: verificationKey, now: clock(), minimumRevision: revision) else { throw URLError(.cannotParseResponse) }
      defaults.set(data, forKey: "updatePolicyEnvelope.v1"); defaults.set(received.revision, forKey: "updatePolicyRevision.v1")
      policy = received; status = String(localized: "已檢查更新")
    } catch { status = String(localized: "暫時無法檢查更新，請稍後重試。") }
    apply(now: clock())
  }
  private func apply(now: Date) {
    decision = policy?.decision(channel: channel ?? "", version: version, build: build, os: ProcessInfo.processInfo.operatingSystemVersion.majorVersion, now: now) ?? .none
    expiryTask?.cancel()
    if let expires = policy?.expiresAt, expires > now.timeIntervalSince1970 {
      expiryTask = Task { [weak self] in
        try? await Task.sleep(nanoseconds: UInt64((expires - now.timeIntervalSince1970) * 1_000_000_000))
        guard !Task.isCancelled else { return }
        self?.decision = .none; self?.policy = nil
      }
    }
  }
}
