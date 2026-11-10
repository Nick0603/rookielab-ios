import ChessKit
import Foundation
import Observation

/// 與網站共用 Lichess chess-openings（CC0），裝置離線即可查理論。
struct OpeningBook: Sendable {
  struct Index: Decodable, Sendable { let names: [String]; let pos: [String: [Int]] }
  struct Position: Sendable { let name: String; let lines: Int }
  struct Candidate: Identifiable, Sendable {
    let uci: String, san: String, name: String
    let lines: Int
    var id: String { uci }
  }
  let index: Index?
  static let shared = OpeningBook()
  init() {
    index = Bundle.main.url(forResource: "opening-book", withExtension: "json")
      .flatMap { try? Data(contentsOf: $0) }.flatMap { try? JSONDecoder().decode(Index.self, from: $0) }
  }
  var available: Bool { index != nil }
  static func key(_ fen: String) -> String {
    var hash: UInt32 = 0x811c9dc5
    for byte in fen.split(separator: " ").prefix(3).joined(separator: " ").utf8 { hash = (hash ^ UInt32(byte)) &* 0x01000193 }
    return String(hash, radix: 36)
  }
  func position(_ fen: String) -> Position? {
    guard let index, let hit = index.pos[Self.key(fen)], hit.count == 2, index.names.indices.contains(hit[0]) else { return nil }
    let name = index.names[hit[0]].split(separator: "|", maxSplits: 1).last.map(String.init) ?? ""
    return Position(name: name, lines: hit[1])
  }
  func candidates(_ fen: String) -> [Candidate] {
    guard let pos = ChessKit.Position(fen: fen) else { return [] }
    let board = Board(position: pos)
    var result: [Candidate] = []
    for piece in pos.pieces where piece.color == pos.sideToMove {
      for square in board.legalMoves(forPieceAt: piece.square) {
        let promotion = piece.kind == .pawn && (square.rank.value == 1 || square.rank.value == 8) ? "q" : ""
        let uci = piece.square.notation + square.notation + promotion
        if let ply = ChessLine.ply(fen: fen, uci: uci, index: 0), let info = position(ply.fenAfter) {
          result.append(.init(uci: uci, san: ply.san, name: info.name, lines: info.lines))
        }
      }
    }
    return result.sorted { $0.lines == $1.lines ? $0.uci < $1.uci : $0.lines > $1.lines }
  }
  func isTheory(_ plies: [Ply]) -> Bool { !plies.isEmpty && plies.allSatisfy { position($0.fenAfter) != nil } }
}

struct OpeningProfile: Identifiable {
  struct Departure: Identifiable {
    let game: GameSummary
    let line: [Ply]
    let played: Ply
    var id: String { game.id + ":" + String(played.index) }
  }
  let family: String
  let side: Side
  let games: Int
  let wins: Int
  let draws: Int
  let myBookMoves: Int
  let leftByMe: Int
  let leftByOpponent: Int
  let line: [Ply]
  let departures: [Departure]
  var id: String { family + ":" + side.rawValue }
  var average: Double { Double(myBookMoves) / Double(max(1, games)) }
  var status: String {
    if games < 3 { return String(localized: "資料還不多，可以先練") }
    if leftByMe * 2 >= games { return String(localized: "值得先練") }
    return average < 3 ? String(localized: "走得淺") : String(localized: "熟悉")
  }
  static func build(games: [GameSummary], book: OpeningBook = .shared) -> [OpeningProfile] {
    struct Row { let game: GameSummary; let line: [Ply]; let mine: Int; let departure: Departure?; let opponentLeft: Bool }
    var groups: [String: [Row]] = [:]
    for game in games {
      guard let parsed = ChessLine(pgn: game.pgn), parsed.startFen == AnalysisModel.standard, parsed.failedAt == nil else { continue }
      let known = Array(parsed.plies.prefix { book.position($0.fenAfter) != nil })
      let next = parsed.plies.dropFirst(known.count).first
      let canContinue = next.map { !book.candidates($0.fenBefore).isEmpty } ?? false
      let departure = next.flatMap { $0.mover == game.color && canContinue ? Departure(game: game, line: known, played: $0) : nil }
      let family = Openings.family(game.openingRaw ?? known.last.flatMap { book.position($0.fenAfter)?.name })
      groups[family + ":" + game.color.rawValue, default: []].append(Row(game: game, line: known, mine: known.filter { $0.mover == game.color }.count, departure: departure, opponentLeft: canContinue && next?.mover != game.color))
    }
    return groups.values.compactMap { rows in
      guard let first = rows.first else { return nil }
      let family = Openings.family(first.game.openingRaw ?? first.line.last.flatMap { book.position($0.fenAfter)?.name })
      return OpeningProfile(family: family, side: first.game.color, games: rows.count,
        wins: rows.filter { $0.game.result == .win }.count, draws: rows.filter { $0.game.result == .draw }.count,
        myBookMoves: rows.reduce(0) { $0 + $1.mine }, leftByMe: rows.compactMap(\.departure).count,
        leftByOpponent: rows.filter(\.opponentLeft).count, line: Array(first.line.prefix(12)), departures: rows.compactMap(\.departure))
    }.sorted { $0.games == $1.games ? $0.id < $1.id : $0.games > $1.games }
  }
}

/// 一條可獨立複習的理論路線。帳號、顏色、完整走法相同才合併。
struct OpeningRoute: Codable, Identifiable, Hashable {
  static let learner = "learner"
  let account: String
  let name: String
  let side: Side
  let moves: [String]
  var id: String { account + ":" + side.rawValue + ":" + moves.joined(separator: " ") }
  var plies: [Ply] {
    var fen = AnalysisModel.standard
    var result: [Ply] = []
    for uci in moves {
      guard let ply = ChessLine.ply(fen: fen, uci: uci, index: result.count) else { return [] }
      result.append(ply); fen = ply.fenAfter
    }
    return result
  }
  var valid: Bool {
    guard !moves.isEmpty, moves.count <= 24 else { return false }
    let line = plies
    return line.count == moves.count && line.contains { $0.mover == side } && (OpeningBook.shared.isTheory(line) || OpeningCourse.contains(moves))
  }
}

@MainActor @Observable
final class OpeningReviewStore {
  struct Card: Codable, Identifiable, Equatable {
    var route: OpeningRoute
    var due: Int
    var streak = 0
    var reps = 0
    var interval = 0
    var lastDay: Int?
    var updated: Date = Date()
    var removed = false
    var id: String { route.id }
    @MainActor var mastered: Bool { streak >= ReviewStore.graduate }
  }
  static let shared = OpeningReviewStore(learnerScope: true)
  private(set) var cards: [Card] = []
  private let defaults: UserDefaults?
  private let sync: Bool
  private let learnerScope: Bool
  private var observer: NSObjectProtocol?
  private static let key = "opening-review.v1"
  init(defaults: UserDefaults? = .standard, sync: Bool = true, learnerScope: Bool = false) {
    self.defaults = defaults; self.sync = sync; self.learnerScope = learnerScope
    if let data = defaults?.data(forKey: Self.key), let saved = try? JSONDecoder().decode([Card].self, from: data) { cards = saved }
    if learnerScope { cards = Self.migrate(cards) }
    if sync {
      observer = NotificationCenter.default.addObserver(forName: NSUbiquitousKeyValueStore.didChangeExternallyNotification, object: NSUbiquitousKeyValueStore.default, queue: .main) { [weak self] _ in
        MainActor.assumeIsolated { self?.mergeCloud() }
      }
      NSUbiquitousKeyValueStore.default.synchronize()
      mergeCloud()
    }
    if learnerScope { save() }
  }
  private func mergeCloud() {
    guard let data = NSUbiquitousKeyValueStore.default.data(forKey: Self.key),
          let remote = try? JSONDecoder().decode([Card].self, from: (try? (data as NSData).decompressed(using: .zlib) as Data) ?? data) else { return }
    let incoming = learnerScope ? Self.migrate(remote) : remote
    var merged = Dictionary(cards.map { ($0.id, $0) }, uniquingKeysWith: { a, b in a.updated >= b.updated ? a : b })
    for card in incoming where merged[card.id].map({ $0.updated < card.updated }) ?? true { merged[card.id] = card }
    let result = merged.values.sorted { $0.id < $1.id }
    guard result != cards.sorted(by: { $0.id < $1.id }) else { return }
    cards = result; save()
  }
  private func save() {
    let encoder = JSONEncoder(); encoder.outputFormatting = .sortedKeys
    guard let data = try? encoder.encode(cards.sorted { $0.id < $1.id }) else { return }
    defaults?.set(data, forKey: Self.key)
    // 與既有 review.v1 共用 iCloud 的總容量，留空間給原本的複習卡。
    if sync, let compressed = try? (data as NSData).compressed(using: .zlib) as Data, compressed.count < 80_000 {
      NSUbiquitousKeyValueStore.default.set(compressed, forKey: Self.key)
    }
  }
  static func migrate(_ input: [Card]) -> [Card] {
    var result: [String: Card] = [:]
    for original in input {
      var card = original
      card.route = OpeningRoute(account: OpeningRoute.learner, name: original.route.name, side: original.route.side, moves: original.route.moves)
      if result[card.id].map({ $0.updated < card.updated }) ?? true { result[card.id] = card }
    }
    return result.values.sorted { $0.id < $1.id }
  }
  private func scoped(_ route: OpeningRoute) -> OpeningRoute {
    learnerScope ? .init(account: OpeningRoute.learner, name: route.name, side: route.side, moves: route.moves) : route
  }
  func active(account: String) -> [Card] { cards.filter { (learnerScope || $0.route.account == account) && !$0.removed } }
  func due(account: String, today: Int = Day.number()) -> [Card] {
    active(account: account).filter { !$0.mastered && $0.due <= today && ($0.lastDay.map { today - $0 >= ReviewStore.minimumInterval } ?? true) }
      .sorted { $0.due == $1.due ? $0.id < $1.id : $0.due < $1.due }
  }
  func has(_ route: OpeningRoute) -> Bool { cards.contains { $0.id == scoped(route).id && !$0.removed } }
  @discardableResult func add(_ route: OpeningRoute, today: Int = Day.number()) -> Bool {
    let route = scoped(route)
    guard route.valid, !has(route) else { return false }
    if let i = cards.firstIndex(where: { $0.id == route.id }) { cards[i].removed = false; cards[i].updated = Date() }
    else { cards.append(Card(route: route, due: today)) }
    save(); return true
  }
  private func resolved(_ id: String) -> String {
    guard learnerScope else { return id }
    let parts = id.split(separator: ":")
    guard parts.count >= 3 else { return id }
    return OpeningRoute.learner + ":" + parts.suffix(2).joined(separator: ":")
  }
  func remove(_ id: String) {
    let id = resolved(id)
    guard let i = cards.firstIndex(where: { $0.id == id }) else { return }
    cards[i].removed = true; cards[i].updated = Date(); save()
  }
  /// 提前加練不增加記憶連對數；看過提示／走偏後完成仍記為需要複習。
  func answer(_ id: String, clean: Bool, today: Int = Day.number()) {
    let id = resolved(id)
    guard let i = cards.firstIndex(where: { $0.id == id }), !cards[i].removed else { return }
    if clean && (cards[i].due > today || (cards[i].lastDay.map { today - $0 < ReviewStore.minimumInterval } ?? false)) { return }
    cards[i].reps += 1; cards[i].lastDay = today; cards[i].streak = clean ? cards[i].streak + 1 : 0
    cards[i].interval = clean ? (cards[i].streak == 1 ? 3 : cards[i].streak == 2 ? 7 : max(3, Int(Double(cards[i].interval) * 2.5))) : 3
    cards[i].due = today + cards[i].interval; cards[i].updated = Date(); save()
  }
}

@MainActor @Observable
final class OpeningExercise {
  private(set) var route: OpeningRoute
  private(set) var plies: [Ply]
  private let alternatives: [OpeningRoute]
  private let automaticOpponent: Bool
  private(set) var cursor = 0
  private(set) var clean = true
  private(set) var finished = false
  var feedback: String?
  var hint = false
  init(route: OpeningRoute, alternatives: [OpeningRoute] = [], at: Int = 0, clean: Bool = true, automaticOpponent: Bool = true) {
    self.route = route; plies = route.plies; self.alternatives = alternatives; self.clean = clean; self.automaticOpponent = automaticOpponent
    cursor = min(max(0, at), plies.count)
    finished = cursor == plies.count && !plies.isEmpty
    if automaticOpponent { advanceOpponent() }
  }
  func reply() {
    guard !finished, let expected, expected.mover != route.side else { return }
    Sounds.play(for: expected); cursor += 1
    finished = cursor == plies.count
  }
  var fen: String { cursor == 0 ? AnalysisModel.standard : plies[cursor - 1].fenAfter }
  var expected: Ply? { plies[safe: cursor] }
  var completed: Int { plies.prefix(cursor).filter { $0.mover == route.side }.count }
  var total: Int { plies.filter { $0.mover == route.side }.count }
  private func advanceOpponent() {
    while cursor < plies.count && plies[cursor].mover != route.side { cursor += 1 }
    finished = cursor == plies.count && !plies.isEmpty
  }
  func move(_ uci: String) {
    guard !finished, let expected, expected.mover == route.side, ChessLine.ply(fen: fen, uci: uci, index: cursor) != nil else { return }
    if uci != expected.uci, let other = alternatives.first(where: { candidate in
      candidate.side == route.side && candidate.moves.count > cursor && Array(candidate.moves.prefix(cursor)) == Array(route.moves.prefix(cursor)) && candidate.moves[cursor] == uci
    }) {
      route = other; plies = other.plies
      move(uci); return
    }
    guard uci == expected.uci else {
      clean = false
      let inBook = OpeningBook.shared.candidates(fen).contains { $0.uci == uci }
      feedback = inBook ? String(localized: "這也是理論走法；這次先練選定的路線，也可以到分析板比較。") : String(localized: "這步不在目前收錄的理論裡，不代表是壞棋。可以再試一次，或到分析板看看。")
      return
    }
    Sounds.play(for: expected); cursor += 1; hint = false; feedback = nil
    if automaticOpponent { advanceOpponent() } else { finished = cursor == plies.count }
  }
  func showHint() { clean = false; hint = true }
  func explored() { clean = false }
}
