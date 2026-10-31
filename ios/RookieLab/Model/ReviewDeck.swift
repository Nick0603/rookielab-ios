import Foundation
import Observation

/// 複習卡：自己對局裡走錯的局面，答案是引擎的正解。排程規則跟網站 src/lib/review.ts 一樣（Anki）：
/// 答對間隔 1 天 → 3 天 → 之後乘上難度係數（起始 2.5）；答錯連續答對歸零、係數降 0.2（下限 1.3）、隔天再出；連續答對 3 次算學會
struct ReviewCard: Codable, Identifiable, Hashable {
  enum Kind: String, Codable, CaseIterable {
    case endgame, time, reversal, tactic, other
    var zh: String {
      switch self {
      case .endgame: "殘局失誤"
      case .time: "時間壓力下的失誤"
      case .reversal: "被逆轉的那一步"
      case .tactic: "戰術失誤"
      case .other: "其他關鍵失誤"
      }
    }
    var icon: String {
      switch self {
      case .endgame: "flag.checkered"
      case .time: "timer"
      case .reversal: "arrow.uturn.down"
      case .tactic: "bolt"
      case .other: "exclamationmark.triangle"
      }
    }
  }

  let id: String
  let gameId: String
  let platform: Platform
  let opponent: String
  let date: Date
  let ply: Int
  let moveNumber: Int
  /// 走錯之前的局面（輪到我）
  let fen: String
  /// 我實際走的（SAN）
  let played: String
  /// 正解（UCI）：引擎的最佳步
  let moves: [String]
  /// 也算答對的步（跟最佳步差不多好的）
  let accept: [String]?
  let kinds: [Kind]
  /// 網站解說的標題（漏看威脅、對手有捉雙…）
  let headline: String
  /// 答完給的說明：你走的、該走的各自會怎樣
  var why: [String]? = nil

  var due: Int
  var interval = 0
  var ease = 2.5
  var streak = 0
  var reps = 0
  var lapses = 0
  var mastered = false
  /// 第一次練的那天（每天新題的上限用）
  var firstDay: Int? = nil
  /// 選題規則的版本（2：只收錯失的機會）。舊規則收的、還沒開始練的題，開 App 時清掉
  var v: Int? = nil
  /// 最近一次沒走到（「剛剛沒走到」那一區用）
  var lastMissDay: Int? = nil
  /// 最近一次練的那天（「今天已練」用）
  var lastDay: Int? = nil

  var isNew: Bool { reps == 0 }
}

enum Day {
  /// 本地時區的第幾天（跨日照使用者的時區）
  static func number(_ d: Date = Date()) -> Int {
    Int((d.timeIntervalSince1970 + Double(TimeZone.current.secondsFromGMT(for: d))) / 86_400)
  }
  static func date(_ n: Int) -> Date {
    let t = Double(n) * 86_400
    return Date(timeIntervalSince1970: t - Double(TimeZone.current.secondsFromGMT(for: Date(timeIntervalSince1970: t))))
  }
}

/// 複習卡與每天練習的紀錄（存在手機上）
@MainActor @Observable
final class ReviewStore {
  static let shared = ReviewStore()

  static let graduate = 3
  private(set) var cards: [ReviewCard] = []
  /// 有練習的日子（第幾天 → 做了幾題）
  private(set) var days: [Int: Int] = [:]

  private struct Saved: Codable { var cards: [ReviewCard]; var days: [Int: Int] }

  private static var file: URL {
    FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("review.json")
  }

  private let persist: Bool

  /// persist：false 給測試用，不讀寫手機上的檔案
  init(persist: Bool = true) {
    self.persist = persist
    if persist, let d = try? Data(contentsOf: Self.file), let s = try? JSONDecoder().decode(Saved.self, from: d) {
      // 舊規則（每一步走壞的都收）收進來、還沒練過的題：很多是已經輸定的局面，練起來沒感覺，清掉
      cards = s.cards.filter { $0.v != nil || !$0.isNew }
      days = s.days
      if cards.count != s.cards.count { save() }
    }
  }

  private func save() {
    guard persist else { return }
    try? JSONEncoder().encode(Saved(cards: cards, days: days)).write(to: Self.file, options: .atomic)
  }

  // MARK: 卡片

  /// 加進複習（已經有的不重複加）；回傳新加了幾張
  @discardableResult
  func add(_ new: [ReviewCard]) -> Int {
    let have = Set(cards.map(\.id))
    let fresh = new.filter { !have.contains($0.id) }
    cards.append(contentsOf: fresh)
    if !fresh.isEmpty { save() }
    return fresh.count
  }

  func remove(_ id: String) {
    cards.removeAll { $0.id == id }
    save()
  }

  func has(_ id: String) -> Bool { cards.contains { $0.id == id } }

  /// 每天最多開始幾題新題（跟 Anki 一樣：一次加很多題也不會一天全部壓上來）
  static let newPerDay = 5

  /// 今天還可以開始幾題新題
  var newLeftToday: Int { max(0, Self.newPerDay - cards.filter { $0.firstDay == Day.number() }.count) }

  /// 今天要做的：到期的舊題全部，加上今天的新題額度
  var dueCards: [ReviewCard] {
    let today = Day.number()
    let due = cards.filter { !$0.mastered && $0.due <= today }
    return due.filter { !$0.isNew } + due.filter(\.isNew).prefix(newLeftToday)
  }
  var masteredCount: Int { cards.filter(\.mastered).count }

  /// 今天這一輪：到期的先（舊的在前），每輪最多 size 張
  func session(size: Int = 5, kind: ReviewCard.Kind? = nil) -> [ReviewCard] {
    let pool = dueCards.filter { kind == nil || $0.kinds.contains(kind!) }
    return Array(pool.sorted { ($0.isNew ? 1 : 0, $0.due) < ($1.isNew ? 1 : 0, $1.due) }.prefix(size))
  }

  /// 這題走得多熟：一次走對、有幫忙（提示、中間走錯過）、看了答案
  enum Recall { case clean, helped, shown }

  /// 熟悉度回饋到排程：一次走對照常拉長；有幫忙也算完成，但間隔拉長得慢、難度係數降一點；看了答案明天再來
  func answer(_ id: String, recall: Recall) {
    switch recall {
    case .clean: answer(id, ok: true)
    case .shown: answer(id, ok: false)
    case .helped:
      guard let i = cards.firstIndex(where: { $0.id == id }) else { return }
      var c = cards[i]
      let today = Day.number()
      if c.firstDay == nil { c.firstDay = today }
      c.reps += 1
      c.streak += 1
      c.ease = max(1.3, c.ease - 0.15)
      c.lastDay = today
      c.interval = c.streak == 1 ? 1 : max(c.interval + 1, Int((Double(c.interval) * 1.2).rounded()))
      c.due = today + c.interval
      // 有幫忙的不算學會：要自己走對才移出題庫
      c.mastered = false
      cards[i] = c
      markPracticed()
    }
  }

  /// 答完一張：照 Anki 的規則排下次
  func answer(_ id: String, ok: Bool) {
    guard let i = cards.firstIndex(where: { $0.id == id }) else { return }
    var c = cards[i]
    let today = Day.number()
    if c.firstDay == nil { c.firstDay = today }
    c.lastDay = today
    c.reps += 1
    if ok {
      c.streak += 1
      c.interval = c.streak == 1 ? 1 : c.streak == 2 ? 3 : max(c.interval + 1, Int((Double(c.interval) * c.ease).rounded()))
      c.due = today + c.interval
      c.mastered = c.streak >= Self.graduate
    } else {
      c.lastMissDay = today
      c.lapses += 1
      c.streak = 0
      c.ease = max(1.3, c.ease - 0.2)
      c.interval = 1
      c.due = today + 1
      c.mastered = false
    }
    cards[i] = c
    markPracticed()
  }

  // MARK: 題庫總覽

  /// 剛剛（今天、昨天）沒走到、還沒重新答對的
  var relearning: [ReviewCard] {
    let today = Day.number()
    return cards.filter { !$0.mastered && $0.streak == 0 && ($0.lastMissDay ?? -9) >= today - 1 }.sorted { $0.due < $1.due }
  }
  /// 答對過、等下次複習的
  var waiting: [ReviewCard] {
    let today = Day.number()
    return cards.filter { !$0.mastered && $0.streak > 0 && $0.due > today }.sorted { $0.due < $1.due }
  }
  /// 今天已練（今天做過的題，不管結果）
  var doneToday: [ReviewCard] { let t = Day.number(); return cards.filter { $0.lastDay == t } }
  /// 今天的進度：已練幾題／今天總共幾題（已練＋還沒練的到期題）
  var todayProgress: (done: Int, total: Int) { let d = doneToday.count; return (d, d + dueCards.count) }

  var masteredCards: [ReviewCard] { cards.filter(\.mastered).sorted { $0.date > $1.date } }
  /// 還沒開始練的新題（每天放 newPerDay 題進來）
  var unstarted: [ReviewCard] { cards.filter { $0.isNew && !$0.mastered } }

  // MARK: 每天的紀錄

  /// 做了一題（複習卡、主題題、殘局練習都算）
  func markPracticed(on day: Int = Day.number()) {
    days[day, default: 0] += 1
    save()
  }

  /// 連續幾天有練：今天還沒練不算斷，從昨天往回數
  var streak: Int {
    let today = Day.number()
    var d = days[today] != nil ? today : today - 1
    var n = 0
    while days[d] != nil { n += 1; d -= 1 }
    return n
  }

  var practicedToday: Bool { days[Day.number()] != nil }
  var todayCount: Int { days[Day.number()] ?? 0 }
}
