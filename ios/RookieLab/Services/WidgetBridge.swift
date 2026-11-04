import Foundation
import WidgetKit

/// 把今天的練習進度、連續天數、最新一局寫給小工具，並請系統重畫小工具
@MainActor
enum WidgetBridge {
  static func update(latest: GameSummary? = nil, reviewed: Bool? = nil) {
    let store = ReviewStore.shared
    var s = WidgetSnapshot.load() ?? WidgetSnapshot(day: Day.number(), done: 0, goal: PracticeView.daily, due: 0, streak: 0)
    s.day = Day.number()
    s.done = store.todayCount
    s.goal = PracticeView.daily
    s.due = store.dueCards.count
    s.streak = store.streak
    if let g = latest {
      s.latestOpponent = g.opponent
      s.latestResult = g.result.rawValue
      s.latestReviewed = reviewed ?? AnalysisStore.exists(g.id)
    }
    s.save()
    WidgetCenter.shared.reloadAllTimelines()
  }
}
