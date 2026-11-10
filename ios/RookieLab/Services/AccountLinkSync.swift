import Foundation
import Security

/// Separate private channel: names and write credentials never enter analytics/Crashlytics.
actor AccountLinkSync {
  static let shared = AccountLinkSync()
  private let defaults = UserDefaults.standard
  private let pendingKey = "telemetry.accountLink.pending"
  private var sending = false
  private static let endpoint = URL(string: "https://rookielab.io/api/account-links")!

  func syncCurrent() async -> Bool {
    #if targetEnvironment(simulator)
    guard UserDefaults.standard.bool(forKey: "telemetryInSimulator") else { return true }
    #endif
    guard ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil else { return true }
    let allowed = UsagePrivacy.shareAccounts
    // Do not register a profile for people who have never chosen account sharing.
    guard allowed || defaults.bool(forKey: "telemetry.accountLink.everEnabled") else { return true }
    if allowed { defaults.set(true, forKey: "telemetry.accountLink.everEnabled") }
    let revision = max(defaults.integer(forKey: "telemetry.accountLink.revision") + 1, Int(Date().timeIntervalSince1970 * 1000))
    defaults.set(revision, forKey: "telemetry.accountLink.revision")
    let accounts = allowed ? AccountStore.all().compactMap { AccountHistory.normalized($0) }.prefix(20).map { ["platform": $0.platform.rawValue, "username": $0.username] } : []
    #if DEBUG || DEVINSTALL
    let dev = true
    #else
    let dev = false
    #endif
    let body: [String: Any] = ["install": UsagePrivacy.installID, "revision": revision, "dev": dev, "accounts": accounts]
    guard let data = try? JSONSerialization.data(withJSONObject: body) else { return false }
    defaults.set(data, forKey: pendingKey)
    return await drain()
  }
  private func drain() async -> Bool {
    guard !sending else { return false }
    sending = true
    defer { sending = false }
    while let data = defaults.data(forKey: pendingKey) {
      var request = URLRequest(url: Self.endpoint, timeoutInterval: 20)
      guard var body = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
            let token = credential() else { return false }
      body["linkToken"] = token
      request.httpMethod = "POST"; request.httpBody = try? JSONSerialization.data(withJSONObject: body)
      request.setValue("application/json", forHTTPHeaderField: "Content-Type")
      do {
        let (_, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { return false }
        if defaults.data(forKey: pendingKey) == data {
          defaults.removeObject(forKey: pendingKey)
          if !UsagePrivacy.shareAccounts { defaults.set(false, forKey: "telemetry.accountLink.everEnabled") }
        }
      } catch { return false }
    }
    return true
  }
  private func credential() -> String? {
    let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                               kSecAttrService as String: "io.rookielab.account-links",
                               kSecAttrAccount as String: UsagePrivacy.installID]
    var read = query; read[kSecReturnData as String] = true
    var found: CFTypeRef?
    if SecItemCopyMatching(read as CFDictionary, &found) == errSecSuccess, let data = found as? Data { return String(data: data, encoding: .utf8) }
    var bytes = [UInt8](repeating: 0, count: 32)
    guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else { return nil }
    let token = Data(bytes).base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    var add = query; add[kSecValueData as String] = Data(token.utf8)
    add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
    guard SecItemAdd(add as CFDictionary, nil) == errSecSuccess else { return nil }
    return token
  }
}
