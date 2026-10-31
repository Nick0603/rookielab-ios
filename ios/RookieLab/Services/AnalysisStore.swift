import Foundation

/// 一局分析完的結果：每個局面的引擎前兩名＋每一手的評級。存在手機上，報告和復盤共用，不用重算
struct AnalyzedGame: Codable {
  static let version = 1
  var version = AnalyzedGame.version
  let gameId: String
  let nodes: Int
  let evals: [[EngineLine]?]
  var records: [MoveRecord?]
  /// 評級規則的版本：規則改了，用存下來的引擎結果重新評，不用重跑引擎
  var grade: Int? = nil

  var complete: Bool { !evals.contains { $0 == nil } }
}

enum AnalysisStore {
  /// 存檔標記（單局復盤與跨局報告共用同一份）
  static let nodes = 150_000
  /// 兩輪分析：第一輪每個局面深度 12、只算最佳一條（跟網站一樣，快速出評級）；
  /// 第二輪只重算有問題的步與好棋前後的局面（15 萬節點、前兩名，判斷傑出、第二選擇才準）
  static let quickDepth = 12

  private static var dir: URL {
    let d = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("analyses", isDirectory: true)
    try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
    return d
  }

  private static func file(_ id: String) -> URL {
    dir.appendingPathComponent(id.replacingOccurrences(of: "[^A-Za-z0-9_-]", with: "_", options: .regularExpression) + ".json")
  }

  /// 刪掉某一局的存檔（量速度、重新分析用）
  static func forget(_ id: String) { try? FileManager.default.removeItem(at: file(id)) }

  /// 有沒有存過（只看檔案在不在，不讀內容）
  static func exists(_ id: String) -> Bool { FileManager.default.fileExists(atPath: file(id).path) }

  static func load(_ id: String) -> AnalyzedGame? {
    guard let d = try? Data(contentsOf: file(id)), let a = try? JSONDecoder().decode(AnalyzedGame.self, from: d),
          a.version == AnalyzedGame.version, a.nodes == nodes, a.complete else { return nil }
    return a
  }

  /// 評級規則的版本（2：被吃馬上吃回不算棄子、傑出要是唯一好步）
  static let gradeVersion = 2

  /// 舊規則評的存檔：用存下來的引擎結果照現在的規則重評、存回去
  static func regraded(_ a: AnalyzedGame, line: ChessLine) -> AnalyzedGame {
    guard a.grade != gradeVersion, a.evals.count == line.plies.count + 1 else { return a }
    var b = a
    b.records = line.plies.indices.map { k in
      guard let before = a.evals[k], let after = a.evals[k + 1] else { return a.records[safe: k] ?? nil }
      return Grading.record(line.plies[k], before: before, after: after)
    }
    b.grade = gradeVersion
    save(b)
    return b
  }

  static func save(_ a: AnalyzedGame) {
    guard a.complete, let d = try? JSONEncoder().encode(a) else { return }
    try? d.write(to: file(a.gameId), options: .atomic)
  }

  /// 分析一整局（每個局面一次），每算完一個局面就回報；已存過就直接回存檔
  static func analyze(_ game: GameSummary, line: ChessLine, priority: StockfishService.Priority = .background,
                      onStep: (@MainActor (Int, [[EngineLine]?], [MoveRecord?]) -> Void)? = nil) async -> AnalyzedGame? {
    if let hit = load(game.id) { return regraded(hit, line: line) }
    let n = line.plies.count
    var evals: [[EngineLine]?] = Array(repeating: nil, count: n + 1)
    var records: [MoveRecord?] = Array(repeating: nil, count: n)
    func grade(_ i: Int) {
      guard i >= 0, i < n, let b = evals[i], let a = evals[i + 1] else { return }
      records[i] = Grading.record(line.plies[i], before: b, after: a)
    }
    // 第一輪：每個局面快速算一次
    for k in 0...n {
      if Task.isCancelled { return nil }
      let over = k > 0 && line.plies[k - 1].isCheckmate
      evals[k] = over ? [] : await StockfishService.shared.analyse(fen: line.fen(at: k), depth: quickDepth, multipv: 1, priority: priority)
      grade(k - 1)
      if let onStep { let e = evals, r = records; await onStep(k, e, r) }
    }
    // 第二輪：有問題的步、可能的好棋（雙方），前後兩個局面算深一點、算前兩名，再重評附近的步
    let suspects = records.indices.filter { i in
      guard let r = records[i] else { return false }
      return [.brilliant, .great, .inaccuracy, .mistake, .miss, .blunder].contains(r.cls) || r.winBefore - r.winAfter >= 0.03
    }
    var refined = Set<Int>()
    for i in suspects {
      for k in [i, i + 1] where !refined.contains(k) && k <= n {
        if Task.isCancelled { return nil }
        refined.insert(k)
        if k > 0 && line.plies[k - 1].isCheckmate { continue }
        let deep = await StockfishService.shared.analyse(fen: line.fen(at: k), nodes: nodes, priority: priority)
        if !deep.isEmpty { evals[k] = deep }
      }
      grade(i - 1); grade(i); grade(i + 1)
      if let onStep { let e = evals, r = records; await onStep(n, e, r) }
    }
    if Task.isCancelled { return nil }
    let a = AnalyzedGame(gameId: game.id, nodes: nodes, evals: evals, records: records, grade: gradeVersion)
    save(a)
    return a
  }
}
