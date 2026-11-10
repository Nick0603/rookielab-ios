import XCTest
@testable import RookieLab

/// 速度量測（印到檔案）：抓對局、讀存檔、報告規則分析、引擎每個局面的時間（不同設定）
final class PerfTests: XCTestCase {
  @MainActor func testQuickReviewFixedGames() async throws {
    let fixtures = [
      "1. e4 e5 2. Qh5 Nc6 3. Bc4 Nf6 4. Qxf7#",
      "1. e4 e5 2. Nf3 d6 3. d4 Bg4 4. dxe5 Bxf3 5. Qxf3 dxe5 6. Bc4 Nf6 7. Qb3 Qe7 8. Nc3 c6 9. Bg5 b5 10. Nxb5 cxb5 11. Bxb5+ Nbd7 12. O-O-O Rd8 13. Rxd7 Rxd7 14. Rd1 Qe6 15. Bxd7+ Nxd7 16. Qb8+ Nxb8 17. Rd8#"
    ]
    try await StockfishService.shared.start()
    var timings: [String] = []
    for pgn in fixtures {
      let line = try XCTUnwrap(ChessLine(pgn: pgn))
      func game() -> GameSummary {
        GameSummary(id: UUID().uuidString, platform: .chesscom, endedAt: Date(), color: .white,
                    opponent: "Fixture", myRating: nil, opponentRating: nil, result: .win,
                    timeClass: "rapid", timeControl: "600", pgn: pgn, url: nil)
      }
      let fastGame = game()
      let referenceGame = game()
      defer { AnalysisStore.forget(fastGame.id); AnalysisStore.forget(referenceGame.id) }
      let start = ProcessInfo.processInfo.systemUptime
      let fastResult = await AnalysisStore.quickReview(fastGame, line: line, side: .white, startedAt: start) { _, _, _ in }
      let fastSeconds = ProcessInfo.processInfo.systemUptime - start
      let fast = try XCTUnwrap(fastResult)
      XCTAssertTrue(fast.complete)
      XCTAssertEqual((fast.records.last ?? nil)?.cls, .best)
      let referenceStart = ProcessInfo.processInfo.systemUptime
      let referenceResult = await AnalysisStore.analyze(referenceGame, line: line, priority: .interactive)
      let referenceSeconds = ProcessInfo.processInfo.systemUptime - referenceStart
      let reference = try XCTUnwrap(referenceResult)
      func mistakes(_ result: AnalyzedGame) -> [Int] {
        result.records.compactMap { $0 }.filter { $0.mover == .white && $0.cls.isBad }.map(\.ply)
      }
      timings.append("REVIEW_BENCH plies=\(line.plies.count) fast=\(fastSeconds) reference=\(referenceSeconds) fastMistakes=\(mistakes(fast)) referenceMistakes=\(mistakes(reference))")
      let expired = await AnalysisStore.quickReview(game(), line: line, side: .white, startedAt: start - 20) { _, _, _ in }
      XCTAssertFalse(try XCTUnwrap(expired).complete)
    }
    let report = XCTAttachment(string: timings.joined(separator: "\n"))
    report.name = "Review engine timings"
    report.lifetime = .keepAlways
    add(report)
  }

  @MainActor func testMeasure() async throws {
    var out = ""
    func t<T>(_ name: String, _ f: () async throws -> T) async rethrows -> T {
      let s = Date(); let r = try await f(); out += "\(name): \(String(format: "%.2f", Date().timeIntervalSince(s)))s\n"; return r
    }
    let acct = Account(platform: .chesscom, username: "rookielab-io")
    let games = try await t("抓 100 局") { try await GameSources.recentGames(acct, limit: 100) }
    _ = try await t("抓 30 局") { try await GameSources.recentGames(acct, limit: 30) }
    _ = await t("讀 100 個分析存檔") { games.map { AnalysisStore.load($0.id) }.compactMap { $0 }.count }
    _ = await t("GameRow 開局名稱 ×100") { games.map { Openings.family($0.openingRaw) }.count }
    let typed = Array(games.prefix(50))
    _ = await t("報告 quick ×50") { await ReportJS.quick(typed) }
    _ = await t("報告 prescription ×50") { await ReportJS.prescription(typed, rating: 500) }
    // 引擎：同一局前 30 個局面
    let line = try XCTUnwrap(ChessLine(pgn: games[0].pgn))
    let fens = (0..<min(30, line.plies.count)).map { line.fen(at: $0) }
    try? await StockfishService.shared.start()
    for (label, nodes, depth, pv) in [("150k 節點 MultiPV2（現在）", 150_000, Int?.none, 2), ("50k 節點 MultiPV2", 50_000, nil, 2),
                                      ("50k 節點 MultiPV1", 50_000, nil, 1), ("深度 12 MultiPV1（網站）", 0, 12, 1), ("深度 12 MultiPV2", 0, 12, 2)] {
      var bests: [String] = []
      _ = await t("引擎 \(label) ×\(fens.count)") {
        for (i, f) in fens.enumerated() {
          _ = i
          let r = await StockfishService.shared.analyse(fen: f, nodes: nodes, depth: depth, multipv: pv, priority: .interactive)
          bests.append(r.first?.best ?? "-")
        }
      }
      out += "  最佳步：\(bests.prefix(12).joined(separator: " "))\n"
    }
    // 整局：兩輪分析，評級全部出來的時間（第一輪完）與全部算完的時間
    let g = games[1]
    let gl = try XCTUnwrap(ChessLine(pgn: g.pgn))
    AnalysisStore.forget(g.id)
    let s0 = Date()
    var firstPass: Double?
    var stamps: [(Int, Double)] = []
    var lastT = Date()
    let a = await AnalysisStore.analyze(g, line: gl, priority: .interactive) { k, _, _ in
      let now = Date()
      if firstPass == nil { stamps.append((k, now.timeIntervalSince(lastT))) }
      lastT = now
      if k == gl.plies.count, firstPass == nil { firstPass = Date().timeIntervalSince(s0) }
    }
    let slow = stamps.sorted { $0.1 > $1.1 }.prefix(6).map { "#\($0.0) \(String(format: "%.2f", $0.1))s" }
    let sorted = stamps.map(\.1).sorted()
    out += "第一輪每個局面：中位數 \(String(format: "%.3f", sorted[sorted.count / 2]))s，最慢 \(slow.joined(separator: ", "))\n"
    out += "整局 \(gl.plies.count) 手：評級全部出來 \(String(format: "%.1f", firstPass ?? -1))s、全部算完 \(String(format: "%.1f", Date().timeIntervalSince(s0)))s\n"
    let bad = a?.records.compactMap { $0 }.filter(\.cls.isBad).count ?? -1
    out += "  失誤類 \(bad) 個\n"
    out += "cores=\(ProcessInfo.processInfo.activeProcessorCount)\n"
    try? out.write(toFile: NSTemporaryDirectory() + "perf.txt", atomically: true, encoding: .utf8)
  }
}
