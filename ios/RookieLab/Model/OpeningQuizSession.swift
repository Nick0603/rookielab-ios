import Foundation
import Observation

struct OpeningQuizQuestion: Codable, Hashable, Identifiable {
  var id: String
  let key: String
  let fen: String
  let uci: String
  let accepted: [String]
  let after: String
  var demo: Bool
}
struct OpeningQuizLesson: Codable, Hashable, Identifiable {
  let id: String
  let stageID: String
  let courseID: String
  let title: OpeningCourse.TextPair
  let questions: [OpeningQuizQuestion]
  let leadIn: [String]
  static let all: [OpeningQuizLesson] = {
    guard let url = Bundle.main.url(forResource: "opening-quizzes", withExtension: "json"),
      let data = try? Data(contentsOf: url), let lessons = try? JSONDecoder().decode([Self].self, from: data) else { return [] }
    return lessons
  }()
}
struct OpeningQuizPending: Codable { var question: OpeningQuizQuestion; var last: Int }
struct OpeningQuizSnapshot: Codable {
  var version = 1
  let lessonID: String
  var core: [OpeningQuizQuestion]
  var cursor: Int
  var current: OpeningQuizQuestion
  var extra: Bool
  var extras: Int
  var answered: Int
  var independent: Int
  var mistakes: Int
  var phase: OpeningQuizSession.Phase
  var hint: Bool
  var fen: String
  var pending: [OpeningQuizPending]
  var paused: Bool?
  var resolved: [String]?
  var recorded: Bool
  var playback: [String]?
  var playbackIndex: Int?
}

@MainActor @Observable
final class OpeningQuizSession {
  enum Phase: String, Codable { case context, demo, transition, answer, correct, incorrect, correction, assisted, complete }
  let lesson: OpeningQuizLesson
  let course: OpeningCourse
  private(set) var state: OpeningQuizSnapshot
  private(set) var paused = false
  private var revision = 0
  private let progress: OpeningCourseProgress
  private let record: () -> Void

  init(course: OpeningCourse, lesson: OpeningQuizLesson, progress: OpeningCourseProgress? = nil, record: (() -> Void)? = nil) {
    let progress = progress ?? .shared
    self.course = course; self.lesson = lesson; self.progress = progress
    self.record = record ?? { ReviewStore.shared.markPracticed() }
    if let saved = progress.quizSnapshot(course.id, lesson: lesson.id), saved.version == 1,
      saved.core.count == lesson.questions.count, saved.phase != .complete {
      state = saved; paused = saved.paused ?? false
    } else {
      var core = lesson.questions
      let protected = Set(core.prefix(3).map(\.key))
      let weak = progress.quizWeak(course.id)
      let carries = weak.filter { q in !protected.contains(q.key) && !core.contains { $0.key == q.key } }.prefix(2)
      for (i, question) in carries.enumerated() {
        let at = i == 0 ? 3 : 4
        if at < core.count { var q = question; q.id = core[at].id; q.demo = false; core[at] = q }
      }
      let current = core[0]
      let showDemo = current.demo && !progress.isComplete(course, stage: course.stages.first { $0.id == lesson.stageID }!)
      let playback = lesson.leadIn + (showDemo ? [current.after] : [])
      state = OpeningQuizSnapshot(lessonID: lesson.id, core: core, cursor: 0, current: current, extra: false, extras: 0,
        answered: 0, independent: 0, mistakes: 0, phase: playback.count > 1 ? .context : .answer, hint: showDemo,
        fen: playback.first ?? current.fen, pending: weak.map { .init(question: $0, last: -3) }, paused: false, resolved: [], recorded: false, playback: playback, playbackIndex: 0)
    }
  }
  var phase: Phase { state.phase }
  var fen: String { state.fen }
  var acceptsMove: Bool { !paused && phase == .answer }
  var arrow: Bool { phase != .context && (state.hint || phase == .incorrect || phase == .correction) }
  var needsTick: Bool { !paused && [.context, .demo, .transition, .correct, .incorrect, .correction, .assisted].contains(phase) }
  var delay: Int { phase == .context ? 600 : phase == .incorrect ? 650 : phase == .correction || phase == .transition ? 220 : phase == .demo ? 700 : 400 }
  var tickKey: String { "\(revision):\(phase.rawValue):\(state.current.id):\(state.cursor):\(state.answered):\(paused)" }
  var fraction: Double {
    if phase == .complete { return 1 }
    let answeredCurrent = [.correct, .incorrect, .correction, .assisted].contains(phase)
    return min(0.95, Double(state.cursor + (!state.extra && answeredCurrent ? 1 : 0)) / Double(state.core.count) * 0.9)
  }
  func showHint() { guard acceptsMove else { return }; state.hint = true; save() }
  func pause() { paused.toggle(); revision += 1; save() }
  func move(_ uci: String) {
    guard acceptsMove, let ply = ChessLine.ply(fen: state.current.fen, uci: uci, index: 0) else { return }
    state.answered += 1
    if !state.current.accepted.contains(uci) {
      state.mistakes += 1; remember(); state.phase = .incorrect; state.fen = state.current.fen
    } else {
      Sounds.play(for: ply); state.fen = ply.fenAfter
      if state.hint { remember(); state.phase = .assisted }
      else {
        let key = state.current.key
        state.independent += 1; state.pending.removeAll { $0.question.key == key }
        state.resolved = Array(Set((state.resolved ?? []) + [key])); state.phase = .correct
      }
    }
    revision += 1; save()
  }
  private func remember() {
    let key = state.current.key
    state.pending.removeAll { $0.question.key == key }
    state.resolved?.removeAll { $0 == key }
    var q = state.current; q.demo = false
    state.pending.append(.init(question: q, last: state.answered))
  }
  func tick() {
    guard needsTick else { return }
    switch phase {
    case .context:
      let index = (state.playbackIndex ?? 0) + 1
      if let playback = state.playback, index < playback.count {
        state.playbackIndex = index; state.fen = playback[index]
      } else { state.phase = .transition; state.fen = state.current.fen }
    case .transition: state.phase = .answer
    case .demo: state.phase = .transition; state.fen = state.current.fen
    case .incorrect: state.phase = .correction; state.fen = state.current.after
    default: next()
    }
    revision += 1; save()
  }
  private func next() {
    if !state.extra { state.cursor += 1 }
    let upcoming = Array(state.core.dropFirst(state.cursor))
    let due = state.pending.first { p in
      state.answered - p.last >= (upcoming.isEmpty ? 1 : 2) && !upcoming.contains { $0.key == p.question.key }
    }
    var next: OpeningQuizQuestion?
    var extra = false
    if state.extras < 2, let due { next = due.question; extra = true }
    else if let first = upcoming.first { next = first }
    else if state.extras < 2, let pending = state.pending.first {
      next = state.core.first { $0.key != pending.question.key }; extra = true
    }
    guard var next else {
      state.phase = .complete
      if !state.recorded {
        state.recorded = true
        progress.quizFinish(course.id, lesson: lesson.id, weak: state.pending.map(\.question), resolved: state.resolved ?? [])
        record()
      }
      return
    }
    state.extra = extra
    if extra { state.extras += 1 }
    next.demo = false; state.current = next; state.hint = false; state.fen = next.fen; state.phase = .transition
  }
  func save() { state.paused = paused; progress.saveQuiz(course.id, lesson: lesson.id, snapshot: state) }
}
