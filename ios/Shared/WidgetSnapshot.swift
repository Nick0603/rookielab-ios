import Foundation

/// App 跟小工具共用的資料（App Group 裡的 UserDefaults）：App 每次練習、抓到新對局就更新，小工具只讀
struct WidgetSnapshot: Codable {
  static let group = "group.io.rookielab.app"
  static let key = "widgetSnapshot"

  /// 這份資料是哪一天的（跨天了，今天的進度要歸零）
  var day: Int
  var done: Int
  var goal: Int
  var due: Int
  var streak: Int
  /// 最新一局：對手、勝負（win／loss／draw）、復盤過沒
  var latestOpponent: String?
  var latestResult: String?
  var latestReviewed = true

  static func load() -> WidgetSnapshot? {
    guard let d = UserDefaults(suiteName: group)?.data(forKey: key) else { return nil }
    return try? JSONDecoder().decode(WidgetSnapshot.self, from: d)
  }

  func save() {
    guard let d = try? JSONEncoder().encode(self) else { return }
    UserDefaults(suiteName: Self.group)?.set(d, forKey: Self.key)
  }

  /// 跟 App 的 Day.number() 一樣：本地時區從 1970 起算的第幾天
  static func today(_ d: Date = Date()) -> Int {
    Int((d.timeIntervalSince1970 + Double(TimeZone.current.secondsFromGMT(for: d))) / 86_400)
  }

  /// 小工具顯示時：跨天了就當今天還沒練
  func current(at d: Date = Date()) -> WidgetSnapshot {
    guard day != Self.today(d) else { return self }
    var s = self
    s.done = 0
    return s
  }
}
