import Foundation
#if canImport(FirebaseCore)
import FirebaseAnalytics
import FirebaseCore
import FirebaseCrashlytics
#endif

/// 使用統計與當機紀錄（Firebase Analytics、Crashlytics）。
/// 設定檔放 RookieLab/Firebase/：上架版 GoogleService-Info.plist（io.rookielab.app）、測試機 GoogleService-Info-Dev.plist（io.rookielab.app.dev）。
/// 沒有對應的設定檔、或還沒加 Firebase 套件（project.yml 的 packages）就整個不啟動，其他功能照常
enum Telemetry {
  private(set) static var on = false

  static func start() {
    #if canImport(FirebaseCore)
    // 模擬器、跑測試時不送（不要把開發中的操作算進真實的使用數據）
    #if targetEnvironment(simulator)
    return
    #endif
    if ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil { return }
    let dev = Bundle.main.bundleIdentifier?.hasSuffix(".dev") ?? false
    guard let path = Bundle.main.path(forResource: dev ? "GoogleService-Info-Dev" : "GoogleService-Info", ofType: "plist"),
          let options = FirebaseOptions(contentsOfFile: path) else { return }
    FirebaseApp.configure(options: options)
    on = true
    #endif
  }

  /// 記一個事件（名稱用英文小寫加底線，參數值只放數字或短字串，不放帳號名稱、棋譜）
  static func log(_ name: String, _ params: [String: Any] = [:]) {
    #if canImport(FirebaseCore)
    guard on else { return }
    Analytics.logEvent(name, parameters: params.isEmpty ? nil : params)
    #endif
  }

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
