import Foundation
import Security
import UIKit

/// 伺服器端新棋局推播：開啟新棋局提醒後，把追蹤的棋站帳號與這台裝置的 APNs token 交給 rookielab.io 輪詢。
/// 關閉提醒就刪除伺服器上的登記。帳號名稱只走這個私有通道，不進統計。
@MainActor final class RemotePush {
  static let shared = RemotePush()
  private let defaults = UserDefaults.standard
  private static let endpoint = URL(string: "https://rookielab.io/api/push")!
  private var syncing = false, again = false, againSeen = false

  /// 伺服器已接受目前的登記；此時由伺服器即時推播，本機排程的提醒停用。
  var active: Bool { defaults.bool(forKey: "push.active") && defaults.string(forKey: "push.token") != nil }

  func register() {
    guard NewGameMonitor.shared.enabled, !Self.testing else { return }
    UIApplication.shared.registerForRemoteNotifications()
  }

  func didRegister(_ token: Data) {
    let hex = token.map { String(format: "%02x", $0) }.joined()
    if defaults.string(forKey: "push.token") != hex { defaults.set(hex, forKey: "push.token"); defaults.removeObject(forKey: "push.signature") }
    Task { await sync() }
  }

  func didFail(_ error: Error) {
    AppLog.add("notification", "remote registration failed")
    defaults.set(false, forKey: "push.active")
  }

  /// seen：使用者已回到 App，伺服器端尚未推出的新棋局就不用再提醒。
  func sync(seen: Bool = false) async {
    guard !Self.testing else { return }
    if syncing { again = true; againSeen = againSeen || seen; return }
    syncing = true
    defer { syncing = false }
    var seen = seen
    repeat {
      again = false
      await syncOnce(seen: seen)
      seen = againSeen; againSeen = false
    } while again
  }

  private func syncOnce(seen: Bool) async {
    let monitor = NewGameMonitor.shared
    let token = defaults.string(forKey: "push.token")
    let enabled = monitor.enabled && token != nil
    guard enabled || defaults.bool(forKey: "push.registered") else { return }
    let accounts = AccountStore.all()
      .filter { AccountHistory.verified($0) && !monitor.excluded.contains($0.id) }
      .compactMap { AccountHistory.normalized($0) }.prefix(20)
      .map { ["platform": $0.platform.rawValue, "username": $0.username] }
    let tz = TimeZone.current.identifier
    let signature = enabled ? "\(token ?? "")|\(tz)|\(accounts.map { "\($0["platform"]!):\($0["username"]!)" }.sorted().joined(separator: ","))" : "off"
    if !seen && signature == defaults.string(forKey: "push.signature") { return }
    guard let secret = credential() else { return }
    let revision = max(defaults.integer(forKey: "push.revision") + 1, Int(Date().timeIntervalSince1970 * 1000))
    defaults.set(revision, forKey: "push.revision")
    #if DEBUG || DEVINSTALL
    let env = "sandbox", dev = true
    #else
    let env = "production", dev = false
    #endif
    var body: [String: Any] = ["install": UsagePrivacy.installID, "secret": secret, "revision": revision, "enabled": enabled, "dev": dev]
    if enabled { body.merge(["token": token!, "env": env, "tz": tz, "accounts": Array(accounts), "seen": seen]) { $1 } }
    var request = URLRequest(url: Self.endpoint, timeoutInterval: 20)
    request.httpMethod = "POST"
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.httpBody = try? JSONSerialization.data(withJSONObject: body)
    do {
      let (_, response) = try await URLSession.shared.data(for: request)
      guard (response as? HTTPURLResponse)?.statusCode == 200 else {
        AppLog.add("notification", "remote sync status \((response as? HTTPURLResponse)?.statusCode ?? 0)")
        return
      }
      defaults.set(signature, forKey: "push.signature")
      defaults.set(enabled, forKey: "push.registered")
      defaults.set(enabled, forKey: "push.active")
      await monitor.reconcile()
    } catch {
      AppLog.add("notification", "remote sync offline")
    }
  }

  private static var testing: Bool { ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil }

  private func credential() -> String? {
    let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                               kSecAttrService as String: "io.rookielab.push",
                               kSecAttrAccount as String: UsagePrivacy.installID]
    var read = query; read[kSecReturnData as String] = true
    var found: CFTypeRef?
    if SecItemCopyMatching(read as CFDictionary, &found) == errSecSuccess, let data = found as? Data { return String(data: data, encoding: .utf8) }
    var bytes = [UInt8](repeating: 0, count: 32)
    guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else { return nil }
    let secret = Data(bytes).base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    var add = query; add[kSecValueData as String] = Data(secret.utf8)
    add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
    guard SecItemAdd(add as CFDictionary, nil) == errSecSuccess else { return nil }
    return secret
  }
}

final class PushAppDelegate: NSObject, UIApplicationDelegate {
  func application(_ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
    Task { @MainActor in RemotePush.shared.didRegister(deviceToken) }
  }
  func application(_ application: UIApplication, didFailToRegisterForRemoteNotificationsWithError error: Error) {
    Task { @MainActor in RemotePush.shared.didFail(error) }
  }
}
