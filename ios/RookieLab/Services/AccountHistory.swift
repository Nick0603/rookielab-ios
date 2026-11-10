import Foundation

/// Validation history is separate from the existing ordered source list, preserving old data.
enum AccountHistory {
  private static let key = "validatedChessAccounts.v1"
  static var records: [String: Double] { UserDefaults.standard.dictionary(forKey: key) as? [String: Double] ?? [:] }
  static func verified(_ a: Account) -> Bool { records[a.id] != nil }
  static func mark(_ a: Account, at date: Date = Date()) {
    var r = records; r[a.id] = date.timeIntervalSince1970
    UserDefaults.standard.set(r, forKey: key)
  }
  static func forget(_ a: Account) {
    var r = records; r.removeValue(forKey: a.id); UserDefaults.standard.set(r, forKey: key)
  }
  static func recent(_ accounts: [Account]) -> [Account] {
    let r = records
    return accounts.filter { r[$0.id] != nil }.sorted { (r[$0.id] ?? 0) > (r[$1.id] ?? 0) }
  }
  static func normalized(_ a: Account) -> Account? {
    let name = a.username.trimmingCharacters(in: .whitespacesAndNewlines)
    guard (2...50).contains(name.count), name.range(of: "^[A-Za-z0-9_-]+$", options: .regularExpression) != nil else { return nil }
    return Account(platform: a.platform, username: name)
  }
}

@MainActor @Observable final class AccountConnector {
  private(set) var busy = false
  private(set) var error: String?
  private var generation = 0
  func cancel() { generation += 1 }
  private let fetch: (Account) async throws -> [GameSummary]
  init(fetch: @escaping (Account) async throws -> [GameSummary] = { try await GameSources.recentGames($0, limit: 30) }) { self.fetch = fetch }
  func connect(_ input: Account, to app: AppModel) async -> Bool {
    guard !busy else { return false }
    guard let a = AccountHistory.normalized(input) else {
      error = String(localized: "請輸入棋站的使用者名稱，不是網址或 Email。")
      return false
    }
    Telemetry.log("account_connect_attempt", ["platform": a.platform.rawValue])
    let token = generation
    busy = true; error = nil
    defer { busy = false }
    do {
      let games: [GameSummary]
      do {
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("-accountDemo") {
          if a.username == "demo-missing" { throw SourceError.notFound }
          games = [GameSummary(id: "ui-account-demo", platform: a.platform, endedAt: Date(), color: .white, opponent: "Demo opponent", myRating: nil, opponentRating: nil, result: .win, timeClass: "blitz", timeControl: "180", pgn: "1. e4 e5 2. Qh5 Nc6 3. Bc4 Nf6 4. Qxf7#", url: nil)]
        } else { games = try await fetch(a) }
        #else
        games = try await fetch(a)
        #endif
      }
      catch SourceError.empty { games = [] }
      try Task.checkCancellation()
      guard token == generation else { return false }
      AccountHistory.mark(a)
      app.use(a, loaded: games)
      Telemetry.log("account_connect_success", ["platform": a.platform.rawValue])
      return true
    } catch is CancellationError { return false }
    catch { Telemetry.log("account_connect_failed", ["platform": a.platform.rawValue]); self.error = error.localizedDescription; return false }
  }
}
