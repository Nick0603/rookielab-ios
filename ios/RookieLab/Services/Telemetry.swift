import Foundation
import UIKit
#if canImport(FirebaseCore)
import FirebaseCore
import FirebaseCrashlytics
#endif

/// 使用統計送到自己的伺服器（rookielab.io/api/events → Cloudflare D1），當機紀錄用 Firebase Crashlytics。
/// 不用 Firebase Analytics：它是閉源套件，App 內建 GPL 的 Stockfish，不能一起發布。
/// Crashlytics 設定檔放 RookieLab/Firebase/：上架版 GoogleService-Info.plist（io.rookielab.app）、測試機 GoogleService-Info-Dev.plist（io.rookielab.app.dev）；沒有就不啟動
enum Telemetry {
  private(set) static var on = false

  static func start() {
    // 模擬器、跑測試時不送（不要把開發中的操作算進真實的使用數據）
    #if targetEnvironment(simulator)
    // 要在模擬器上確認統計有送出：啟動參數加 -telemetryInSimulator YES（標成 dev）
    guard UserDefaults.standard.bool(forKey: "telemetryInSimulator") else { return }
    #endif
    if ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil { return }
    Events.shared.enable()
    log("app_open")
    #if canImport(FirebaseCore)
    let dev = Bundle.main.bundleIdentifier?.hasSuffix(".dev") ?? false
    guard let path = Bundle.main.path(forResource: dev ? "GoogleService-Info-Dev" : "GoogleService-Info", ofType: "plist"),
          let options = FirebaseOptions(contentsOfFile: path) else { return }
    FirebaseApp.configure(options: options)
    on = true
    #endif
  }

  /// 記一個事件（名稱用英文小寫加底線，參數值只放數字或短字串，不放帳號名稱、棋譜）
  static func log(_ name: String, _ params: [String: Any] = [:]) {
    Events.shared.add(name, params)
  }

  /// 送出還沒送的事件（App 進背景時呼叫）
  static func flush() { Events.shared.flush() }

  /// 當機前的足跡（換頁、打開哪個畫面）：跟回饋的診斷紀錄同一份
  static func breadcrumb(_ text: String) {
    #if canImport(FirebaseCore)
    guard on else { return }
    Crashlytics.crashlytics().log(text)
    #endif
  }

  /// 沒有當機但值得知道的錯誤（例如抓對局失敗）
  static func record(_ error: Error, _ context: String) {
    #if canImport(FirebaseCore)
    guard on else { return }
    Crashlytics.crashlytics().record(error: error, userInfo: ["context": context])
    #endif
  }
}

/// 事件先存在手機上（App 關掉也不會掉），滿 20 筆、過 60 秒或進背景時整批送；送失敗下次再送
final class Events: @unchecked Sendable {
  static let shared = Events()
  private static let endpoint = URL(string: "https://rookielab.io/api/events")!
  private static let batch = 50, keep = 500

  struct Event: Codable { let n: String; let p: [String: Value]?; let t: Int64 }
  enum Value: Codable {
    case s(String), n(Double), b(Bool)
    func encode(to e: Encoder) throws {
      var c = e.singleValueContainer()
      switch self { case .s(let v): try c.encode(v); case .n(let v): try c.encode(v); case .b(let v): try c.encode(v) }
    }
    init(from d: Decoder) throws {
      let c = try d.singleValueContainer()
      if let v = try? c.decode(Bool.self) { self = .b(v) } else if let v = try? c.decode(Double.self) { self = .n(v) } else { self = .s(try c.decode(String.self)) }
    }
  }

  private let q = DispatchQueue(label: "io.rookielab.events")
  private var on = false, sending = false, timer = false
  private var pending: [Event] = []
  private let file = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("events.json")

  /// App 第一次打開時隨機產生，只用來把同一支手機的事件串起來（不是裝置識別碼，刪掉 App 就換新的）
  private lazy var install: String = {
    let d = UserDefaults.standard
    if let id = d.string(forKey: "telemetryInstall") { return id }
    let id = UUID().uuidString
    d.set(id, forKey: "telemetryInstall")
    return id
  }()

  func enable() {
    q.async {
      self.on = true
      if let d = try? Data(contentsOf: self.file), let saved = try? JSONDecoder().decode([Event].self, from: d) { self.pending = saved }
      if !self.pending.isEmpty { self.send() }
    }
  }

  func add(_ name: String, _ params: [String: Any]) {
    let p = params.compactMapValues { v -> Value? in
      switch v {
      case let b as Bool: return .b(b)
      case let i as Int: return .n(Double(i))
      case let x as Double: return .n(x)
      case let s as String: return .s(String(s.prefix(64)))
      default: return .s(String(String(describing: v).prefix(64)))
      }
    }
    let e = Event(n: name, p: p.isEmpty ? nil : p, t: Int64(Date().timeIntervalSince1970 * 1000))
    q.async {
      guard self.on else { return }
      self.pending.append(e)
      if self.pending.count > Self.keep { self.pending.removeFirst(self.pending.count - Self.keep) }
      self.save()
      if self.pending.count >= 20 { self.send() } else if !self.timer {
        self.timer = true
        self.q.asyncAfter(deadline: .now() + 60) { self.timer = false; self.send() }
      }
    }
  }

  func flush() { q.async { self.send() } }

  /// 在 q 上呼叫
  private func send() {
    guard on, !sending, !pending.isEmpty else { return }
    sending = true
    let chunk = Array(pending.prefix(Self.batch))
    #if DEBUG
    let dev = true
    #else
    let dev = false
    #endif
    let body: [String: Any] = [
      "install": install,
      "version": Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "",
      "os": "iOS \(UIDevice.current.systemVersion)",
      "locale": Locale.preferredLanguages.first ?? "",
      "dev": dev,
      "events": (try? JSONSerialization.jsonObject(with: JSONEncoder().encode(chunk))) ?? [],
    ]
    var req = URLRequest(url: Self.endpoint)
    req.httpMethod = "POST"
    req.setValue("application/json", forHTTPHeaderField: "content-type")
    req.httpBody = try? JSONSerialization.data(withJSONObject: body)
    req.timeoutInterval = 15
    URLSession.shared.dataTask(with: req) { _, r, _ in
      let code = (r as? HTTPURLResponse)?.statusCode ?? 0
      self.q.async {
        self.sending = false
        // 成功、或資料本身有問題（400/413，重送也一樣）就移掉；網路失敗、429、5xx 留著下次送
        if code == 200 || code == 400 || code == 413 {
          self.pending.removeFirst(min(chunk.count, self.pending.count))
          self.save()
          if !self.pending.isEmpty { self.send() }
        }
      }
    }.resume()
  }

  private func save() {
    try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
    try? JSONEncoder().encode(pending).write(to: file, options: .atomic)
  }
}
