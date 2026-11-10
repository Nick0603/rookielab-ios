import Foundation
import Observation

struct OpeningCourse: Decodable, Identifiable {
  struct TextPair: Codable, Hashable { let zh: String; let en: String; var text: String { AppLang.isZh ? zh : en } }
  struct Mark: Decodable { let from: String; let to: String; let kind: String }
  struct Step: Decodable { let uci: String; let san: String; let zh: String; let en: String; let facts: TextPair?; let marks: [Mark]?; var text: String { AppLang.isZh ? zh : en } }
  struct Variation: Decodable, Identifiable {
    let id: String, zh: String, en: String
    let steps: [Step]
    var name: String { AppLang.isZh ? zh : en }
  }
  struct Stage: Identifiable, Hashable {
    let id: String, title: String
    let variation: Int
    let plies: Int
    let mixed: Bool
    var startPly: Int = 0
    var reviewPositions: [Int] = []
    var recallOnly: Bool = false
    var isReview: Bool { recallOnly || !reviewPositions.isEmpty }
  }
  let id: String
  let family: TextPair
  let side: Side
  let goal: TextPair
  let variants: [Variation]
  /// 用主線前六個半回合呈現開局的代表局面，封面與實際課程使用同一份棋譜。
  var coverFEN: String { route(variation: 0, count: 6).plies.last?.fenAfter ?? AnalysisModel.standard }
  var maxTurn: Int { max(1, (variants.map { $0.steps.count }.min() ?? 2) / 2) }
  var stages: [Stage] {
    guard let main = variants.first else { return [] }
    var result: [Stage] = []
    for (variation, line) in variants.enumerated() {
      let plies = route(variation: variation, count: line.steps.count).plies
      // 分支從與主線不同的地方開始，不再重複已學過的整段起手。
      let fork = variation == 0 ? 0 : (0..<min(main.steps.count, line.steps.count)).first { main.steps[$0].uci != line.steps[$0].uci } ?? 0
      var start = fork
      var part = 0
      while start < plies.count {
        let owned = plies.indices.filter { $0 >= start && plies[$0].mover == side }
        guard !owned.isEmpty else { break }
        part += 1
        let end = owned.count > 3 ? owned[3] : plies.count
        let last = end == plies.count
        let id = variation == 0 ? (part == 1 ? "intro" : last ? "main" : "main-part-\(part)") : (last ? line.id : "\(line.id)-part-\(part)")
        let title = variation == 0 ? (part == 1 ? String(localized: "起手練習") : String(localized: "主線 · 第 \(part) 小段")) : line.name + " · \(part)"
        result.append(Stage(id: id, title: title, variation: variation, plies: end, mixed: false, startPly: start))
        let learned = plies.indices.filter { $0 >= start && $0 < end && plies[$0].mover == side }
        // 中途位置與段落收尾各一題；先有前文，再從棋盤回想，不先播放答案。
        let questions = Array(Set([learned[learned.count / 2], learned.last!])).sorted()
        result.append(Stage(id: "recall-" + id, title: String(localized: "情境回想 · \(questions.count) 題"), variation: variation, plies: end, mixed: false, startPly: start, reviewPositions: questions))
        start = end
      }
    }
    result.append(Stage(id: "mixed", title: String(localized: "分辨不同變化"), variation: 0, plies: variants.map { $0.steps.count }.max() ?? 0, mixed: true, recallOnly: true))
    return result
  }
  var quizStages: [Stage] { stages.filter { !$0.isReview || $0.mixed } }
  func minimumTurn(_ stage: Stage) -> Int {
    if !stage.mixed { return stage.startPly / 2 + 1 }
    let indices = stage.mixed ? Array(variants.indices.dropFirst()) : [stage.variation]
    return indices.map { index in
      let branch = variants[index].steps.map(\.uci), main = variants[0].steps.map(\.uci)
      let fork = (0..<min(branch.count, main.count)).first { branch[$0] != main[$0] } ?? 0
      return fork / 2 + 1
    }.max() ?? 1
  }
  func route(variation: Int, count: Int) -> OpeningRoute {
    let v = variants[variation]
    return .init(account: OpeningRoute.learner, name: family.text + " · " + v.name, side: side, moves: v.steps.prefix(count).map(\.uci))
  }
  static let all: [OpeningCourse] = {
    guard let url = Bundle.main.url(forResource: "opening-courses", withExtension: "json"), let data = try? Data(contentsOf: url),
          let result = try? JSONDecoder().decode([OpeningCourse].self, from: data) else { return [] }
    return result
  }()
  /// 已整理課程的合法路線，不把理論資料庫缺少的過渡局面誤判為無效。
  static func contains(_ moves: [String]) -> Bool {
    !moves.isEmpty && all.contains { c in c.variants.contains { Array($0.steps.prefix(moves.count).map(\.uci)) == moves } }
  }
}

@MainActor @Observable
final class OpeningCourseProgress {
  struct Checkpoint: Codable { var moves: [String]; var cursor: Int; var clean: Bool }
  struct Entry: Codable {
    var enrolled: Bool? = nil
    var completed: Set<String> = []
    var lesson: [String: Int] = [:]
    var practice: [String: Checkpoint] = [:]
    var rounds: [String: Set<String>]? = nil
    var turn: Int?
    var quizzes: [String: OpeningQuizSnapshot]?
    var quizWeak: [OpeningQuizQuestion]?
  }
  static let shared = OpeningCourseProgress()
  private(set) var entries: [String: Entry] = [:]
  private(set) var recent: String?
  private let defaults: UserDefaults?
  init(defaults: UserDefaults? = .standard) {
    self.defaults = defaults
    if let data = defaults?.data(forKey: "opening-courses.progress.v1"), let saved = try? JSONDecoder().decode([String: Entry].self, from: data) { entries = saved }
    recent = defaults?.string(forKey: "opening-courses.recent")
  }
  func entry(_ course: String) -> Entry { entries[course] ?? Entry() }
  func quizSnapshot(_ course: String, lesson: String) -> OpeningQuizSnapshot? { entry(course).quizzes?[lesson] }
  func quizWeak(_ course: String) -> [OpeningQuizQuestion] { entry(course).quizWeak ?? [] }
  func saveQuiz(_ course: String, lesson: String, snapshot: OpeningQuizSnapshot) {
    var entry = entry(course); var quizzes = entry.quizzes ?? [:]; quizzes[lesson] = snapshot
    entry.quizzes = quizzes; entries[course] = entry; save()
  }
  func quizFinish(_ course: String, lesson: String, weak: [OpeningQuizQuestion], resolved: [String]) {
    var combined = quizWeak(course).filter { !resolved.contains($0.key) }
    for q in weak { combined.removeAll { $0.key == q.key }; combined.append(q) }
    entries[course, default: Entry()].quizWeak = combined
    complete(course, stage: lesson)
    if lesson != "mixed" { complete(course, stage: "recall-" + lesson) }
  }
  func quizComplete(_ course: OpeningCourse, stage: OpeningCourse.Stage) -> Bool {
    isComplete(course, stage: stage) && (stage.mixed || entry(course.id).completed.contains("recall-" + stage.id))
  }
  func quizUnlocked(_ course: OpeningCourse, index: Int) -> Bool {
    course.quizStages.prefix(index).allSatisfy { quizComplete(course, stage: $0) }
  }
  func quizCompletedStages(_ course: OpeningCourse) -> Int { course.quizStages.filter { quizComplete(course, stage: $0) }.count }
  func isComplete(_ course: OpeningCourse, stage: OpeningCourse.Stage) -> Bool {
    let completed = entry(course.id).completed
    return completed.contains(stage.id) || legacyCovered(course, stage: stage, completed: completed)
  }
  func completedStages(_ course: OpeningCourse) -> Int {
    course.stages.filter { isComplete(course, stage: $0) }.count
  }
  func enrolled(_ course: String) -> Bool {
    guard let entry = entries[course] else { return false }
    return entry.enrolled == true || !entry.completed.isEmpty || !entry.lesson.isEmpty || !entry.practice.isEmpty
  }
  func enroll(_ course: String) { entries[course, default: Entry()].enrolled = true; visit(course); save() }
  func visit(_ course: String) { recent = course; defaults?.set(course, forKey: "opening-courses.recent") }
  func lesson(_ course: String, stage: String, step: Int) { entries[course, default: Entry()].lesson[stage] = step; save() }
  func practice(_ course: String, stage: String, route: OpeningRoute, cursor: Int, clean: Bool) {
    entries[course, default: Entry()].practice[stage] = .init(moves: route.moves, cursor: cursor, clean: clean); save()
  }
  func finishedRound(_ course: String, stage: String, moves: [String]) {
    var entry = entry(course)
    var rounds = entry.rounds ?? [:]; rounds[stage, default: []].insert(moves.joined(separator: " "))
    entry.rounds = rounds; entries[course] = entry; save()
  }
  func complete(_ course: String, stage: String) {
    entries[course, default: Entry()].completed.insert(stage)
    entries[course]?.practice.removeValue(forKey: stage)
    entries[course]?.rounds?.removeValue(forKey: stage); save()
  }
  private func legacyCovered(_ course: OpeningCourse, stage: OpeningCourse.Stage, completed: Set<String>) -> Bool {
    guard !stage.isReview else { return false }
    return completed.contains(stage.variation == 0 ? "main" : course.variants[stage.variation].id)
  }
  func selectTurn(_ course: String, turn: Int) { entries[course, default: Entry()].turn = turn; save() }
  func unlocked(_ course: OpeningCourse, index: Int) -> Bool {
    let completed = entry(course.id).completed
    return index == 0 || course.stages.prefix(index).allSatisfy { stage in
      completed.contains(stage.id) || legacyCovered(course, stage: stage, completed: completed)
    }
  }
  private func save() {
    guard let data = try? JSONEncoder().encode(entries) else { return }
    defaults?.set(data, forKey: "opening-courses.progress.v1")
  }
}
