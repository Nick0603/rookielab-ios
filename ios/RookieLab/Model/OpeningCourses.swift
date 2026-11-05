import Foundation
import Observation

struct OpeningCourse: Decodable, Identifiable {
  struct TextPair: Decodable { let zh: String; let en: String; var text: String { AppLang.isZh ? zh : en } }
  struct Mark: Decodable { let from: String; let to: String; let kind: String }
  struct Step: Decodable { let uci: String; let san: String; let zh: String; let en: String; let facts: TextPair?; let marks: [Mark]?; var text: String { AppLang.isZh ? zh : en } }
  struct Variation: Decodable, Identifiable {
    let id: String, zh: String, en: String
    let steps: [Step]
    var name: String { AppLang.isZh ? zh : en }
  }
  struct Stage: Identifiable {
    let id: String, title: String
    let variation: Int
    let plies: Int
    let mixed: Bool
  }
  let id: String
  let family: TextPair
  let side: Side
  let goal: TextPair
  let variants: [Variation]
  var maxTurn: Int { max(1, (variants.map { $0.steps.count }.min() ?? 2) / 2) }
  var stages: [Stage] {
    guard let main = variants.first else { return [] }
    var result = [Stage(id: "intro", title: String(localized: "起手與構想"), variation: 0, plies: min(6, main.steps.count), mixed: false),
                  Stage(id: "main", title: String(localized: "串起主線"), variation: 0, plies: main.steps.count, mixed: false)]
    result += variants.indices.dropFirst().map { Stage(id: variants[$0].id, title: variants[$0].name, variation: $0, plies: variants[$0].steps.count, mixed: false) }
    result.append(Stage(id: "mixed", title: String(localized: "分辨不同變化"), variation: 0, plies: maxTurn * 2, mixed: true))
    return result
  }
  func minimumTurn(_ stage: Stage) -> Int {
    if stage.id == "intro" || stage.id == "main" { return 1 }
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
    var completed: Set<String> = []
    var lesson: [String: Int] = [:]
    var practice: [String: Checkpoint] = [:]
    var rounds: [String: Set<String>]? = nil
    var turn: Int?
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
  func selectTurn(_ course: String, turn: Int) { entries[course, default: Entry()].turn = turn; save() }
  func unlocked(_ course: OpeningCourse, index: Int) -> Bool {
    index == 0 || course.stages.prefix(index).allSatisfy { entry(course.id).completed.contains($0.id) }
  }
  private func save() {
    guard let data = try? JSONEncoder().encode(entries) else { return }
    defaults?.set(data, forKey: "opening-courses.progress.v1")
  }
}
