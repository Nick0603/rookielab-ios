import AppIntents
import Foundation
import Observation

/// Siri／捷徑、小工具點進來要做的事：App 打開後由 RootView 接手
@MainActor @Observable
final class Router {
  enum Action: Equatable { case practice, latestGame, newGames }
  static let shared = Router()
  var pending: Action?
}

/// 「開始今天的練習」：打開練習分頁，直接開始今天的 5 題
struct StartPracticeIntent: AppIntent {
  static let title: LocalizedStringResource = "開始今天的練習"
  static let description = IntentDescription("打開 Rookie Lab，直接開始今天的 5 題練習")
  static let openAppWhenRun = true

  @MainActor func perform() async throws -> some IntentResult {
    Router.shared.pending = .practice
    return .result()
  }
}

/// 「復盤我最新一局」：打開最新的一局，從頭快速復盤
struct ReviewLatestGameIntent: AppIntent {
  static let title: LocalizedStringResource = "復盤我最新一局"
  static let description = IntentDescription("打開 Rookie Lab，復盤你剛下完的那一局")
  static let openAppWhenRun = true

  @MainActor func perform() async throws -> some IntentResult {
    Router.shared.pending = .latestGame
    return .result()
  }
}

struct RookieShortcuts: AppShortcutsProvider {
  static var appShortcuts: [AppShortcut] {
    AppShortcut(
      intent: StartPracticeIntent(),
      phrases: ["\(.applicationName) 今天的練習", "Start practice in \(.applicationName)", "Practice chess with \(.applicationName)"],
      shortTitle: "今天的練習", systemImageName: "flame")
    AppShortcut(
      intent: ReviewLatestGameIntent(),
      phrases: ["\(.applicationName) 復盤最新一局", "Review my latest game in \(.applicationName)", "Analyze my last game with \(.applicationName)"],
      shortTitle: "復盤最新一局", systemImageName: "list.bullet.rectangle.portrait")
  }
}
