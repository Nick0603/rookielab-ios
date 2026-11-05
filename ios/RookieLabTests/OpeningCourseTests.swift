import XCTest
@testable import RookieLab

@MainActor
final class OpeningCourseTests: XCTestCase {
  func testAllCoursesHaveBothRolesLegalLinesAndDifferentVariations() {
    XCTAssertEqual(OpeningCourse.all.count, 6)
    for course in OpeningCourse.all {
      XCTAssertGreaterThanOrEqual(course.variants.count, 2)
      XCTAssertGreaterThan(course.maxTurn, 2)
      for index in course.variants.indices {
        let route = course.route(variation: index, count: course.variants[index].steps.count)
        XCTAssertEqual(route.plies.count, route.moves.count, "\(course.id) illegal line")
        XCTAssertTrue(route.valid)
        XCTAssertTrue(course.variants[index].steps.allSatisfy { !$0.zh.isEmpty && !$0.en.isEmpty })
      }
      let variations = Set(course.variants.map { $0.steps.map(\.uci).joined(separator: " ") })
      XCTAssertEqual(variations.count, course.variants.count)
      XCTAssertTrue(course.stages.allSatisfy { course.minimumTurn($0) <= course.maxTurn })
    }
    XCTAssertEqual(Set(OpeningCourse.all.map(\.side)), [.white, .black])
  }
  func testKnownAlternativeSwitchesActualRouteWithoutMarkingWrong() {
    let course = OpeningCourse.all.first { $0.id == "italian-white" }!
    let routes = course.variants.indices.map { course.route(variation: $0, count: course.maxTurn * 2) }
    let main = routes[0]
    // 執黑角色才可親自選黑方分叉；選出我方回合的已知分叉驗證轉線。
    let alternate = OpeningRoute(account: main.account, name: "other", side: main.side, moves: ["e2e4", "e7e5", "b1c3"])
    let exercise = OpeningExercise(route: main, alternatives: [alternate])
    exercise.move("e2e4"); exercise.move("b1c3")
    XCTAssertEqual(exercise.route.moves, alternate.moves)
    XCTAssertTrue(exercise.clean)
    XCTAssertTrue(exercise.finished)
  }
  func testLessonAndPracticeProgressSurviveReload() {
    let suite = "course-tests-" + UUID().uuidString, defaults: UserDefaults
    defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite) }
    let course = OpeningCourse.all[0], store = OpeningCourseProgress(defaults: defaults)
    XCTAssertFalse(store.unlocked(course, index: 1))
    store.lesson(course.id, stage: "intro", step: 2)
    store.practice(course.id, stage: "intro", route: course.route(variation: 0, count: 6), cursor: 2, clean: false)
    let restored = OpeningCourseProgress(defaults: defaults)
    XCTAssertEqual(restored.entry(course.id).lesson["intro"], 2)
    XCTAssertEqual(restored.entry(course.id).practice["intro"]?.clean, false)
    restored.complete(course.id, stage: "intro")
    XCTAssertTrue(restored.unlocked(course, index: 1))
  }
  func testMigratingSameRoutePreservesLatestRecallAndRemoval() {
    let a = OpeningRoute(account: "local", name: "one", side: .white, moves: ["e2e4", "e7e5"])
    let b = OpeningRoute(account: "chesscom:person", name: "one", side: .white, moves: a.moves)
    var old = OpeningReviewStore.Card(route: a, due: 100); old.updated = Date(timeIntervalSince1970: 10)
    var latest = OpeningReviewStore.Card(route: b, due: 200); latest.updated = Date(timeIntervalSince1970: 20); latest.streak = 2
    let migrated = OpeningReviewStore.migrate([old, latest])
    XCTAssertEqual(migrated.count, 1)
    XCTAssertEqual(migrated[0].due, 200)
    XCTAssertEqual(migrated[0].streak, 2)
    XCTAssertEqual(migrated[0].route.account, OpeningRoute.learner)
    latest.removed = true
    XCTAssertTrue(OpeningReviewStore.migrate([old, latest])[0].removed)
  }
  func testGuestAndPGNImportNeedNoAccount() {
    let previousSource = UserDefaults.standard.object(forKey: "gameSource")
    defer { UserDefaults.standard.set(previousSource, forKey: "gameSource") }
    let app = AppModel(restore: false)
    XCTAssertNil(app.account)
    XCTAssertEqual(app.tab, .openings)
    let pgn = "[White \"A\"]\n[Black \"B\"]\n[Result \"1-0\"]\n\n1. e4 e5 2. Nf3 Nc6 1-0"
    let game = ImportedGames.parse(pgn, side: .white)!
    XCTAssertEqual(game.opponent, "B")
    XCTAssertEqual(game.result, .win)
    XCTAssertNil(ImportedGames.parse("1. e4 e9", side: .white))
    XCTAssertEqual(ImportedGames.parse(pgn, side: .white)?.id, game.id)
  }
  func testLearnerScopePreservesReviewAcrossChessAccounts() {
    let store = OpeningReviewStore(defaults: nil, sync: false, learnerScope: true)
    let route = OpeningCourse.all[0].route(variation: 0, count: 6)
    let old = OpeningRoute(account: "chesscom:old", name: route.name, side: route.side, moves: route.moves)
    XCTAssertTrue(store.add(old, today: 100))
    XCTAssertFalse(store.add(route, today: 100))
    store.answer(old.id, clean: true, today: 100)
    XCTAssertEqual(store.active(account: "lichess:other").first?.due, 103)
    XCTAssertTrue(store.due(account: "local", today: 101).isEmpty)
    store.remove(old.id)
    XCTAssertTrue(store.active(account: "anything").isEmpty)
  }
  func testNMeansCompleteMovePairsAndForkNeedsEnoughDepth() {
    for course in OpeningCourse.all {
      for turn in 1...course.maxTurn {
        let route = course.route(variation: 0, count: turn * 2)
        XCTAssertEqual(route.moves.count, turn * 2)
        XCTAssertEqual(route.plies.filter { $0.mover == course.side }.count, turn)
      }
      XCTAssertGreaterThan(course.minimumTurn(course.stages.last!), 1)
    }
    let unfinished = ImportedGames.parse("1. e4 e5", side: .black)
    XCTAssertEqual(unfinished?.termination, "unfinished", "未結束的棋譜不能當成和棋統計")
  }
  func testMixedRoundsPersistAndDoNotResetRecallWhenContinuing() {
    let suite = "mixed-tests-" + UUID().uuidString
    let defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite) }
    let course = OpeningCourse.all[0], store = OpeningCourseProgress(defaults: defaults)
    let route = course.route(variation: 1, count: course.maxTurn * 2)
    store.finishedRound(course.id, stage: "mixed", moves: route.moves)
    let restored = OpeningCourseProgress(defaults: defaults)
    XCTAssertTrue(restored.entry(course.id).rounds?["mixed"]?.contains(route.moves.joined(separator: " ")) == true)
    restored.complete(course.id, stage: "mixed")
    XCTAssertNil(restored.entry(course.id).rounds?["mixed"])
  }

}
