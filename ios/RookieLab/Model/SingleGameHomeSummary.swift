import Foundation

/// A returning user's next action is derived from actual games and validated analysis caches.
struct SingleGameHomeSummary: Equatable {
  enum Kind: Equatable { case firstUse, checking, newGames, unreviewed, reviewed, empty, unavailable }
  let kind: Kind
  var target: GameSummary?
  var count = 0
  static func make(hasSources: Bool, games: [GameSummary], analyzed: Set<String>, indexReady: Bool,
                   fresh: Set<String>, loading: Bool, failed: Bool) -> Self {
    let finished = games.filter { $0.termination != "unfinished" }.sorted { $0.endedAt > $1.endedAt }
    if !hasSources && games.isEmpty { return Self(kind: .firstUse) }
    if finished.isEmpty {
      if loading { return Self(kind: .checking) }
      return Self(kind: failed ? .unavailable : .empty)
    }
    guard indexReady else { return Self(kind: .checking) }
    let pending = finished.filter { !analyzed.contains($0.id) }
    let discovered = pending.filter { fresh.contains($0.id) }
    if let target = discovered.first { return Self(kind: .newGames, target: target, count: discovered.count) }
    if let target = pending.first { return Self(kind: .unreviewed, target: target, count: pending.count) }
    return Self(kind: .reviewed, target: finished.first)
  }
}
