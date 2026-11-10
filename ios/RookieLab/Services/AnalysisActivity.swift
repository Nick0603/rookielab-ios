import Observation

/// Keep update prompts out of an in-progress game analysis.
@MainActor @Observable final class AnalysisActivity {
  static let shared = AnalysisActivity()
  private var count = 0
  private var screens = 0
  var reviewing: Bool { screens > 0 }
  func enterReview() { screens += 1 }
  func leaveReview() { screens = max(0, screens - 1) }
  var running: Bool { count > 0 }
  func begin() { count += 1 }
  func end() { count = max(0, count - 1) }
}
