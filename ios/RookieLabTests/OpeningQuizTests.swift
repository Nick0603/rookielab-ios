import XCTest
@testable import RookieLab

@MainActor
final class OpeningQuizTests: XCTestCase {
  func session(_ course: OpeningCourse, _ lesson: OpeningQuizLesson, progress: OpeningCourseProgress? = nil, record: (() -> Void)? = nil) -> OpeningQuizSession {
    OpeningQuizSession(course: course, lesson: lesson, progress: progress ?? OpeningCourseProgress(defaults: nil), record: record ?? {})
  }
  func finish(_ s: OpeningQuizSession, wrong: Bool = false) {
    var limit = 100
    while s.phase != .complete && limit > 0 {
      limit -= 1
      if s.acceptsMove {
        let q = s.state.current
        if wrong {
          let bad = FEN.pieces(q.fen).keys.flatMap { from in FEN.targets(fen: q.fen, from: from).map { from + $0 } }.first { !q.accepted.contains($0) }!
          s.move(bad)
        } else { s.move(q.uci) }
      } else { s.tick() }
    }
    XCTAssertGreaterThan(limit, 0)
    XCTAssertLessThanOrEqual(s.state.answered, s.state.core.count + 2)
  }
  func testEveryRoleHasCompleteBoundedLessonsAndLegalQuestions() {
    XCTAssertEqual(OpeningQuizLesson.all.count, 168)
    for course in OpeningCourse.all {
      let lessons = OpeningQuizLesson.all.filter { $0.courseID == course.id }
      XCTAssertEqual(lessons.map(\.id), course.quizStages.map(\.id))
      for lesson in lessons {
        XCTAssertTrue([6,8].contains(lesson.questions.count))
        XCTAssertGreaterThanOrEqual(Set(lesson.questions.map(\.key)).count, lesson.questions.count == 6 ? 3 : 5)
        for q in lesson.questions {
          XCTAssertEqual(FEN.sideToMove(q.fen), course.side)
          XCTAssertTrue(q.accepted.contains(q.uci))
          XCTAssertNotNil(ChessLine.ply(fen: q.fen, uci: q.uci, index: 0))
        }
        let s = session(course, lesson); finish(s)
        XCTAssertEqual(s.state.answered, lesson.questions.count)
        XCTAssertTrue(s.state.pending.isEmpty)
      }
    }
  }
  func testErrorsAutoCorrectAndReappearWithoutHintOrDuplicateScoring() {
    let c = OpeningCourse.all[0], l = OpeningQuizLesson.all.first { $0.courseID == c.id && $0.id == "intro" }!
    let p = OpeningCourseProgress(defaults: nil)
    p.complete(c.id, stage: "intro") // old learning progress skips demonstration
    var records = 0
    let s = session(c, l, progress: p) { records += 1 }
    XCTAssertEqual(s.phase, .answer)
    let first = s.state.current
    s.move("a2a3")
    XCTAssertEqual(s.phase, .incorrect)
    s.move(first.uci); XCTAssertEqual(s.state.answered, 1)
    XCTAssertTrue(s.arrow)
    s.tick(); XCTAssertEqual(s.phase, .correction); XCTAssertEqual(s.fen, first.after)
    s.tick(); XCTAssertEqual(s.phase, .transition); s.tick(); XCTAssertEqual(s.phase, .answer); XCTAssertFalse(s.arrow)
    finish(s)
    XCTAssertEqual(records, 1); XCTAssertTrue(s.state.pending.isEmpty)
    XCTAssertTrue(p.quizComplete(c, stage: c.stages[0]))
    s.tick(); s.move(first.uci); XCTAssertEqual(records, 1)
    XCTAssertTrue(p.quizUnlocked(c, index: 1))
  }
  func testAllWrongStillTerminatesAndCarriesUnresolvedQuestions() {
    let c = OpeningCourse.all[0], l = OpeningQuizLesson.all.first { $0.courseID == c.id && $0.id == "intro" }!
    let p = OpeningCourseProgress(defaults: nil), s = session(c, l, progress: p)
    finish(s, wrong: true)
    XCTAssertEqual(s.state.independent, 0)
    XCTAssertFalse(p.quizWeak(c.id).isEmpty)
    XCTAssertLessThanOrEqual(s.state.extras, 2)
  }
  func testPauseAndCheckpointKeepFeedbackAndFrozenOrder() throws {
    let c = OpeningCourse.all[0], l = OpeningQuizLesson.all.first { $0.courseID == c.id && $0.id == "intro" }!
    let suite = "quiz-" + UUID().uuidString, defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite) }
    let p = OpeningCourseProgress(defaults: defaults), s = session(c, l, progress: p)
    while s.needsTick { s.tick() }; s.move(s.state.current.uci)
    let before = s.state.answered
    s.pause(); s.tick(); s.move(s.state.current.uci)
    XCTAssertEqual(s.state.answered, before)
    let restored = session(c, l, progress: OpeningCourseProgress(defaults: defaults))
    XCTAssertTrue(restored.paused); XCTAssertEqual(restored.phase, s.phase)
    XCTAssertEqual(restored.state.core.map(\.id), s.state.core.map(\.id))
    restored.pause(); finish(restored)
    XCTAssertEqual(restored.phase, .complete)
  }
  func testOldLearningAndRecallMergeWithoutLosingProgress() {
    let c = OpeningCourse.all[0], p = OpeningCourseProgress(defaults: nil), stage = c.stages[0]
    p.complete(c.id, stage: stage.id)
    XCTAssertFalse(p.quizComplete(c, stage: stage))
    p.complete(c.id, stage: "recall-" + stage.id)
    XCTAssertTrue(p.quizComplete(c, stage: stage))
    XCTAssertTrue(p.entry(c.id).completed.contains(stage.id))
    XCTAssertTrue(p.entry(c.id).completed.contains("recall-" + stage.id))
  }
  func testFinishingResumedRoundPreservesNewerWeakQuestions() {
    let c = OpeningCourse.all[0], lessons = OpeningQuizLesson.all.filter { $0.courseID == c.id }
    let l = lessons.first!, p = OpeningCourseProgress(defaults: nil), s = session(c, l, progress: p)
    let foreign = lessons.last!.questions.first { q in !s.state.core.contains { $0.key == q.key } }!
    p.quizFinish(c.id, lesson: "mixed", weak: [foreign], resolved: [])
    finish(s)
    XCTAssertTrue(p.quizWeak(c.id).contains { $0.key == foreign.key })
  }

  func testAlreadyScheduledWeakContextDoesNotInsertAnExtraCard() {
    let c = OpeningCourse.all[0], l = OpeningQuizLesson.all.first { $0.courseID == c.id && $0.id == "main-part-2" }!
    let p = OpeningCourseProgress(defaults: nil)
    p.quizFinish(c.id, lesson: "intro", weak: [l.questions[4]], resolved: [])
    let s = session(c, l, progress: p); finish(s)
    XCTAssertEqual(s.state.answered, l.questions.count)
    XCTAssertTrue(s.state.pending.isEmpty)
  }

  func testContinuationReplaysPreviousSegmentAndResumesWithoutAnswerLeak() {
    let c = OpeningCourse.all[0], l = OpeningQuizLesson.all.first { $0.courseID == c.id && $0.id == "main-part-2" }!
    let suite = "lead-in-" + UUID().uuidString, defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite) }
    let p = OpeningCourseProgress(defaults: defaults)
    p.complete(c.id, stage: l.stageID)
    let s = session(c, l, progress: p)
    XCTAssertEqual(l.leadIn.first, "rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1")
    XCTAssertEqual(l.leadIn.last, l.questions[0].fen)
    XCTAssertEqual(s.phase, .context); XCTAssertFalse(s.arrow)
    s.move(s.state.current.uci); XCTAssertEqual(s.state.answered, 0)
    s.tick(); let fen = s.fen; s.pause(); s.tick(); XCTAssertEqual(s.fen, fen)
    let resumed = session(c, l, progress: OpeningCourseProgress(defaults: defaults))
    XCTAssertTrue(resumed.paused); XCTAssertEqual(resumed.state.playbackIndex, s.state.playbackIndex)
    resumed.pause(); while resumed.needsTick { resumed.tick() }
    XCTAssertEqual(resumed.fen, l.questions[0].fen); XCTAssertFalse(resumed.state.hint)
    resumed.move(resumed.state.current.uci); XCTAssertEqual(resumed.state.independent, 1)
  }

}
