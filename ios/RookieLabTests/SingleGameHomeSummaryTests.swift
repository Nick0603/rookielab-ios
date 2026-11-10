import XCTest
@testable import RookieLab

final class SingleGameHomeSummaryTests: XCTestCase {
  func game(_ id: String, at time: Double = 1, unfinished: Bool = false) -> GameSummary {
    GameSummary(id: id, platform: .chesscom, endedAt: Date(timeIntervalSince1970: time), color: .white, opponent: "Opponent",
      myRating: nil, opponentRating: nil, result: .win, timeClass: "blitz", timeControl: "180", pgn: "1. e4 e5", url: nil,
      termination: unfinished ? "unfinished" : nil)
  }
  func testFirstUseAndReturningPGNGuestDiffer() {
    XCTAssertEqual(SingleGameHomeSummary.make(hasSources: false, games: [], analyzed: [], indexReady: true, fresh: [], loading: false, failed: false).kind, .firstUse)
    XCTAssertEqual(SingleGameHomeSummary.make(hasSources: false, games: [game("import")], analyzed: [], indexReady: true, fresh: [], loading: false, failed: false).kind, .unreviewed)
  }
  func testNewMeansDetectedAndNotAlreadyAnalyzed() {
    let games = [game("old", at: 1), game("latest", at: 3), game("middle", at: 2)]
    let s = SingleGameHomeSummary.make(hasSources: true, games: games, analyzed: ["latest"], indexReady: true, fresh: ["old", "middle", "latest", "other-source"], loading: false, failed: false)
    XCTAssertEqual(s.kind, .newGames); XCTAssertEqual(s.target?.id, "middle"); XCTAssertEqual(s.count, 2)
    let complete = SingleGameHomeSummary.make(hasSources: true, games: games, analyzed: Set(games.map(\.id)), indexReady: true, fresh: Set(games.map(\.id)), loading: false, failed: false)
    XCTAssertEqual(complete.kind, .reviewed); XCTAssertEqual(complete.target?.id, "latest")
  }
  func testInitialAccountHistoryDoesNotPretendToBeNew() {
    let s = SingleGameHomeSummary.make(hasSources: true, games: [game("b", at: 2), game("a", at: 1)], analyzed: [], indexReady: true, fresh: [], loading: false, failed: false)
    XCTAssertEqual(s.kind, .unreviewed); XCTAssertEqual(s.target?.id, "b")
  }
  func testLoadingEmptyFailureAndCacheReadyAreDistinct() {
    XCTAssertEqual(SingleGameHomeSummary.make(hasSources: true, games: [], analyzed: [], indexReady: false, fresh: [], loading: true, failed: false).kind, .checking)
    XCTAssertEqual(SingleGameHomeSummary.make(hasSources: true, games: [], analyzed: [], indexReady: false, fresh: [], loading: false, failed: true).kind, .unavailable)
    XCTAssertEqual(SingleGameHomeSummary.make(hasSources: true, games: [], analyzed: [], indexReady: true, fresh: [], loading: false, failed: false).kind, .empty)
    XCTAssertEqual(SingleGameHomeSummary.make(hasSources: true, games: [game("cached")], analyzed: [], indexReady: false, fresh: [], loading: false, failed: false).kind, .checking)
    let cached = SingleGameHomeSummary.make(hasSources: true, games: [game("cached")], analyzed: ["cached"], indexReady: true, fresh: [], loading: true, failed: true)
    XCTAssertEqual(cached.kind, .reviewed)
  }
  func testUnfinishedGameIsNeverThePrimaryAnalysisTarget() {
    let s = SingleGameHomeSummary.make(hasSources: true, games: [game("live", at: 3, unfinished: true), game("done", at: 2)], analyzed: [], indexReady: true, fresh: ["live"], loading: false, failed: false)
    XCTAssertEqual(s.kind, .unreviewed); XCTAssertEqual(s.target?.id, "done")
  }
}
