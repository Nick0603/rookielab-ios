import SwiftUI
import WidgetKit

/// 主畫面／鎖定畫面小工具：今天的練習進度、連續天數、最新一局。資料由 App 寫進 App Group（WidgetSnapshot）
struct Provider: TimelineProvider {
  func placeholder(in context: Context) -> Entry { Entry(date: Date(), s: .sample) }
  func getSnapshot(in context: Context, completion: @escaping (Entry) -> Void) { completion(Entry(date: Date(), s: WidgetSnapshot.load() ?? .sample)) }
  func getTimeline(in context: Context, completion: @escaping (Timeline<Entry>) -> Void) {
    let now = Date()
    let s = WidgetSnapshot.load() ?? WidgetSnapshot(day: WidgetSnapshot.today(), done: 0, goal: 5, due: 0, streak: 0)
    // 過了午夜進度要歸零：明天 0:01 再畫一次（App 有更新時也會主動叫重畫）
    let tomorrow = Calendar.current.date(byAdding: .minute, value: 1, to: Calendar.current.startOfDay(for: now.addingTimeInterval(86_400)))!
    completion(Timeline(entries: [Entry(date: now, s: s.current(at: now)), Entry(date: tomorrow, s: s.current(at: tomorrow))], policy: .after(tomorrow)))
  }
}

struct Entry: TimelineEntry {
  let date: Date
  let s: WidgetSnapshot
}

extension WidgetSnapshot {
  static let sample = WidgetSnapshot(day: today(), done: 2, goal: 5, due: 3, streak: 4, latestOpponent: "magnus", latestResult: "win", latestReviewed: false)
}

private let orange = Color(red: 0.91, green: 0.443, blue: 0.122)
private let teal = Color(red: 0.122, green: 0.435, blue: 0.471)
private let ink = Color(red: 0.165, green: 0.145, blue: 0.133)
private let paper = Color(red: 1, green: 0.969, blue: 0.937)

struct Ring: View {
  let s: WidgetSnapshot
  var body: some View {
    ZStack {
      Circle().stroke(teal.opacity(0.18), lineWidth: 7)
      Circle().trim(from: 0, to: min(1, Double(s.done) / Double(max(1, s.goal))))
        .stroke(s.done >= s.goal ? teal : orange, style: StrokeStyle(lineWidth: 7, lineCap: .round)).rotationEffect(.degrees(-90))
      VStack(spacing: 0) {
        Text("\(min(s.done, s.goal))").font(.title2.bold().monospacedDigit()).foregroundStyle(ink)
        Text("/\(s.goal)").font(.caption2).foregroundStyle(ink.opacity(0.6))
      }
    }
  }
}

struct WidgetView: View {
  @Environment(\.widgetFamily) private var family
  let entry: Entry
  var s: WidgetSnapshot { entry.s }
  var title: String { s.done >= s.goal ? String(localized: "今天的練習完成了") : String(localized: "今天的練習") }
  var streakText: String { s.streak > 0 ? String(localized: "🔥 連續 \(s.streak) 天") : String(localized: "今天開始連續紀錄") }

  var body: some View {
    switch family {
    case .accessoryCircular:
      Gauge(value: Double(min(s.done, s.goal)), in: 0...Double(max(1, s.goal))) { Text("♟") } currentValueLabel: { Text("\(min(s.done, s.goal))") }
        .gaugeStyle(.accessoryCircularCapacity)
        .widgetURL(URL(string: "rookielab://practice"))
    case .accessoryRectangular:
      VStack(alignment: .leading, spacing: 2) {
        Text("Rookie Lab").font(.caption.bold())
        Text(title + " \(min(s.done, s.goal))/\(s.goal)").font(.caption)
        Text(streakText).font(.caption2)
      }
      .widgetURL(URL(string: "rookielab://practice"))
    case .systemMedium:
      HStack(spacing: 14) {
        Link(destination: URL(string: "rookielab://practice")!) {
          HStack(spacing: 12) {
            Ring(s: s).frame(width: 64, height: 64)
            VStack(alignment: .leading, spacing: 4) {
              Text(title).font(.headline).foregroundStyle(ink)
              Text(streakText).font(.caption).foregroundStyle(orange)
              if s.due > 0 { Text("\(s.due) 題複習到期").font(.caption2).foregroundStyle(ink.opacity(0.6)) }
            }
          }
        }
        if let opp = s.latestOpponent {
          Divider()
          Link(destination: URL(string: "rookielab://latest")!) {
            VStack(alignment: .leading, spacing: 4) {
              Text(s.latestReviewed ? String(localized: "最新一局") : String(localized: "剛下完一局")).font(.caption.bold()).foregroundStyle(teal)
              Text("vs \(opp)").font(.subheadline.bold()).foregroundStyle(ink).lineLimit(1)
              Text(s.latestReviewed ? String(localized: "再看一次") : String(localized: "點這裡復盤")).font(.caption2).foregroundStyle(ink.opacity(0.6))
            }
          }
        }
      }
    default:
      VStack(alignment: .leading, spacing: 6) {
        HStack {
          Ring(s: s).frame(width: 54, height: 54)
          Spacer()
          Image(s.done >= s.goal ? "accent-rook" : "accent-bishop").resizable().scaledToFit().accessibilityHidden(true).frame(width: 40, height: 40)
        }
        Text(title).font(.caption.bold()).foregroundStyle(ink).lineLimit(1)
        Text(streakText).font(.caption2).foregroundStyle(orange).lineLimit(1)
      }
      .widgetURL(URL(string: "rookielab://practice"))
    }
  }
}

struct RookieLabWidget: Widget {
  var body: some WidgetConfiguration {
    StaticConfiguration(kind: "RookieLabPractice", provider: Provider()) { entry in
      WidgetView(entry: entry).containerBackground(paper, for: .widget)
    }
    .configurationDisplayName("今天的練習")
    .description("今天的 5 題進度、連續天數，還有剛下完的那一局")
    .supportedFamilies([.systemSmall, .systemMedium, .accessoryCircular, .accessoryRectangular])
  }
}

@main
struct RookieLabWidgets: WidgetBundle {
  var body: some Widget { RookieLabWidget() }
}
