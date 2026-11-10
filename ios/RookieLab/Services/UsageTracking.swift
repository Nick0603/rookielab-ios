import Foundation
import SwiftUI
import Darwin

/// Account names have a separate, opt-in first-party channel. They never belong in event parameters.
enum UsagePrivacy {
  private static let installLock = NSLock()
  static let usageKey = "telemetry.usage.enabled"
  static let accountKey = "telemetry.accountLink.enabled"
  static var enabled: Bool { UserDefaults.standard.object(forKey: usageKey) as? Bool ?? true }
  static var shareAccounts: Bool { enabled && UserDefaults.standard.bool(forKey: accountKey) }
  static var installID: String {
    installLock.lock(); defer { installLock.unlock() }
    if let id = UserDefaults.standard.string(forKey: "telemetryInstall") { return id }
    let id = UUID().uuidString
    UserDefaults.standard.set(id, forKey: "telemetryInstall")
    return id
  }
}

enum UsageEventPolicy {
  // Avoid double-counting Firebase's automatic ad/session events.
  static func firebaseName(_ name: String) -> String { name == "screen_view" ? name : "rl_" + name.prefix(37) }

  static func parameters(_ values: [String: Any]) -> [String: Any] {
    let forbidden = ["username", "account", "email", "password", "token", "pgn", "fen", "opponent", "url"]
    var out: [String: Any] = [:]
    for key in values.keys.sorted() where out.count < 9 {
      guard key.range(of: "^[a-z][a-z0-9_]{0,39}$", options: .regularExpression) != nil,
            !forbidden.contains(where: { key.lowercased().contains($0) }), let value = values[key] else { continue }
      if let text = value as? String {
        guard !text.contains("://"), !text.contains("@") else { continue }
        out[key] = String(text.prefix(64))
      } else if let number = value as? NSNumber, number.doubleValue.isFinite { out[key] = value }
    }
    return out
  }
  static var deviceModel: String {
    var info = utsname(); uname(&info)
    return withUnsafePointer(to: &info.machine) { ptr in
      ptr.withMemoryRebound(to: CChar.self, capacity: 256) { String(cString: $0) }
    }
  }
}

@MainActor final class UsageSession {
  static let shared = UsageSession()
  private var started: TimeInterval?
  func change(active: Bool) {
    if active {
      guard started == nil, UsagePrivacy.enabled else { return }
      started = ProcessInfo.processInfo.systemUptime
      Telemetry.log("session_start", ["device_model": UsageEventPolicy.deviceModel,
                                     "app_build": Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "",
                                     "thermal_state": ProcessInfo.processInfo.thermalState.rawValue,
                                     "low_power": ProcessInfo.processInfo.isLowPowerModeEnabled])
    } else if let began = started {
      started = nil
      Telemetry.log("session_end", ["duration_ms": Int(max(0, ProcessInfo.processInfo.systemUptime - began) * 1000)])
      Telemetry.flush()
    }
  }
}

private struct ScreenTracking: ViewModifier {
  let name: String
  @Environment(\.scenePhase) private var phase
  @State private var since: TimeInterval?
  @State private var visible = false
  func body(content: Content) -> some View {
    content.onAppear { visible = true; enter() }
      .onDisappear { visible = false; leave() }
      .onChange(of: phase) { _, state in
        if state == .active && visible { enter() } else { leave() }
      }
  }
  private func enter() {
    guard since == nil, UsagePrivacy.enabled else { return }
    since = ProcessInfo.processInfo.systemUptime
    Telemetry.log("screen_view", ["screen_name": name, "screen_class": name])
  }
  private func leave() {
    guard let began = since else { return }
    since = nil
    Telemetry.log("screen_engagement", ["screen_name": name, "duration_ms": Int(max(0, ProcessInfo.processInfo.systemUptime - began) * 1000)])
  }
}
extension View {
  func trackedScreen(_ name: String) -> some View { modifier(ScreenTracking(name: name)) }
}

struct UsagePrivacySettings: View {
  @AppStorage(UsagePrivacy.usageKey) private var enabled = true
  @AppStorage(UsagePrivacy.accountKey) private var accounts = false
  @State private var result = ""
  var body: some View {
    Form {
      Section {
        Toggle("使用統計與診斷", isOn: $enabled)
        Text("記錄本 App 的頁面、停留時間、分析與廣告互動，以及手機機型、系統與 App 版本，協助改善功能與穩定度。")
          .font(.footnote).foregroundStyle(.secondary)
      }
      Section {
        Toggle("分享我輸入的棋站帳號", isOn: $accounts).disabled(!enabled)
        Text("開啟後，你在此裝置連接的 Chess.com／Lichess 帳號會與使用紀錄關聯，傳至 Rookie Lab 自有資料庫，供功能使用分析與支援。不傳給 Firebase Analytics 或廣告平台，也不代表已驗證棋站所有權。關閉會要求刪除伺服器上的帳號關聯。")
          .font(.footnote).foregroundStyle(.secondary)
        if !result.isEmpty { Text(result).font(.footnote) }
      }
      Section {
        Link("隱私政策", destination: URL(string: "https://rookielab.io\(AppLang.isZh ? "" : "/" + AppLang.code)/privacy/")!)
        Text("統計使用隨機安裝識別碼，不讀取其他 App 的活動、訊息或手機內容。")
          .font(.footnote).foregroundStyle(.secondary)
      }
    }
    .navigationTitle("使用統計與隱私")
    .trackedScreen("usage_privacy")
    .onChange(of: enabled) { _, value in
      if !value { accounts = false }
      UsageSession.shared.change(active: false)
      Telemetry.updateCollection()
      if value { UsageSession.shared.change(active: true) }
      synchronize()
    }
    .onChange(of: accounts) { _, _ in synchronize() }
  }
  private func synchronize() {
    Telemetry.log("account_link_setting", ["enabled": UsagePrivacy.shareAccounts])
    result = String(localized: "同步中…")
    Task { result = await AccountLinkSync.shared.syncCurrent() ? String(localized: "設定已同步") : String(localized: "尚未同步，連線恢復後會重試") }
  }
}
