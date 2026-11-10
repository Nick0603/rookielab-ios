import Foundation
import Observation

/// 單關只建立一次；畫面更新與進度保存不會重新解析或重設棋譜。
@MainActor @Observable
final class OpeningLessonSession {
  enum Phase: String { case demonstration, practice, roundComplete, complete }
  let course: OpeningCourse
  let stage: OpeningCourse.Stage
  let isRecall: Bool
  private let standaloneRecall: Bool
  private(set) var recallCursor = 0
  private(set) var phase: Phase = .demonstration
  private(set) var demoCursor = 0
  private(set) var exercise: OpeningExercise?
  private(set) var round: OpeningRoute
  private(set) var demoPlies: [Ply]
  private(set) var paused = false
  private var targets: [OpeningRoute]
  private var completed: Set<String>
  private var recorded: Set<String>
  private let progress: OpeningCourseProgress
  private let recordPractice: (OpeningRoute, Bool) -> Void
  private let alternatives: [OpeningRoute]
  private let resume: OpeningCourseProgress.Checkpoint?
  private var resumed = false
  private var answersByPosition: [String: Set<String>] = [:]

  init(course: OpeningCourse, stage: OpeningCourse.Stage, progress: OpeningCourseProgress? = nil, recall: Bool = false,
       recordPractice: ((OpeningRoute, Bool) -> Void)? = nil) {
    let progress = progress ?? OpeningCourseProgress.shared
    self.course = course; self.stage = stage; self.progress = progress; self.isRecall = recall || stage.isReview; self.standaloneRecall = recall
    let count = stage.plies
    let offered = !stage.reviewPositions.isEmpty ? stage.reviewPositions.map { course.route(variation: stage.variation, count: $0 + 1) } : stage.mixed ? course.variants.indices.map { course.route(variation: $0, count: count) }.shuffled() : [course.route(variation: stage.variation, count: count)]
    var seen = Set<String>()
    let unique = offered.filter { seen.insert(Self.key($0)).inserted }
    let finished: Set<String> = recall ? [] : progress.entry(course.id).rounds?[stage.id] ?? []
    completed = finished
    recorded = finished
    targets = unique
    let learned = course.variants.indices.filter { index in
      stage.mixed || index == stage.variation || progress.entry(course.id).completed.contains(index == 0 ? "main" : course.variants[index].id)
    }.map { course.route(variation: $0, count: count) }
    alternatives = learned
    let savedResume = recall || progress.entry(course.id).completed.contains(stage.id) ? nil : progress.entry(course.id).practice[stage.id]
    resume = savedResume
    let initial: OpeningRoute
    if let savedResume, !finished.contains(savedResume.moves.joined(separator: " ")), let previous = learned.first(where: { $0.moves == savedResume.moves }) {
      initial = previous
    } else { initial = unique.first(where: { !finished.contains(Self.key($0)) }) ?? unique[0] }
    round = initial
    demoPlies = initial.plies
    self.recordPractice = recordPractice ?? { route, clean in
      if !recall && !stage.isReview {
        let store = OpeningReviewStore.shared
        store.add(route); store.answer(route.id, clean: clean && stage.startPly == 0)
      }
      ReviewStore.shared.markPracticed()
    }
    for ply in unique.flatMap(\.plies) where ply.mover == course.side {
      answersByPosition[Self.positionKey(ply.fenBefore), default: []].insert(ply.uci)
    }
    demoCursor = stage.startPly
    if targets.allSatisfy({ completed.contains(Self.key($0)) }) {
      if !standaloneRecall { progress.complete(course.id, stage: stage.id) }; phase = .complete
    } else if isRecall { beginRecall() }
  }

  private static func positionKey(_ fen: String) -> String { fen.split(separator: " ").prefix(4).joined(separator: " ") }
  private static func key(_ route: OpeningRoute) -> String { route.moves.joined(separator: " ") }
  var fen: String {
    if phase != .demonstration { return exercise?.fen ?? AnalysisModel.standard }
    return demoCursor == 0 ? AnalysisModel.standard : demoPlies[demoCursor - 1].fenAfter
  }
  var demonstrationPly: Ply? { phase == .demonstration && demoCursor > 0 ? demoPlies[demoCursor - 1] : nil }
  var expected: Ply? { phase == .practice ? exercise?.expected : nil }
  var waitingForOpponent: Bool { phase == .practice && expected?.mover != nil && expected?.mover != course.side }
  var acceptsMove: Bool { phase == .practice && expected?.mover == course.side }
  var needsTick: Bool { (phase == .demonstration && !paused) || waitingForOpponent }
  var tickKey: String { "\(phase.rawValue):\(Self.key(round)):\(demoCursor):\(exercise?.cursor ?? 0):\(paused)" }
  var total: Int { isRecall ? 1 : demoPlies.dropFirst(stage.startPly).filter { $0.mover == course.side }.count }
  var completedMoves: Int { isRecall ? ((exercise?.cursor ?? 0) > recallCursor ? 1 : 0) : max(0, (exercise?.completed ?? 0) - demoPlies.prefix(stage.startPly).filter { $0.mover == course.side }.count) }
  var feedback: String? { exercise?.feedback }
  var hint: Bool { exercise?.hint ?? false }

  /// 播放與對手回應由畫面的可取消計時工作驅動，使用者走子不等待引擎。
  func tick() {
    if phase == .demonstration && !paused {
      if demoCursor < demoPlies.count {
        Sounds.play(for: demoPlies[demoCursor]); demoCursor += 1
      } else {
        let checkpoint = !resumed && resume?.moves == round.moves ? resume : nil
        resumed = true
        if exercise == nil { exercise = OpeningExercise(route: round, alternatives: alternatives, at: max(stage.startPly, checkpoint?.cursor ?? stage.startPly), clean: checkpoint?.clean ?? true, automaticOpponent: false) }
        phase = .practice
        checkCompletion()
      }
    } else if waitingForOpponent {
      exercise?.reply(); saveCheckpoint(); checkCompletion()
    }
  }
  func move(_ uci: String) {
    guard acceptsMove else { return }
    exercise?.move(uci); saveCheckpoint(); checkCompletion()
  }
  func showHint() { guard acceptsMove else { return }; exercise?.showHint(); saveCheckpoint() }
  func pause() { guard phase == .demonstration else { return }; paused.toggle() }
  func replay() {
    guard phase == .demonstration else { return }; demoCursor = stage.startPly; paused = false
  }
  private func saveCheckpoint() {
    guard let exercise else { return }
    guard !isRecall else { return }
    progress.practice(course.id, stage: stage.id, route: exercise.route, cursor: exercise.cursor, clean: exercise.clean)
  }
  private func checkCompletion() {
    guard phase == .practice, let exercise, exercise.finished || (isRecall && exercise.cursor > recallCursor) else { return }
    let key = Self.key(isRecall || !stage.mixed ? round : exercise.route)
    if recorded.insert(key).inserted {
      recordPractice(exercise.route, exercise.clean)
      if !standaloneRecall { progress.finishedRound(course.id, stage: stage.id, moves: isRecall ? round.moves : exercise.route.moves) }
    }
    completed.insert(key)
    if targets.allSatisfy({ completed.contains(Self.key($0)) }) {
      if !standaloneRecall { progress.complete(course.id, stage: stage.id) }; phase = .complete
    } else { phase = .roundComplete }
  }
  func replayPractice() {
    guard phase == .practice else { return }
    // 保留這次練習的位置，示範結束後回來繼續；不把看過答案算成獨立回想。
    exercise?.showHint(); saveCheckpoint()
    demoCursor = stage.startPly; paused = false; phase = .demonstration
  }
  /// 明確要求重練時開始新一輪，不沿用已完成的 checkpoint 或輪次。
  func repeatLesson() {
    targets.shuffle()
    completed = []; recorded = []; resumed = true
    round = targets[0]; demoPlies = round.plies; demoCursor = stage.startPly
    exercise = nil; paused = false; phase = .demonstration
    if isRecall { beginRecall() }
  }
  func nextRound() {
    guard phase == .roundComplete, let next = targets.first(where: { !completed.contains(Self.key($0)) }) else { return }
    round = next; demoPlies = next.plies; demoCursor = stage.startPly; exercise = nil; paused = false; phase = .demonstration
    if isRecall { beginRecall() }
  }
  private func beginRecall() {
    if !stage.reviewPositions.isEmpty {
      recallCursor = demoPlies.count - 1
      exercise = OpeningExercise(route: round, at: recallCursor, automaticOpponent: false)
      phase = .practice
      return
    }
    let other = targets.first { $0.moves != round.moves }
    let fork = other.flatMap { other in
      (0..<min(other.moves.count, round.moves.count)).first { other.moves[$0] != round.moves[$0] }
    } ?? 0
    // 分叉是我方選擇時，先在棋盤上走過該選擇與對手回應。
    // 不在完全相同的盤面隨機要求不同答案，讓變化由局面本身辨識。
    let afterContext = demoPlies[safe: fork]?.mover == course.side ? fork + 1 : fork
    recallCursor = demoPlies.indices.first {
      $0 >= afterContext && demoPlies[$0].mover == course.side && answersByPosition[Self.positionKey(demoPlies[$0].fenBefore)]?.count == 1
    }
      ?? demoPlies.indices.last { demoPlies[$0].mover == course.side } ?? 0
    exercise = OpeningExercise(route: round, at: recallCursor, automaticOpponent: false)
    phase = .practice
  }
}
