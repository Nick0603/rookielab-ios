import Foundation
import SwiftUI
import UserNotifications

/// 黏著度的迴圈（docs/ios-retention-goal.md）：新對局 → 自動分析 → 一件事 → 自動加入複習 → 每日複習 → 回去下棋
@MainActor @Observable
final class AutoAnalyzer {
  static let shared = AutoAnalyzer()

  /// 新對局：最近 3 天內、還沒分析過的，一次最多 3 局
  static let maxGames = 3
  static let recentDays: TimeInterval = 3 * 86_400

  private(set) var running = false
  private(set) var total = 0
  private(set) var done = 0
  /// 這一輪新加進複習的題數
  private(set) var newCards = 0
  /// 這一輪分析完的局（給「一件事」用）
  private(set) var lessons: [Lesson] = []
  private var task: Task<Void, Never>?

  /// 分析過的日子（第幾天 → 幾局）
  private(set) var analyzedDays: [Int: Int] = {
    (UserDefaults.standard.dictionary(forKey: "analyzedDays") as? [String: Int] ?? [:]).reduce(into: [:]) { $0[Int($1.key) ?? 0] = $1.value }
  }()

  var analyzedToday: Int { analyzedDays[Day.number()] ?? 0 }

  static var autoAdd: Bool {
    get { UserDefaults.standard.object(forKey: "autoAddReview") as? Bool ?? true }
    set { UserDefaults.standard.set(newValue, forKey: "autoAddReview") }
  }

  /// 分析完一局（不管是自動、復盤還是報告）：記一筆、把失誤加進複習
  func record(_ d: GameDigest) -> Int {
    analyzedDays[Day.number(), default: 0] += 1
    UserDefaults.standard.set(Dictionary(uniqueKeysWithValues: analyzedDays.map { ("\($0.key)", $0.value) }), forKey: "analyzedDays")
    return Self.autoAdd ? ReviewStore.shared.add(ReviewBuilder.cards(d)) : 0
  }

  func start(_ games: [GameSummary], refresh: @escaping () -> Void) {
    guard !running else { return }
    let now = Date()
    let fresh = games.filter { now.timeIntervalSince($0.endedAt) < Self.recentDays && AnalysisStore.load($0.id) == nil }.prefix(Self.maxGames)
    guard !fresh.isEmpty else { return }
    running = true
    total = fresh.count
    done = 0
    newCards = 0
    lessons = []
    task = Task { [weak self] in
      try? await StockfishService.shared.start()
      for g in fresh {
        guard let self, !Task.isCancelled else { return }
        guard let line = ChessLine(pgn: g.pgn), let a = await AnalysisStore.analyze(g, line: line), let d = GameDigest(game: g, line: line, analysis: a) else {
          self.done += 1
          continue
        }
        self.newCards += self.record(d)
        if let l = Lesson(d) { self.lessons.append(l) }
        self.done += 1
        refresh()
      }
      self?.running = false
      Notifier.reschedule()
    }
  }
}

/// 這局最該記住的一件事：掉最多的那一步（網站的白話解說）；沒有失誤就是這局最好的一步
struct Lesson: Identifiable {
  let game: GameSummary
  let ply: Int
  let good: Bool
  let title: String
  let detail: String
  var id: String { "\(game.id)-\(ply)" }

  @MainActor init?(_ d: GameDigest) {
    let mine = d.analysis.records.compactMap { $0 }.filter { $0.mover == d.game.color }
    let key = { (r: MoveRecord) -> ExplainJS.Explanation? in
      ExplainJS.explain(key: "\(d.game.id)-\(r.ply)", record: r, ply: d.line.plies[r.ply], before: d.analysis.evals[r.ply] ?? nil, after: d.analysis.evals[safe: r.ply + 1] ?? nil)
    }
    game = d.game
    if let worst = mine.filter(\.cls.isBad).max(by: { ($0.winBefore - $0.winAfter) < ($1.winBefore - $1.winAfter) }) {
      let e = key(worst)
      ply = worst.ply
      good = false
      title = "第 \(worst.ply / 2 + 1) 手 \(worst.san)：\(e?.headline ?? worst.cls.zh)"
      detail = e?.plainReasons.first ?? "該走 \(worst.bestSan ?? "—")"
    } else if let best = mine.first(where: { $0.cls == .brilliant || $0.cls == .great }) ?? mine.first {
      let e = key(best)
      ply = best.ply
      good = true
      title = best.cls == .brilliant || best.cls == .great ? "第 \(best.ply / 2 + 1) 手 \(best.san)：\(best.cls.zh)" : "這局沒有明顯的失誤"
      detail = e?.plainReasons.first ?? "每一步都穩穩的，繼續保持"
    } else {
      return nil
    }
  }
}

// MARK: - 通知：一天最多一則，使用者可以在「我的」關掉

enum Notifier {
  static let hourKey = "remindHour"
  static var enabled: Bool {
    get { UserDefaults.standard.bool(forKey: "remindOn") }
    set { UserDefaults.standard.set(newValue, forKey: "remindOn") }
  }
  /// 每天幾點提醒（預設晚上 8 點）
  static var hour: Int {
    get { UserDefaults.standard.object(forKey: hourKey) as? Int ?? 20 }
    set { UserDefaults.standard.set(newValue, forKey: hourKey) }
  }

  static func requestAndEnable() async -> Bool {
    let ok = (try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge])) ?? false
    enabled = ok
    await MainActor.run { reschedule() }
    return ok
  }

  /// 接下來 7 天，每天一則：今天練過就跳過今天；內容寫連續天數與到期題數
  @MainActor static func reschedule() {
    let c = UNUserNotificationCenter.current()
    c.removePendingNotificationRequests(withIdentifiers: (0..<7).map { "daily-\($0)" })
    guard enabled else { return }
    let store = ReviewStore.shared
    let cal = Calendar.current
    for k in 0..<7 {
      guard let day = cal.date(byAdding: .day, value: k, to: Date()),
            var at = cal.date(bySettingHour: hour, minute: 0, second: 0, of: day) else { continue }
      if k == 0 && (store.practicedToday || at < Date()) { continue }
      if at < Date() { at = at.addingTimeInterval(86_400) }
      let content = UNMutableNotificationContent()
      let streak = store.streak + (store.practicedToday ? 0 : 0)
      let due = store.cards.filter { !$0.mastered && $0.due <= Day.number(at) }.count
      if streak > 0 {
        content.title = "連續 \(streak) 天，今天也來幾題"
      } else {
        content.title = "今天練幾題就好"
      }
      content.body = due > 0 ? "有 \(due) 題到期，大約 \(max(1, min(due, PracticeView.daily) / 2)) 分鐘" : "下完棋回來分析，看這局最該記住的一件事"
      content.sound = .default
      let comps = cal.dateComponents([.year, .month, .day, .hour, .minute], from: at)
      c.add(UNNotificationRequest(identifier: "daily-\(k)", content: content, trigger: UNCalendarNotificationTrigger(dateMatching: comps, repeats: false)))
    }
  }
}

// MARK: - 畫面

/// 對局首頁最上面：連續天數、今日目標（複習 5 題＋分析 1 局）、新對局分析的進度
struct TodayCard: View {
  @Environment(AppModel.self) private var app
  @State private var store = ReviewStore.shared
  @State private var auto = AutoAnalyzer.shared
  @State private var lesson: Lesson?

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      HStack(spacing: 14) {
        ring(Double(store.todayCount) / 5, "複習", "\(min(store.todayCount, 5))/5")
        ring(Double(auto.analyzedToday), "分析", "\(min(auto.analyzedToday, 1))/1")
        VStack(alignment: .leading, spacing: 2) {
          HStack(spacing: 4) {
            Image(systemName: "flame.fill").foregroundStyle(store.streak > 0 ? Brand.orange : .gray.opacity(0.5))
            Text("連續 \(store.streak) 天").font(.headline)
          }
          Text(goalText).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
        Spacer(minLength: 0)
      }
      if auto.running {
        HStack(spacing: 8) {
          ProgressView().controlSize(.small)
          Text("分析新對局 \(auto.done)/\(auto.total)…").font(.subheadline)
        }
      } else if !auto.lessons.isEmpty {
        VStack(alignment: .leading, spacing: 6) {
          Text("新對局的一件事").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
          ForEach(auto.lessons) { l in
            Button { lesson = l } label: {
              HStack(alignment: .top, spacing: 8) {
                Image(systemName: l.good ? "star.fill" : "lightbulb.fill").foregroundStyle(l.good ? .green : Brand.orange)
                VStack(alignment: .leading, spacing: 1) {
                  Text("vs \(l.game.opponent)・\(l.title)").font(.subheadline.weight(.medium)).foregroundStyle(Brand.ink).lineLimit(1)
                  Text(l.detail).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                }
              }
            }
            .buttonStyle(.plain)
          }
          if auto.newCards > 0 { Text("已把 \(auto.newCards) 個失誤加進複習").font(.caption).foregroundStyle(.green) }
        }
      }
      let due = store.dueCards.count
      if due > 0 && !(store.todayCount >= 5) {
        Button { app.tab = .practice } label: {
          Label("今天有 \(due) 題到期，去複習", systemImage: "flame.fill").font(.subheadline.weight(.semibold)).frame(maxWidth: .infinity, minHeight: 40)
        }
        .buttonStyle(.borderedProminent).tint(Brand.orange)
      }
    }
    .padding(14)
    .background(Brand.cream, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    .listRowSeparator(.hidden)
    .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 4, trailing: 16))
    .navigationDestination(item: $lesson) { l in ReviewView(game: l.game, startAt: l.ply + 1) }
  }

  private var goalText: String {
    let r = store.todayCount >= 5, a = auto.analyzedToday >= 1
    if r && a { return "今天的目標完成了" }
    if r { return "再分析一局新對局就完成今天的目標" }
    if a { return "再複習 \(5 - store.todayCount) 題就完成今天的目標" }
    return "今日目標：分析 1 局、複習 5 題"
  }

  private func ring(_ v: Double, _ label: String, _ value: String) -> some View {
    VStack(spacing: 3) {
      ZStack {
        Circle().stroke(Color(.secondarySystemFill), lineWidth: 5)
        Circle().trim(from: 0, to: min(max(v, 0), 1)).stroke(v >= 1 ? Color.green : Brand.orange, style: StrokeStyle(lineWidth: 5, lineCap: .round))
          .rotationEffect(.degrees(-90))
          .animation(.easeOut(duration: 0.5), value: v)
        Text(value).font(.caption2.weight(.semibold).monospacedDigit())
      }
      .frame(width: 44, height: 44)
      Text(label).font(.caption2).foregroundStyle(.secondary)
    }
  }
}

extension Lesson: Hashable {
  static func == (a: Lesson, b: Lesson) -> Bool { a.id == b.id }
  func hash(into h: inout Hasher) { h.combine(id) }
}

/// 這週的進步：準確率跟上週比、這週練了幾題、學會幾題
struct WeeklyCard: View {
  @Environment(AppModel.self) private var app
  let store: ReviewStore

  var body: some View {
    let today = Day.number()
    let thisWeek = (0..<7).reduce(0) { $0 + (store.days[today - $1] ?? 0) }
    let lastWeek = (7..<14).reduce(0) { $0 + (store.days[today - $1] ?? 0) }
    let acc = { (from: Int, to: Int) -> Double? in
      let xs = app.games.filter { (from..<to).contains(Day.number($0.endedAt)) }.compactMap { app.accuracy[$0.id] }
      return xs.isEmpty ? nil : xs.reduce(0, +) / Double(xs.count)
    }
    let now = acc(today - 6, today + 1), before = acc(today - 13, today - 6)
    return VStack(alignment: .leading, spacing: 8) {
      Text("這週").font(.headline)
      HStack(spacing: 0) {
        stat("練了", "\(thisWeek) 題", lastWeek > 0 ? diff(thisWeek - lastWeek, unit: "題") : nil)
        stat("準確率", now.map { String(format: "%.0f", $0) } ?? "—", now.flatMap { n in before.map { diff(Int((n - $0).rounded()), unit: "") } })
        stat("學會", "\(store.masteredCount) 題", nil)
      }
      Text("只跟上週的自己比").font(.caption2).foregroundStyle(.secondary)
    }
    .padding(.vertical, 4)
  }

  private func diff(_ d: Int, unit: String) -> String { d == 0 ? "跟上週一樣" : "比上週 \(d > 0 ? "+" : "")\(d)\(unit)" }

  private func stat(_ label: String, _ v: String, _ sub: String?) -> some View {
    VStack(spacing: 2) {
      Text(v).font(.title3.bold().monospacedDigit()).foregroundStyle(Brand.ink)
      Text(label).font(.caption).foregroundStyle(.secondary)
      if let sub { Text(sub).font(.caption2).foregroundStyle(sub.contains("+") ? .green : .secondary) }
    }
    .frame(maxWidth: .infinity)
  }
}

/// 分析完一局跳出來：這局最該記住的一件事
struct LessonSheet: View {
  let lesson: Lesson
  let added: Int
  let go: () -> Void
  let close: () -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      Label(lesson.good ? "這局最好的一步" : "這局最該記住的一件事", systemImage: lesson.good ? "star.fill" : "lightbulb.fill")
        .font(.subheadline.weight(.semibold)).foregroundStyle(lesson.good ? .green : Brand.orange)
      Text(lesson.title).font(.title3.bold()).foregroundStyle(Brand.ink)
      Text(lesson.detail).font(.body).foregroundStyle(Brand.ink.opacity(0.85)).fixedSize(horizontal: false, vertical: true)
      if added > 0 { Label("這局的 \(added) 個失誤已加進複習", systemImage: "checkmark.circle.fill").font(.footnote).foregroundStyle(.green) }
      HStack {
        Button("繼續看整局", action: close).buttonStyle(.bordered)
        Spacer()
        Button(action: go) { Text("看這一步").font(.headline).frame(minWidth: 120, minHeight: 40) }
          .buttonStyle(.borderedProminent).tint(Brand.orange)
      }
    }
    .padding(20)
    .presentationDetents([.height(300)])
  }
}
