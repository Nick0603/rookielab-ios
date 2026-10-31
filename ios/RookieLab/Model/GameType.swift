import Foundation

/// 對局類型 = 時間制 + 具體的時間設定（10 分鐘快棋、3+2 閃電棋），規則與網站 src/lib/timeClass.ts 一致。
/// 不同時間制的分數分開算，報告一次只看一種。
struct GameType: Hashable, Identifiable {
  let key: String
  let games: Int
  var id: String { key }
  var label: String { GameType.label(key) }
  /// 3+0、3+2、10+0 這種短寫
  var short: String? { GameType.short(key) }

  static let defaultKey = "rapid:600+0"
  static let timeClassZh = ["rapid": "快棋", "blitz": "閃電棋", "bullet": "子彈棋", "daily": "每日棋", "classical": "慢棋"]

  static func key(_ g: GameSummary) -> String {
    let tc = g.timeClass
    guard tc != "daily" else { return tc }
    // 兩個來源都已經是「秒數+加秒」（chess.com 180+2；Lichess 由 clock 組成 180+2）
    let parts = g.timeControl.split(separator: "+").compactMap { Double($0) }
    guard let base = parts.first else { return tc }
    return "\(tc):\(Int(base))+\(parts.count > 1 ? Int(parts[1]) : 0)"
  }

  private static func clock(_ key: String) -> (base: Int, inc: Int)? {
    let parts = key.split(separator: ":")
    guard parts.count == 2 else { return nil }
    let c = parts[1].split(separator: "+").compactMap { Int($0) }
    return c.count == 2 ? (c[0], c[1]) : nil
  }

  static func label(_ key: String) -> String {
    let tc = String(key.split(separator: ":").first ?? "")
    let name = timeClassZh[tc] ?? tc
    guard let c = clock(key) else { return name }
    let minutes = Double(c.base) / 60
    let m = minutes == minutes.rounded() ? "\(Int(minutes))" : String(format: "%.1f", minutes)
    if c.inc > 0 { return c.base < 60 ? "\(c.base) 秒+\(c.inc) \(name)" : "\(m)+\(c.inc) \(name)" }
    return c.base < 60 ? "\(c.base) 秒\(name)" : "\(m) 分鐘\(name)"
  }

  static func short(_ key: String) -> String? {
    guard let c = clock(key) else { return nil }
    let minutes = Double(c.base) / 60
    let m = minutes == minutes.rounded() ? "\(Int(minutes))" : String(format: "%.1f", minutes)
    return "\(m)+\(c.inc)"
  }

  /// 依局數排序，預設的 10 分鐘快棋排第一
  static func types(_ games: [GameSummary]) -> [GameType] {
    var n: [String: Int] = [:]
    for g in games { n[key(g), default: 0] += 1 }
    return n.map { GameType(key: $0.key, games: $0.value) }
      .sorted { ($0.key == defaultKey ? 1 : 0, $0.games) > ($1.key == defaultKey ? 1 : 0, $1.games) }
  }

  /// 報告預設看哪一種：10 分鐘快棋至少 20 局、或佔 30% 以上、或本來就最多 → 用它；不然用最多局的那種
  static func pick(_ games: [GameSummary]) -> String? {
    let ts = types(games)
    guard let most = ts.max(by: { $0.games < $1.games }) else { return nil }
    if let d = ts.first(where: { $0.key == defaultKey }),
       d.games >= 20 || Double(d.games) >= Double(games.count) * 0.3 || d.games >= most.games { return d.key }
    return most.key
  }
}

/// 開局名稱的台灣譯名（openings.json 由 scripts/export-ios-openings.ts 從網站的表產生）
enum Openings {
  private static let table: [(String, String)] = {
    guard let url = Bundle.main.url(forResource: "openings", withExtension: "json"),
          let d = try? Data(contentsOf: url), let rows = try? JSONDecoder().decode([[String]].self, from: d) else { return [] }
    return rows.compactMap { $0.count == 2 ? (norm($0[0]), $0[1]) : nil }
  }()
  private static let longestFirst = table.sorted { $0.0.count > $1.0.count }
  private static let shortestFirst = table.sorted { $0.0.count < $1.0.count }

  private static func norm(_ s: String) -> String {
    s.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil)
      .replacingOccurrences(of: "['’]", with: "", options: .regularExpression)
      .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
      .trimmingCharacters(in: .whitespaces)
  }

  static func name(_ raw: String?) -> String {
    guard let raw, !raw.isEmpty else { return "未知開局" }
    let k = norm(raw)
    return longestFirst.first { k.contains($0.0) }?.1 ?? raw
  }

  /// 開局家族（統計分組用）：西西里防禦的各種變化都歸到「西西里防禦」
  static func family(_ raw: String?) -> String {
    guard let raw, !raw.isEmpty else { return "未知開局" }
    let k = norm(raw)
    if let hit = shortestFirst.first(where: { k.contains($0.0) }) {
      return String(hit.1.components(separatedBy: " — ").first ?? hit.1)
    }
    // 沒有譯名：保留原名，去掉後面附的走法（"... 2.Nf3"）與 Variation 之後的細節
    let words = raw.split(separator: " ").prefix { !($0.first?.isNumber ?? false) && $0 != "Variation" }
    return words.prefix(4).joined(separator: " ").replacingOccurrences(of: "Van t ", with: "Van't ")
  }
}
