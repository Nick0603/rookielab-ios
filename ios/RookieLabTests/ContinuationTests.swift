import XCTest
@testable import RookieLab

/// 延伸棋局：引擎的線要夠長；開局局面要有資料庫裡真人的接法（要連網路）
final class ContinuationTests: XCTestCase {
  func testLinesForOpeningMistake() async throws {
    let line = try XCTUnwrap(ChessLine(pgn: "1. e4 e5 2. Nf3 f6 *"))
    let p = line.plies[3]
    let before = await StockfishService.shared.analyse(fen: p.fenBefore)
    let after = await StockfishService.shared.analyse(fen: p.fenAfter)
    let r = try XCTUnwrap(Grading.record(p, before: before, after: after))
    let opts = await Continuations.build(r, ply: p, before: before, after: after)
    var report = "\(r.san) \(r.cls)：\(Explain.text(r, ply: p, before: before, after: after) ?? "-")\n"
    for o in opts { report += "[\(o.source)] \(o.title) \(o.evalText ?? "?")：\(o.plies.map(\.san).joined(separator: " "))\n" }
    try? report.write(toFile: ProcessInfo.processInfo.environment["LINES_REPORT"] ?? NSTemporaryDirectory() + "lines.txt", atomically: true, encoding: .utf8)
    XCTAssertTrue(opts.contains { if case .database = $0.source { true } else { false } }, "應該有資料庫的接法")
    for o in opts where o.source == .engine { XCTAssertGreaterThanOrEqual(o.plies.count, 8, o.title) }
  }
}

/// 網站的解說（explain.js 在 JavaScriptCore 裡跑）：要有白話的標題、理由與兩條路
final class ExplainJSTests: XCTestCase {
  @MainActor func testExplainOpeningMistake() async throws {
    let line = try XCTUnwrap(ChessLine(pgn: "1. e4 e5 2. Nf3 f6 *"))
    let p = line.plies[3]
    let before = await StockfishService.shared.analyse(fen: p.fenBefore)
    let after = await StockfishService.shared.analyse(fen: p.fenAfter)
    let r = try XCTUnwrap(Grading.record(p, before: before, after: after))
    let e = try XCTUnwrap(ExplainJS.explain(key: "t-f6", record: r, ply: p, before: before, after: after))
    XCTAssertFalse(e.headline.isEmpty)
    XCTAssertFalse(e.plainReasons.isEmpty)
    XCTAssertFalse(e.plainReasons.contains { $0.contains("勝率") || $0.contains("評分") }, "不講勝率、評分數字")
    XCTAssertEqual(ExplainJS.plain("子力沒有吃虧，但評分從 -0.4 掉到 -1.6。"), "子力沒有吃虧，但局面從均勢變成小劣。")
    XCTAssertTrue(e.lines.contains { $0.kind == "played" })
    // 這步當成對手走的：說明要從使用者的角度講（「你」「對手」對調）
    let opp = try XCTUnwrap(ExplainJS.explain(key: "t-f6", record: r, ply: p, before: before, after: after, opponent: true))
    XCTAssertFalse(opp.lines.contains { $0.outcome.contains("你丟了") }, "對手的步不能說「你丟了」")
    let o = try XCTUnwrap(e.lines.first.flatMap { LineOption($0, base: 3) })
    XCTAssertEqual(o.captions?.count, o.plies.count)
    let report = "\(e.motif)｜\(e.headline)\n" + e.plainReasons.joined(separator: "\n") + "\n" + e.lines.map { "\($0.title)→\($0.plainOutcome)｜" + $0.steps.map(\.caption).joined(separator: " / ") }.joined(separator: "\n")
    try? report.write(toFile: NSTemporaryDirectory() + "explain.txt", atomically: true, encoding: .utf8)
  }
}

/// 網站的跨局分析（report.js）：真實帳號的棋譜要算得出快速統計、先學的一件事；分析過的局要算得出用時與殘局（要連網路）
final class ReportJSTests: XCTestCase {
  @MainActor func testReportOnRealGames() async throws {
    let all = try await GameSources.recentGames(Account(platform: .chesscom, username: "rookielab-io"), limit: 60)
    let q0 = await ReportJS.quick(all)
    let q = try XCTUnwrap(q0)
    XCTAssertEqual(q.total, all.count)
    XCTAssertFalse(q.topOpenings.asWhite.isEmpty)
    XCTAssertNotEqual(q.topOpenings.asWhite.first?.name, "未知開局", "要帶開局名稱")
    let p0 = await ReportJS.prescription(all, rating: all[0].myRating ?? 500)
    let p = try XCTUnwrap(p0)
    XCTAssertFalse(p.pick.label.isEmpty)
    var digests: [GameDigest] = []
    for g in all.prefix(3) {
      let line = try XCTUnwrap(ChessLine(pgn: g.pgn))
      let analyzed = await AnalysisStore.analyze(g, line: line)
      let a = try XCTUnwrap(analyzed)
      if let d = GameDigest(game: g, line: line, analysis: a) { digests.append(d) }
    }
    let d0 = await ReportJS.deep(digests)
    let d = try XCTUnwrap(d0)
    XCTAssertEqual(d.phases.count, 3)
    var out = "先練：\(p.pick.label) 你 \(p.pick.mine) 同 \(p.pick.same) 下 \(p.pick.next)｜\(p.pick.lesson)\n"
    out += "開局：\(q.topOpenings.asWhite.prefix(3).map { "\($0.name) \($0.games)局 \($0.winRate)%" })\n"
    out += "用時：\(String(describing: d.time))\n殘局：\(d.endgames.map { "\($0.name) \($0.games)" })\n習慣：\(d.habits.map { "\($0.name) \($0.games)" })\n"
    out += "階段：\(d.phases.map { "\($0.name) \($0.accuracy ?? -1)" })"
    try? out.write(toFile: NSTemporaryDirectory() + "report.txt", atomically: true, encoding: .utf8)
  }
}
