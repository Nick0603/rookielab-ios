import Foundation

/// App 目前顯示的語言（系統語言對得上 zh-Hant／en／es／pt-BR 就用它，其他一律繁中）
enum AppLang {
  static var code: String {
    let id = Bundle.main.preferredLocalizations.first ?? "zh-Hant"
    if id.hasPrefix("en") { return "en" }
    if id.hasPrefix("es") { return "es" }
    if id.hasPrefix("pt") { return "pt" }
    return "zh"
  }
  static var isZh: Bool { code == "zh" }
  /// 傳給 explain.js／report.js 的語言。JS 端目前只有 zh、en 的文字；es、pt 還沒有時它自己回英文
  static var js: String { code }
  /// JS 實際吐出來的文字語言（Swift 端要認得句型時用）
  static var jsText: String { isZh ? "zh" : "en" }
}
