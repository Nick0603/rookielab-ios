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

  /// Interactive review spends most of its budget locating turning points, then verifies a few.
  static func quickReview(_ game: GameSummary, line: ChessLine, side: Side, startedAt: TimeInterval,
                          onStep: @MainActor (Int, [[EngineLine]?], [MoveRecord?]) -> Void) async -> AnalyzedGame? {
    if let hit = load(game.id) { return regraded(hit, line: line) }
    let n = line.plies.count
    let scanDeadline = startedAt + 5
    let reviewDeadline = startedAt + 8
    var evals = Array<[EngineLine]?>(repeating: nil, count: n + 1)
    var records = Array<MoveRecord?>(repeating: nil, count: n)
    let nodesPerPosition = min(16_000, max(3_000, 850_000 / max(1, n + 1)))

    for k in 0...n {
      guard !Task.isCancelled else { return nil }
      guard ProcessInfo.processInfo.systemUptime < scanDeadline else { break }
      let mate = k > 0 && line.plies[k - 1].isCheckmate
      let fen = line.fen(at: k)
      let lines = mate ? [] : await StockfishService.shared.analyse(
        fen: fen, nodes: nodesPerPosition, multipv: 1, priority: .interactive, deadline: scanDeadline)
      if !lines.isEmpty || mate || !FEN.hasMoves(fen) { evals[k] = lines }
      if k > 0, let before = evals[k - 1], let after = evals[k], !after.isEmpty || mate {
        records[k - 1] = Grading.record(line.plies[k - 1], before: before, after: after)
      }
      if k % 8 == 0 || k == n { await onStep(k, evals, records) }
    }

    let candidates = records.compactMap { $0 }.filter {
      $0.mover == side && ($0.cls.isBad || $0.cls == .great || $0.cls == .brilliant)
    }.sorted {
      let left = $0.winBefore - $0.winAfter
      let right = $1.winBefore - $1.winAfter
      return left == right ? $0.ply < $1.ply : left > right
    }
    var verified = Set<Int>()
    var refined: [Int: [EngineLine]] = [:]
    for candidate in candidates.prefix(3) {
      guard !Task.isCancelled else { return nil }
      guard ProcessInfo.processInfo.systemUptime < reviewDeadline else { break }
      let k = candidate.ply
      let move = line.plies[k]
      if refined[k] == nil {
        refined[k] = await StockfishService.shared.analyse(
          fen: line.fen(at: k), nodes: 50_000, multipv: 2, priority: .interactive, deadline: reviewDeadline)
      }
      if refined[k + 1] == nil {
        refined[k + 1] = move.isCheckmate ? [] : await StockfishService.shared.analyse(
          fen: line.fen(at: k + 1), nodes: 50_000, multipv: 2, priority: .interactive, deadline: reviewDeadline)
      }
      guard let before = refined[k], let after = refined[k + 1],
            !before.isEmpty, !after.isEmpty || move.isCheckmate,
            let record = Grading.record(move, before: before, after: after) else { continue }
      records[k] = record
      evals[k] = before
      evals[k + 1] = after
      verified.insert(k)
    }
    guard !Task.isCancelled else { return nil }
    for k in records.indices where !verified.contains(k) {
      guard let record = records[k] else { continue }
      if record.cls.isBad || record.cls == .great || record.cls == .brilliant { records[k] = nil }
    }
    let result = AnalyzedGame(gameId: game.id, nodes: nodes, evals: evals, records: records, grade: gradeVersion)
    await onStep(evals.lastIndex { $0 != nil } ?? 0, evals, records)
    save(result)
    return result
  }

  /// 分析一整局（每個局面一次），每算完一個局面就回報；已存過就直接回存檔
  static func analyze(_ game: GameSummary, line: ChessLine, priority: StockfishService.Priority = .background,
                      firstPass: [[EngineLine]?]? = nil, cacheID: String? = nil,
                      onStep: (@MainActor (Int, [[EngineLine]?], [MoveRecord?]) -> Void)? = nil) async -> AnalyzedGame? {
    if let hit = load(cacheID ?? game.id) { return regraded(hit, line: line) }
    let n = line.plies.count
    var evals: [[EngineLine]?] = firstPass ?? Array(repeating: nil, count: n + 1)
    guard evals.count == n + 1 else { return nil }
    var records: [MoveRecord?] = Array(repeating: nil, count: n)
    func grade(_ i: Int) {
      guard i >= 0, i < n, let b = evals[i], let a = evals[i + 1] else { return }
      records[i] = Grading.record(line.plies[i], before: b, after: a)
    }
    // 第一輪：每個局面快速算一次
    for k in 0...n {
      if Task.isCancelled { return nil }
      let over = k > 0 && line.plies[k - 1].isCheckmate
      if firstPass == nil { evals[k] = over ? [] : await StockfishService.shared.analyse(fen: line.fen(at: k), depth: quickDepth, multipv: 1, priority: priority) }
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
    let a = AnalyzedGame(gameId: cacheID ?? game.id, nodes: nodes, evals: evals, records: records, grade: gradeVersion)
    save(a)
    return a
  }
}
