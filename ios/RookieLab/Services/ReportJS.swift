import Foundation
import JavaScriptCore

/// 跨局分析：直接跑網站的規則分析與彙整（ios/js/report-entry.ts 打包成 Resources/report.js），結果跟網站報告一致。
/// 50 局的規則分析要 1 秒多：放在自己的背景佇列跑（JSContext 只在這條佇列上用），不卡畫面
enum ReportJS {
  private static let queue = DispatchQueue(label: "rookielab.report-js", qos: .userInitiated)
  // MARK: 輸出

  struct Quick: Decodable, Sendable {
    struct Rec: Decodable { let win: Int; let loss: Int; let draw: Int }
    struct Side: Decodable { let games: Int; let wins: Int; let winRate: Int }
    struct ByColor: Decodable { let white: Side; let black: Side }
    struct LossBy: Decodable { let checkmated: Int; let resigned: Int; let timeout: Int; let other: Int }
    struct WinBy: Decodable { let checkmate: Int; let resignation: Int; let timeout: Int; let other: Int }
    struct Opening: Decodable, Hashable { let name: String; let games: Int; let wins: Int; let winRate: Int }
    struct Top: Decodable { let asWhite: [Opening]; let asBlack: [Opening] }
    struct Opp: Decodable { let avg: Int; let whenWin: Int; let whenLoss: Int }
    struct Delta: Decodable { let from: Int; let to: Int; let diff: Int }
    struct Fatigue: Decodable { let earlyWinRate: Int; let lateWinRate: Int; let threshold: Int }
    let total: Int
    let record: Rec
    let winRate: Int
    let byColor: ByColor
    let lossBy: LossBy
    let winBy: WinBy
    let timeoutRate: Int
    let topOpenings: Top
    let avgMoves: Int
    let opponentRating: Opp
    let ratingDelta: Delta?
    let fatigue: Fatigue?
  }

  struct Prescription: Decodable, Sendable {
    struct Row: Decodable, Hashable {
      let key: String, label: String, hint: String, lesson: String
      let mine: String, same: String, next: String, better: String
      let enough: Bool, extra: Bool, gap: Double
    }
    struct Example: Decodable { let gameId: String; let ply: Int; let moveNumber: Int; let played: String; let opponent: String; let date: String; let fen: String }
    let status: String
    let games: Int
    let band: String
    let same: String
    let next: String
    let pick: Row
    let rows: [Row]
    let example: Example?
  }

  struct Deep: Decodable, Sendable {
    struct Time: Decodable {
      let games: Int, moves: Int, avg: Double
      let avgBad: Double?, avgOther: Double?, fastBadShare: Double?, badCount: Int
      let lowRate: Double?, normalRate: Double?, lowMoves: Int
    }
    struct Phase: Decodable { let key: String; let name: String; let games: Int?; let moves: Int?; let accuracy: Double?; let errorsPer100: Double? }
    struct Endgame: Decodable, Hashable { let type: String; let name: String; let tip: String; let games: Int; let ahead: Int; let converted: Int; let even: Int; let evenLost: Int; let accuracy: Double }
    struct Habit: Decodable, Hashable { let kind: String; let games: Int; let name: String; let desc: String; let tip: String }
    let time: Time?
    let phases: [Phase]
    let endgames: [Endgame]
    let habits: [Habit]
  }

  // MARK: 執行

  nonisolated(unsafe) private static let context: JSContext? = {
    guard let url = Bundle.main.url(forResource: "report", withExtension: "js"), let src = try? String(contentsOf: url, encoding: .utf8),
          let ctx = JSContext() else { return nil }
    ctx.exceptionHandler = { _, e in
      #if DEBUG
      print("[report.js]", e?.toString() ?? "")
      #endif
    }
    ctx.evaluateScript(src)
    return ctx
  }()

  private static func call<T: Decodable & Sendable>(_ name: String, _ args: [String]) async -> T? {
    await withCheckedContinuation { c in
      queue.async {
        guard let fn = context?.objectForKeyedSubscript(name), !fn.isUndefined,
              let out = fn.call(withArguments: args)?.toString(), out != "null", out != "undefined" else { c.resume(returning: nil); return }
        c.resume(returning: try? JSONDecoder().decode(T.self, from: Data(out.utf8)))
      }
    }
  }

  private static func json(_ v: some Encodable) -> String { (try? String(data: JSONEncoder().encode(v), encoding: .utf8)) ?? "[]" }

  /// 網站的 GameSummary
  private struct WebGame: Encodable {
    let id: String, platform: String, date: String, endedAt: Double, color: String, opponent: String
    let myRating: Int?, opponentRating: Int?, result: String, timeClass: String, timeControl: String
    let opening: String?, termination: String?, pgn: String
    init(_ g: GameSummary) {
      id = g.id; platform = g.platform.rawValue; endedAt = g.endedAt.timeIntervalSince1970 * 1000
      let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"; f.timeZone = .current
      date = f.string(from: g.endedAt)
      color = g.color.rawValue; opponent = g.opponent; myRating = g.myRating; opponentRating = g.opponentRating
      result = g.result.rawValue; timeClass = g.timeClass; timeControl = g.timeControl; opening = g.openingRaw; pgn = g.pgn
      termination = g.termination ?? (g.lostOnTime ? "timeout" : nil)
    }
  }

  /// 只看棋譜就能算的統計（不用等引擎）
  static func quick(_ games: [GameSummary]) async -> Quick? { await call("RLQuick", [json(games.map(WebGame.init))]) }

  /// 先學的一件事：至少 10 局才給
  static func prescription(_ games: [GameSummary], rating: Int) async -> Prescription? {
    await call("RLPrescription", [json(games.map(WebGame.init)), "\(rating)"])
  }

  /// 網站的 AnalyzedGame（我方每一步的評級、勝率曲線、各階段步數）
  private struct WebAnalyzed: Encodable {
    let id: String, platform: String, date: String, endedAt: Double, color: String, opponent: String
    let myRating: Int?, opponentRating: Int?, result: String, timeClass: String, timeControl: String
    let opening: String?, termination: String?, pgn: String
    let lossReason: String?
    let moves: [ExplainJS.WebRecord]
    let accuracy: Double
    let winProb: [Double]
    let blunders: [String]
    let peakWinProb: Double
    let myMoveCount: Int
    let missedOpponentBlunders: Int
    let phaseBlunders: [String: Int]
    let phaseMoves: [String: Int]
  }

  @MainActor static func deep(_ digests: [GameDigest]) async -> Deep? {
    let list: [WebAnalyzed] = digests.map { d in
      let g = WebGame(d.game)
      let mine = d.analysis.records.compactMap { $0 }.filter { $0.mover == d.game.color }
      let moves = mine.map { r in
        ExplainJS.webRecord(r, ply: d.line.plies[r.ply], before: d.analysis.evals[r.ply] ?? nil, after: d.analysis.evals[safe: r.ply + 1] ?? nil, oneBased: true)
      }
      let reason: String? = switch d.lossReason {
      case .threwWinning: "threw_winning"
      case .opening: "opening"
      case .timeout: "timeout"
      case .outplayed: "outplayed"
      case nil: nil
      }
      // 對手走了壞棋，我下一步卻沒抓到（不是最佳、好棋、傑出、優秀）
      let recs = d.analysis.records
      let missed = recs.indices.filter { k in
        guard let o = recs[k], o.mover != d.game.color, o.cls.isBad, let next = recs[safe: k + 1] ?? nil else { return false }
        return ![.best, .great, .brilliant, .excellent].contains(next.cls)
      }.count
      return WebAnalyzed(
        id: g.id, platform: g.platform, date: g.date, endedAt: g.endedAt, color: g.color, opponent: g.opponent,
        myRating: g.myRating, opponentRating: g.opponentRating, result: g.result, timeClass: g.timeClass, timeControl: g.timeControl,
        opening: g.opening, termination: g.termination, pgn: g.pgn, lossReason: reason, moves: moves, accuracy: d.accuracy,
        winProb: mine.map(\.winAfter), blunders: [], peakWinProb: mine.map(\.winAfter).max() ?? 0.5, myMoveCount: mine.count,
        missedOpponentBlunders: max(0, missed),
        phaseBlunders: Dictionary(uniqueKeysWithValues: d.phases.map { ($0.key.rawValue, $0.value.errors) }),
        phaseMoves: Dictionary(uniqueKeysWithValues: d.phases.map { ($0.key.rawValue, $0.value.moves) }))
    }
    return await call("RLDeep", [json(list)])
  }
}
