import Foundation
import SwiftUI

enum SourceError: LocalizedError {
  case notFound, network, empty
  var errorDescription: String? {
    switch self {
    case .notFound: "找不到這個帳號"
    case .network: "暫時抓不到對局，稍後再試"
    case .empty: "這個帳號最近沒有對局"
    }
  }
}

/// 對局來源。chess.com 直接用公開 API；Lichess 要 token，走網站的 /api/lichess-games（伺服器帶 token）
enum GameSources {
  static let site = URL(string: "https://rookielab.io")!

  static func recentGames(_ account: Account, limit: Int = 40) async throws -> [GameSummary] {
    switch account.platform {
    case .chesscom: try await chesscom(account.username, limit: limit)
    case .lichess: try await lichess(account.username, limit: limit)
    }
  }

  private static func get(_ url: URL) async throws -> (Data, Int) {
    var req = URLRequest(url: url)
    req.setValue("RookieLab-iOS/1.0 (+https://rookielab.io)", forHTTPHeaderField: "User-Agent")
    do {
      let (d, r) = try await URLSession.shared.data(for: req)
      return (d, (r as? HTTPURLResponse)?.statusCode ?? 0)
    } catch { throw SourceError.network }
  }

  // MARK: chess.com

  private struct Archives: Decodable { let archives: [String] }
  private struct CGames: Decodable { let games: [CGame] }
  private struct CPlayer: Decodable { let username: String; let rating: Int?; let result: String }
  private struct CGame: Decodable {
    let url: String?; let uuid: String?; let pgn: String?; let end_time: Double?
    let time_class: String?; let time_control: String?; let rules: String?
    let white: CPlayer; let black: CPlayer
  }

  private static func chesscom(_ user: String, limit: Int) async throws -> [GameSummary] {
    let name = user.lowercased()
    let (d, code) = try await get(URL(string: "https://api.chess.com/pub/player/\(name)/games/archives")!)
    if code == 404 { throw SourceError.notFound }
    guard code == 200, let arch = try? JSONDecoder().decode(Archives.self, from: d) else { throw SourceError.network }
    var out: [GameSummary] = []
    for month in arch.archives.reversed() {
      guard let u = URL(string: month) else { continue }
      let (md, mc) = try await get(u)
      guard mc == 200, let g = try? JSONDecoder().decode(CGames.self, from: md) else { continue }
      for game in g.games.reversed() where (game.rules ?? "chess") == "chess" {
        guard let x = summary(game, user: name) else { continue }
        out.append(x)
        if out.count >= limit { return out }
      }
      if out.count >= limit { break }
    }
    if out.isEmpty { throw SourceError.empty }
    return out
  }

  private static func summary(_ game: CGame, user name: String) -> GameSummary? {
    guard let pgn = game.pgn else { return nil }
    let meWhite = game.white.username.lowercased() == name
    let me = meWhite ? game.white : game.black, opp = meWhite ? game.black : game.white
    let result: GameResult = me.result == "win" ? .win : ["agreed", "repetition", "stalemate", "insufficient", "50move", "timevsinsufficient"].contains(me.result) ? .draw : .loss
    return GameSummary(
      id: game.uuid ?? game.url ?? UUID().uuidString, platform: .chesscom,
      endedAt: Date(timeIntervalSince1970: game.end_time ?? 0), color: meWhite ? .white : .black,
      opponent: opp.username, myRating: me.rating, opponentRating: opp.rating, result: result,
      timeClass: game.time_class ?? "", timeControl: game.time_control ?? "", pgn: pgn, url: game.url.flatMap(URL.init(string:)),
      termination: me.result, opponentEnd: opp.result)
  }

  // MARK: 分享進來的單局

  /// 分享進來的一局：雙方帳號，以及「以某一方的角度」取得這局
  struct Shared {
    let platform: Platform
    let white: String
    let black: String
    /// 連結上看得出是哪一方分享的（Lichess 自己的對局連結會帶 /white、/black）
    var hint: Side? = nil
    let fetch: (String) async throws -> GameSummary
  }

  private struct CCallback: Decodable {
    struct G: Decodable { let pgnHeaders: [String: Value]? }
    enum Value: Decodable {
      case s(String), i(Int)
      init(from d: Decoder) throws {
        let c = try d.singleValueContainer()
        if let x = try? c.decode(String.self) { self = .s(x) } else { self = .i(try c.decode(Int.self)) }
      }
      var string: String { switch self { case let .s(x): x; case let .i(x): "\(x)" } }
    }
    let game: G
  }

  /// 對局連結 → 雙方帳號（chess.com 用網站給對局頁的資料；Lichess 單局匯出不用 token）
  static func shared(_ link: String) async throws -> Shared {
    if link.contains("chess.com") {
      guard let r = link.range(of: #"(live|daily)/(game/)?\d+"#, options: .regularExpression) else { throw SourceError.notFound }
      let part = String(link[r])
      let kind = part.hasPrefix("daily") ? "daily" : "live"
      let id = part.split(separator: "/").last.map(String.init) ?? ""
      let (d, code) = try await get(URL(string: "https://www.chess.com/callback/\(kind)/game/\(id)")!)
      guard code == 200, let cb = try? JSONDecoder().decode(CCallback.self, from: d), let h = cb.game.pgnHeaders,
            let w = h["White"]?.string, let b = h["Black"]?.string else { throw SourceError.notFound }
      let date = (h["EndDate"] ?? h["Date"])?.string.split(separator: ".").map(String.init) ?? []
      return Shared(platform: .chesscom, white: w, black: b) { user in
        // 從這個帳號那個月（和下個月，跨月結束的局）的公開棋譜找到這一局
        guard date.count >= 2, let y = Int(date[0]), let m = Int(date[1]) else { throw SourceError.notFound }
        for (yy, mm) in [(y, m), m == 12 ? (y + 1, 1) : (y, m + 1)] {
          let u = URL(string: "https://api.chess.com/pub/player/\(user.lowercased())/games/\(yy)/\(String(format: "%02d", mm))")!
          let (md, mc) = try await get(u)
          guard mc == 200, let g = try? JSONDecoder().decode(CGames.self, from: md) else { continue }
          if let hit = g.games.first(where: { ($0.url ?? "").hasSuffix("/\(id)") }), let x = summary(hit, user: user.lowercased()) { return x }
        }
        throw SourceError.notFound
      }
    }
    guard let r = link.range(of: #"lichess\.org/(game/|embed/game/)?[A-Za-z0-9]{8}"#, options: .regularExpression) else { throw SourceError.notFound }
    let id = String(link[r].suffix(8))
    let tail = link[r.upperBound...].lowercased()
    let hint: Side? = tail.hasPrefix("/white") ? .white : tail.hasPrefix("/black") ? .black : nil
    var req = URLRequest(url: URL(string: "https://lichess.org/game/export/\(id)?pgnInJson=true&clocks=true&evals=false")!)
    req.setValue("application/json", forHTTPHeaderField: "Accept")
    guard let (d, resp) = try? await URLSession.shared.data(for: req), (resp as? HTTPURLResponse)?.statusCode == 200,
          let g = try? JSONDecoder().decode(LGame.self, from: d) else { throw SourceError.notFound }
    let w = g.players?.white?.user?.name ?? "?", b = g.players?.black?.user?.name ?? "?"
    return Shared(platform: .lichess, white: w, black: b, hint: hint) { user in
      guard let x = lichessSummary(g, user: user) else { throw SourceError.notFound }
      return x
    }
  }

  // MARK: Lichess

  private struct LGame: Decodable {
    struct P: Decodable { struct U: Decodable { let name: String? }; let user: U?; let rating: Int? }
    struct Ps: Decodable { let white: P?; let black: P? }
    struct Clock: Decodable { let initial: Int?; let increment: Int? }
    let id: String; let lastMoveAt: Double?; let createdAt: Double?; let speed: String?
    let winner: String?; let status: String?; let players: Ps?; let pgn: String?; let clock: Clock?
  }

  private static func lichessSummary(_ g: LGame, user: String) -> GameSummary? {
    guard let pgn = g.pgn else { return nil }
    let me = user.lowercased()
    let meWhite = g.players?.white?.user?.name?.lowercased() == me
    let my = meWhite ? g.players?.white : g.players?.black, opp = meWhite ? g.players?.black : g.players?.white
    let result: GameResult = g.winner == nil ? .draw : (g.winner == "white") == meWhite ? .win : .loss
    let tc = g.clock.map { "\(($0.initial ?? 0))+\($0.increment ?? 0)" } ?? ""
    return GameSummary(
      id: g.id, platform: .lichess, endedAt: Date(timeIntervalSince1970: (g.lastMoveAt ?? g.createdAt ?? 0) / 1000),
      color: meWhite ? .white : .black, opponent: opp?.user?.name ?? "?", myRating: my?.rating, opponentRating: opp?.rating,
      result: result, timeClass: g.speed ?? "", timeControl: tc, pgn: pgn, url: URL(string: "https://lichess.org/\(g.id)"),
      termination: result == .win ? "win" : result == .draw ? "agreed" : ["mate": "checkmated", "resign": "resigned", "outoftime": "timeout", "timeout": "timeout"][g.status ?? ""] ?? g.status,
      opponentEnd: result == .win && g.status == "resign" ? "resigned" : nil)
  }

  private static func lichess(_ user: String, limit: Int) async throws -> [GameSummary] {
    var c = URLComponents(url: site.appendingPathComponent("api/lichess-games"), resolvingAgainstBaseURL: false)!
    c.queryItems = [.init(name: "user", value: user), .init(name: "max", value: "\(limit)")]
    let (d, code) = try await get(c.url!)
    if code == 404 { throw SourceError.notFound }
    guard code == 200 else { throw SourceError.network }
    let me = user.lowercased()
    var out: [GameSummary] = []
    for line in String(decoding: d, as: UTF8.self).split(separator: "\n") {
      guard let g = try? JSONDecoder().decode(LGame.self, from: Data(line.utf8)), let x = lichessSummary(g, user: me) else { continue }
      out.append(x)
    }
    if out.isEmpty { throw SourceError.empty }
    return out
  }
}

/// 走法資料庫：網站的 /api/explorer（Lichess 資料庫、伺服器帶 token、快取 30 天）
enum Explorer {
  struct Move: Decodable, Hashable { let san: String; let uci: String; let games: Int; let white: Int; let draws: Int; let black: Int }
  struct Result: Decodable { let total: Int; let moves: [Move] }

  static let bands: [(key: String, label: String)] = [
    ("all", "全部"), ("0", "1000 以下"), ("1000", "1000–1199"), ("1200", "1200–1399"), ("1400", "1400–1599"),
    ("1600", "1600–1799"), ("1800", "1800–1999"), ("2000", "2000–2199"), ("2200", "2200 以上"),
  ]

  /// chess.com 分數 → 約等於的 Lichess 分數（資料庫是 Lichess 的；同一個人在 Lichess 通常高 300–500 分），只拿來選預設分段
  static func lichessRating(_ r: Int, platform: Platform) -> Int {
    platform == .chesscom ? (r >= 2400 ? r + 50 : Int((Double(r) * 0.75 + 650).rounded())) : r
  }

  static func band(for rating: Int?, platform: Platform = .lichess) -> String {
    guard let rating else { return "all" }
    let r = lichessRating(rating, platform: platform)
    for k in ["2200", "2000", "1800", "1600", "1400", "1200", "1000"] where r >= Int(k)! { return k }
    return "0"
  }

  /// 好不好找：這個分段的玩家在這個局面，多少人走了這一步。局數不夠（少於 30 局）就不下結論
  static let minForDifficulty = 30
  struct Findability { let share: Double; let games: Int
    var label: String { share >= 0.4 ? "好找" : share >= 0.15 ? "有點難" : "不容易找到" }
    var color: Color { share >= 0.4 ? .green : share >= 0.15 ? .orange : .red }
  }
  static func findability(_ r: Result?, uci: String) -> Findability? {
    guard let r, r.total >= minForDifficulty else { return nil }
    let n = r.moves.first { $0.uci == uci || $0.uci.prefix(4) == uci.prefix(4) }?.games ?? 0
    return Findability(share: Double(n) / Double(r.total), games: r.total)
  }

  private static var cache: [String: Result] = [:]

  static func fetch(fen: String, band: String) async -> Result? {
    let key = "\(band)|\(fen)"
    if let hit = cache[key] { return hit }
    var c = URLComponents(url: GameSources.site.appendingPathComponent("api/explorer"), resolvingAgainstBaseURL: false)!
    c.queryItems = [.init(name: "fen", value: fen), .init(name: "band", value: band)]
    guard let (d, r) = try? await URLSession.shared.data(from: c.url!), (r as? HTTPURLResponse)?.statusCode == 200,
          let res = try? JSONDecoder().decode(Result.self, from: d) else { return nil }
    cache[key] = res
    return res
  }
}

/// 存過的帳號（使用者排的順序）與目前用的那一個。切換不改順序；新帳號放最前面
enum AccountStore {
  private static let key = "rookielab.accounts"
  private static let currentKey = "rookielab.current"

  static func all() -> [Account] {
    guard let d = UserDefaults.standard.data(forKey: key) else { return [] }
    return (try? JSONDecoder().decode([Account].self, from: d)) ?? []
  }

  static func save(_ list: [Account]) {
    UserDefaults.standard.set(try? JSONEncoder().encode(list), forKey: key)
  }

  static func remember(_ a: Account) {
    var list = all()
    if !list.contains(where: { $0.id == a.id }) { list.insert(a, at: 0) }
    save(list)
  }

  static func remove(_ a: Account) {
    save(all().filter { $0.id != a.id })
    if current?.id == a.id { current = nil }
  }

  static var current: Account? {
    get {
      let list = all()
      let id = UserDefaults.standard.string(forKey: currentKey)
      return list.first { $0.id == id } ?? list.first
    }
    set { UserDefaults.standard.set(newValue?.id, forKey: currentKey) }
  }
}
