import XCTest
@testable import RookieLab

@MainActor
final class OpeningLessonSessionTests: XCTestCase {
  private func demo(_ session: OpeningLessonSession) {
    for _ in 0..<(session.demoPlies.count + 1) { session.tick() }
    XCTAssertEqual(session.phase, .practice)
  }
  private func finish(_ session: OpeningLessonSession) {
    var limit = 100
    while session.phase == .practice && limit > 0 {
      limit -= 1
      if session.waitingForOpponent { session.tick() }
      else if let next = session.expected { session.move(next.uci) }
      else { XCTFail("Practice has no continuation"); return }
    }
    XCTAssertGreaterThan(limit, 0)
  }
  func testDemoAutomaticallyTransitionsThenFirstMoveAndOpponentReplyContinue() {
    for course in OpeningCourse.all {
      let progress = OpeningCourseProgress(defaults: nil)
      var records = 0
      let session = OpeningLessonSession(course: course, stage: course.stages[0], progress: progress) { _, _ in records += 1 }
      XCTAssertEqual(session.phase, .demonstration)
      XCTAssertFalse(session.acceptsMove)
      demo(session)
      if session.waitingForOpponent { session.tick() }
      let before = session.fen, expected = session.expected!
      let state = session.exercise
      let start = Date()
      session.move(expected.uci)
      XCTAssertLessThan(Date().timeIntervalSince(start), 0.5, "單次走子不得重建或等待引擎")
      XCTAssertNotEqual(session.fen, before)
      XCTAssertTrue(session.exercise === state, "走子後保留同一個執行狀態，不因保存進度而重建")
      finish(session)
      XCTAssertEqual(session.phase, .complete)
      XCTAssertEqual(records, 1)
      XCTAssertTrue(progress.entry(course.id).completed.contains("intro"))
      session.move(expected.uci); session.tick()
      XCTAssertEqual(records, 1, "結束後不重複計題")
    }
  }
  func testMixedRecallUsesLearnedPositionsAndAllVariations() {
    let course = OpeningCourse.all[0], stage = course.stages.last!
    var recorded: [OpeningRoute] = []
    let session = OpeningLessonSession(course: course, stage: stage, progress: OpeningCourseProgress(defaults: nil)) { route, _ in recorded.append(route) }
    var rounds = 0
    while session.phase != .complete && rounds < 10 {
      XCTAssertEqual(session.phase, .practice)
      finish(session); rounds += 1
      if session.phase == .roundComplete { session.nextRound() }
    }
    XCTAssertEqual(session.phase, .complete)
    XCTAssertEqual(recorded.count, course.variants.count)
    XCTAssertEqual(Set(recorded.map(\.moves)).count, recorded.count)
  }
  func testPauseDoesNotEnterPracticeAndHintDoesNotCountAsClean() {
    let course = OpeningCourse.all[0]
    var clean: Bool?
    let session = OpeningLessonSession(course: course, stage: course.stages[0], progress: OpeningCourseProgress(defaults: nil)) { _, result in clean = result }
    session.pause(); session.tick()
    XCTAssertEqual(session.demoCursor, 0)
    session.pause(); demo(session)
    session.showHint(); finish(session)
    XCTAssertEqual(clean, false)
  }
  func testCheckpointResumesAfterDemonstrationWithoutRestartingFirstMove() {
    let course = OpeningCourse.all[0], progress = OpeningCourseProgress(defaults: nil)
    let first = OpeningLessonSession(course: course, stage: course.stages[0], progress: progress) { _, _ in }
    demo(first); first.move(first.expected!.uci); first.tick()
    let fen = first.fen
    let resumed = OpeningLessonSession(course: course, stage: course.stages[0], progress: progress) { _, _ in }
    XCTAssertEqual(resumed.phase, .demonstration)
    demo(resumed)
    XCTAssertEqual(resumed.fen, fen)
    finish(resumed)
    XCTAssertEqual(resumed.phase, .complete)
  }
  func testEnrollmentAndExistingLearningProgressAreRecognized() {
    let progress = OpeningCourseProgress(defaults: nil)
    XCTAssertFalse(progress.enrolled("italian-white"))
    progress.enroll("italian-white")
    XCTAssertTrue(progress.enrolled("italian-white"))
    progress.lesson("london-white", stage: "intro", step: 2)
    XCTAssertTrue(progress.enrolled("london-white"), "升級保留已開始的課程")
  }
  func testCompletedCheckpointNeverLeavesPracticeWithoutLegalNextStep() {
    let course = OpeningCourse.all[0], stage = course.stages[0], progress = OpeningCourseProgress(defaults: nil)
    let route = course.route(variation: 0, count: min(stage.plies, course.maxTurn * 2))
    progress.practice(course.id, stage: stage.id, route: route, cursor: route.moves.count, clean: true)
    var records = 0
    let session = OpeningLessonSession(course: course, stage: stage, progress: progress) { _, _ in records += 1 }
    for _ in 0...route.moves.count { session.tick() }
    XCTAssertEqual(session.phase, .complete)
    XCTAssertEqual(records, 1)
  }
  func testRewatchKeepsPracticePositionAndRepeatStartsFreshAfterCompletion() {
    let course = OpeningCourse.all[0]
    var records = 0
    let session = OpeningLessonSession(course: course, stage: course.stages[0], progress: OpeningCourseProgress(defaults: nil)) { _, _ in records += 1 }
    demo(session); session.move(session.expected!.uci); session.tick()
    let fen = session.fen
    session.replayPractice(); XCTAssertEqual(session.phase, .demonstration)
    demo(session); XCTAssertEqual(session.fen, fen); XCTAssertFalse(session.exercise!.clean)
    finish(session); XCTAssertEqual(records, 1)
    session.repeatLesson(); XCTAssertEqual(session.phase, .demonstration)
    demo(session); XCTAssertEqual(session.completedMoves, 0)
    finish(session); XCTAssertEqual(records, 2)
  }
  func testCoversAndProgressUseRealCourseData() {
    let progress = OpeningCourseProgress(defaults: nil)
    for course in OpeningCourse.all {
      XCTAssertNotEqual(course.coverFEN, AnalysisModel.standard)
      XCTAssertEqual(course.coverFEN, course.route(variation: 0, count: 6).plies.last?.fenAfter)
      XCTAssertFalse(FEN.pieces(course.coverFEN).isEmpty)
      XCTAssertEqual(progress.completedStages(course), 0)
      progress.complete(course.id, stage: course.stages[0].id)
      progress.complete(course.id, stage: "obsolete-stage")
      XCTAssertEqual(progress.completedStages(course), 1)
    }
  }

  func testVariationRecallPresentsEveryBranchAndRequiresOneCorrectMoveWithoutUnlockingLessons() {
    for course in OpeningCourse.all {
      let progress = OpeningCourseProgress(defaults: nil)
      var records = 0
      let session = OpeningLessonSession(course: course, stage: course.stages.last!, progress: progress, recall: true) { _, _ in records += 1 }
      var routes = Set<[String]>()
      var answersByPosition: [String: Set<String>] = [:]
      for _ in course.variants.indices {
        XCTAssertEqual(session.phase, .practice)
        XCTAssertTrue(session.acceptsMove)
        XCTAssertEqual(session.expected?.mover, course.side)
        XCTAssertEqual(session.total, 1)
        answersByPosition[session.fen.split(separator: " ").prefix(4).joined(separator: " "), default: []].insert(session.expected!.uci)
        let cursor = session.exercise!.cursor
        session.move("a1a8")
        XCTAssertEqual(session.exercise!.cursor, cursor)
        routes.insert(session.round.moves)
        session.move(session.expected!.uci)
        XCTAssertNotEqual(session.phase, .practice)
        XCTAssertEqual(session.completedMoves, 1)
        if session.phase == .roundComplete { session.nextRound() }
      }
      XCTAssertEqual(session.phase, .complete)
      XCTAssertTrue(answersByPosition.values.allSatisfy { $0.count == 1 }, "\(course.id)：不能在同一盤面隨機要求兩個不同的分支答案：\(answersByPosition)")
      XCTAssertEqual(routes.count, course.variants.count)
      XCTAssertEqual(records, course.variants.count)
      XCTAssertTrue(progress.entry(course.id).completed.isEmpty, "快練不得跳過基礎關卡")
      session.repeatLesson()
      XCTAssertEqual(session.phase, .practice)
      XCTAssertEqual(session.completedMoves, 0)
    }
  }

  func testLessonsDoNotTruncateLongerVariationsToShortestBranch() {
    for course in OpeningCourse.all {
      for stage in course.stages where !stage.mixed && !stage.isReview {
        let session = OpeningLessonSession(course: course, stage: stage, progress: OpeningCourseProgress(defaults: nil)) { _, _ in }
        XCTAssertEqual(session.demoPlies.count, stage.plies)
        demo(session); finish(session)
        XCTAssertEqual(session.phase, .complete)
      }
    }
  }

  func testEveryShortSectionHasAtMostThreeNewMovesAndImmediateRecall() {
    for course in OpeningCourse.all {
      for (index, stage) in course.stages.enumerated() where !stage.mixed && !stage.isReview {
        let session = OpeningLessonSession(course: course, stage: stage, progress: OpeningCourseProgress(defaults: nil)) { _, _ in }
        XCTAssertLessThanOrEqual(session.total, 3)
        XCTAssertGreaterThan(session.total, 0)
        XCTAssertEqual(session.demoCursor, stage.startPly)
        let review = course.stages[index + 1]
        XCTAssertTrue(review.isReview)
        let progress = OpeningCourseProgress(defaults: nil)
        XCTAssertFalse(progress.unlocked(course, index: index + 2 < course.stages.count ? index + 2 : index + 1))
        let recall = OpeningLessonSession(course: course, stage: review, progress: progress) { _, _ in }
        for _ in review.reviewPositions {
          XCTAssertEqual(recall.phase, .practice)
          XCTAssertTrue(recall.acceptsMove)
          XCTAssertGreaterThanOrEqual(recall.recallCursor, stage.startPly)
          XCTAssertLessThan(recall.recallCursor, stage.plies)
          recall.move(recall.expected!.uci)
          if recall.phase == .roundComplete { recall.nextRound() }
        }
        XCTAssertEqual(recall.phase, .complete)
        XCTAssertTrue(progress.entry(course.id).completed.contains(review.id))
      }
    }
  }
  func testOldMainProgressCoversNewShortSectionsButStillOffersNewRecall() {
    let course = OpeningCourse.all[0], progress = OpeningCourseProgress(defaults: nil)
    progress.complete(course.id, stage: "main")
    for stage in course.stages where stage.variation == 0 && !stage.mixed {
      XCTAssertEqual(progress.isComplete(course, stage: stage), !stage.isReview)
    }
  }

  func testLegacyLongLessonCheckpointCannotRestartBeforeNewShortSection() {
    let course = OpeningCourse.all[0], stage = course.stages.first { $0.id == "main" }!
    let progress = OpeningCourseProgress(defaults: nil)
    let route = course.route(variation: 0, count: stage.plies)
    progress.practice(course.id, stage: stage.id, route: route, cursor: 2, clean: true)
    let session = OpeningLessonSession(course: course, stage: stage, progress: progress) { _, _ in }
    demo(session)
    XCTAssertEqual(session.exercise?.cursor, stage.startPly)
    XCTAssertEqual(session.completedMoves, 0)
    finish(session); XCTAssertEqual(session.phase, .complete)
  }

}
