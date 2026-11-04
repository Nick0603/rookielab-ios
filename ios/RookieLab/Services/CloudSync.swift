import Foundation

/// iCloud 同步（NSUbiquitousKeyValueStore，不用自己的伺服器）：複習卡與每天的練習紀錄。
/// 換手機、重裝、之後的 iPad 都接得上。兩邊都有資料時合併：同一張卡取練得比較多（reps、lastDay 較新）的那份，每天的題數取大的
@MainActor
enum CloudSync {
  private static let key = "review.v1"
  private static var kv: NSUbiquitousKeyValueStore { .default }
  /// iCloud key-value 一個 key 上限 1MB，留一點空間
  private static let limit = 900_000

  struct Payload: Codable { var cards: [ReviewCard]; var days: [Int: Int] }

  /// App 啟動：拿雲端的跟手機上的合併；之後雲端有變（別的裝置練了）也合併
  static func start(merge: @escaping (Payload) -> Void) {
    NotificationCenter.default.addObserver(forName: NSUbiquitousKeyValueStore.didChangeExternallyNotification, object: kv, queue: .main) { _ in
      MainActor.assumeIsolated { if let p = pull() { merge(p) } }
    }
    kv.synchronize()
    if let p = pull() { merge(p) }
  }

  static func pull() -> Payload? {
    guard let d = kv.data(forKey: key) else { return nil }
    return try? JSONDecoder().decode(Payload.self, from: (try? (d as NSData).decompressed(using: .zlib) as Data) ?? d)
  }

  static func push(cards: [ReviewCard], days: [Int: Int]) {
    guard let raw = try? JSONEncoder().encode(Payload(cards: cards, days: days)),
          let d = try? (raw as NSData).compressed(using: .zlib) as Data, d.count < limit else { return }
    kv.set(d, forKey: key)
  }

  /// 合併兩份：卡片以 id 對齊，練得比較多的那份留下；每天題數取大的
  static func merged(local: Payload, remote: Payload) -> Payload {
    var byId = Dictionary(local.cards.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
    for c in remote.cards {
      if let l = byId[c.id] {
        let newer = (c.reps, c.lastDay ?? 0) > (l.reps, l.lastDay ?? 0)
        if newer { byId[c.id] = c }
      } else {
        byId[c.id] = c
      }
    }
    let days = local.days.merging(remote.days) { max($0, $1) }
    return Payload(cards: Array(byId.values).sorted { $0.date > $1.date }, days: days)
  }
}
