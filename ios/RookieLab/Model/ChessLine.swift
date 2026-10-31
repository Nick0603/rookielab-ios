import ChessKit
import Foundation

/// 一手棋：走之前、走之後的局面與走法
struct Ply: Hashable {
  let index: Int
  let san: String
  let uci: String
  let from: String
  let to: String
  let mover: Side
  let moveNumber: Int
  let fenBefore: String
  let fenAfter: String
  /// 吃到的子（p n b r q），沒吃是 nil
  let captured: String?
  let isCheckmate: Bool
}

/// PGN → 主線的每一手（棋規交給 ChessKit）
struct ChessLine {
  let startFen: String
  let plies: [Ply]

  /// 解析不了時，停在哪一手（除錯用）
  private(set) var failedAt: String?

  /// 自己切 PGN 的走法（拿掉標頭、註解、變化、手數、結果），再一步一步交給 ChessKit 的棋規。
  /// 不用 ChessKit 的 PGN 解析器：有些 chess.com 的棋譜它會整局解析失敗。
  init?(pgn: String) {
    var startPos = Position.standard
    if let fen = Self.tag("FEN", in: pgn), let p = Position(fen: fen) { startPos = p }
    startFen = startPos.fen
    var board = Board(position: startPos)
    var out: [Ply] = []
    for san in Self.sanTokens(pgn) {
      let pos = board.position
      guard let m = Self.play(san, on: &board) else {
        failedAt = "\(san) @ \(pos.fen)"
        break
      }
      out.append(Self.ply(m, before: pos.fen, after: board.position.fen, index: out.count, mate: san.hasSuffix("#")))
    }
    if out.isEmpty { return nil }
    plies = out
  }

  init(startFen: String, plies: [Ply]) {
    self.startFen = startFen
    self.plies = plies
  }

  static func ply(_ m: Move, before: String, after: String, index: Int, mate: Bool = false) -> Ply {
    var captured: String?
    if case let .capture(p) = m.result { captured = p.kind == .pawn ? "p" : p.kind.rawValue.lowercased() }
    let promoChar = m.promotedPiece.map { $0.kind.rawValue.lowercased() } ?? ""
    let mover: Side = m.piece.color == .white ? .white : .black
    return Ply(
      index: index, san: m.san, uci: m.start.notation + m.end.notation + promoChar,
      from: m.start.notation, to: m.end.notation, mover: mover,
      moveNumber: Int(before.split(separator: " ").last ?? "1") ?? 1, fenBefore: before, fenAfter: after,
      captured: captured, isCheckmate: m.checkState == .checkmate || mate)
  }

  /// 從某個局面走一步（分析棋盤用）；promotion 是 q r b n
  static func ply(fen: String, uci: String, index: Int) -> Ply? {
    guard uci.count >= 4, let pos = Position(fen: fen) else { return nil }
    var board = Board(position: pos)
    guard var m = board.move(pieceAt: Square(String(uci.prefix(2))), to: Square(String(uci.dropFirst(2).prefix(2)))) else { return nil }
    if uci.count == 5, let k = Piece.Kind(rawValue: uci.suffix(1).uppercased()) { m = board.completePromotion(of: m, to: k) }
    return ply(m, before: fen, after: board.position.fen, index: index)
  }

  /// 在合法走法裡找 SAN 一樣的那一步走下去。
  /// 不用 ChessKit 的 Move(san:)：有標明起點的走法（Ngxe7、Rbc1）它會挑錯子。
  private static func play(_ san: String, on board: inout Board) -> Move? {
    let want = norm(san)
    let side = board.position.sideToMove
    for piece in board.position.pieces where piece.color == side {
      for dest in board.legalMoves(forPieceAt: piece.square) {
        var trial = board
        guard var m = trial.move(pieceAt: piece.square, to: dest) else { continue }
        if piece.kind == .pawn, dest.rank.value == 1 || dest.rank.value == 8 {
          let kind = promoKind(san) ?? .queen
          m = trial.completePromotion(of: m, to: kind)
        }
        if norm(m.san) == want { board = trial; return m }
      }
    }
    return nil
  }

  private static func norm(_ san: String) -> String {
    san.replacingOccurrences(of: "[+#!?]", with: "", options: .regularExpression).replacingOccurrences(of: "0", with: "O")
  }

  private static func promoKind(_ san: String) -> Piece.Kind? {
    guard let i = san.firstIndex(of: "=") else { return nil }
    return Piece.Kind(rawValue: String(san[san.index(after: i)]))
  }

  private static func tag(_ name: String, in pgn: String) -> String? {
    guard let r = pgn.range(of: "[\(name) \""), let e = pgn[r.upperBound...].firstIndex(of: "\"") else { return nil }
    return String(pgn[r.upperBound..<e])
  }

  /// 棋譜本文 → SAN 清單
  static func sanTokens(_ pgn: String) -> [String] { moveTokens(pgn).map(\.san) }

  /// 棋譜本文 → 每一步的 SAN，以及這步後面註解裡的時鐘（[%clk 0:02:51.5]，剩下幾秒）
  static func moveTokens(_ pgn: String) -> [(san: String, clock: Double?)] {
    // 拿掉標頭行
    let body = pgn.split(separator: "\n").filter { !$0.hasPrefix("[") }.joined(separator: " ")
    var out: [(san: String, clock: Double?)] = []
    var word = "", comment = ""
    var brace = 0, paren = 0
    func flush() {
      defer { word = "" }
      var t = word
      // 去掉手數（12. 或 12...）
      if let r = t.range(of: "^[0-9]+\\.+", options: .regularExpression) { t.removeSubrange(r) }
      if t.isEmpty || t.hasPrefix("$") || ["1-0", "0-1", "1/2-1/2", "*"].contains(t) { return }
      // 去掉 !? 這類註記
      t = t.replacingOccurrences(of: "[!?]+$", with: "", options: .regularExpression)
      if !t.isEmpty { out.append((t, nil)) }
    }
    for ch in body {
      if brace > 0 {
        if ch == "}" {
          brace -= 1
          if brace == 0, paren == 0, !out.isEmpty, let c = clock(comment) { out[out.count - 1].clock = c }
          comment = ""
        } else { comment.append(ch) }
        continue
      }
      if ch == "{" { flush(); brace += 1; continue }
      if ch == "(" { flush(); paren += 1; continue }
      if ch == ")" { paren = max(0, paren - 1); continue }
      if paren > 0 { continue }
      if ch == " " || ch == "\t" { flush() } else { word.append(ch) }
    }
    flush()
    return out
  }

  /// [%clk 1:02:03.4] → 秒
  private static func clock(_ comment: String) -> Double? {
    guard let r = comment.range(of: #"%clk\s+([0-9:.]+)"#, options: .regularExpression) else { return nil }
    let v = comment[r].split(separator: " ").last ?? ""
    let parts = v.split(separator: ":").compactMap { Double($0) }
    return parts.reduce(0) { $0 * 60 + $1 }
  }

  /// 每一手想了幾秒：同一方上一手剩的時間 − 這一手剩的 + 加秒（第一手用起始時間）。沒有時鐘紀錄（每日棋、舊棋譜）就是 nil
  static func thinkTimes(pgn: String, timeControl: String) -> [Double?] {
    let clocks = moveTokens(pgn).map(\.clock)
    let tc = timeControl.split(separator: "+").compactMap { Double($0) }
    guard let base = tc.first, !timeControl.contains("/") else { return clocks.map { _ in nil } }
    let inc = tc.count > 1 ? tc[1] : 0
    return clocks.indices.map { k in
      guard let now = clocks[k] else { return nil }
      let prev = k >= 2 ? clocks[k - 2] : base
      guard let prev else { return nil }
      return max(0, prev - now + inc)
    }
  }

  /// 第 n 手走完的局面（0 = 開始局面）
  func fen(at n: Int) -> String { n == 0 ? startFen : plies[n - 1].fenAfter }
}

enum FEN {
  /// FEN 的棋子擺放 → [格子: "wK"]
  static func pieces(_ fen: String) -> [String: String] {
    var out: [String: String] = [:]
    let rows = fen.split(separator: " ").first?.split(separator: "/") ?? []
    for (r, row) in rows.enumerated() {
      var file = 0
      for ch in row {
        if let n = ch.wholeNumberValue { file += n; continue }
        let sq = "\(Character(UnicodeScalar(97 + file)!))\(8 - r)"
        out[sq] = (ch.isUppercase ? "w" : "b") + ch.uppercased()
        file += 1
      }
    }
    return out
  }

  static func sideToMove(_ fen: String) -> Side { fen.split(separator: " ").dropFirst().first == "b" ? .black : .white }

  static func valid(_ fen: String) -> Bool { fen.split(separator: " ").count >= 4 && Position(fen: fen) != nil }

  /// 這格的子能走到哪幾格（輪到它那一方才有）
  static func targets(fen: String, from: String) -> [String] {
    guard let pos = Position(fen: fen) else { return [] }
    let board = Board(position: pos)
    let sq = Square(from)
    guard let pc = pos.pieces.first(where: { $0.square == sq }), pc.color == pos.sideToMove else { return [] }
    return board.legalMoves(forPieceAt: sq).map(\.notation)
  }

  /// 被將死的王在哪一格（沒有將死就是 nil）：輪到的一方沒步可走、而且王被攻擊
  static func matedKing(_ fen: String) -> String? {
    guard !hasMoves(fen) else { return nil }
    let side = sideToMove(fen)
    guard let king = pieces(fen).first(where: { $0.value == (side == .white ? "wK" : "bK") })?.key else { return nil }
    // 換對方走，看對方能不能吃到這個王
    var parts = fen.split(separator: " ").map(String.init)
    guard parts.count >= 2 else { return nil }
    parts[1] = side == .white ? "b" : "w"
    if parts.count >= 4 { parts[3] = "-" }
    let flipped = parts.joined(separator: " ")
    for (sq, code) in pieces(flipped) where (code.first == "w") == (side != .white) {
      if targets(fen: flipped, from: sq).contains(king) { return king }
    }
    return nil
  }

  /// 輪到的一方還有沒有合法的步（將死、逼和就沒有）
  static func hasMoves(_ fen: String) -> Bool {
    guard let pos = Position(fen: fen) else { return false }
    let board = Board(position: pos)
    return pos.pieces.contains { $0.color == pos.sideToMove && !board.legalMoves(forPieceAt: $0.square).isEmpty }
  }

  /// 引擎的一條線（UCI）→ SAN，最多 n 步
  static func sanLine(fen: String, pv: [String], max n: Int = 8) -> [String] {
    var out: [String] = []
    var f = fen
    for u in pv.prefix(n) {
      guard let p = ChessLine.ply(fen: f, uci: u, index: 0) else { break }
      out.append(p.san)
      f = p.fenAfter
    }
    return out
  }

  static let pieceValue: [String: Int] = ["p": 1, "n": 3, "b": 3, "r": 5, "q": 9, "k": 0]

  /// UCI → SAN（給引擎的最佳步、第二選擇用）
  static func san(fen: String, uci: String) -> String? {
    guard uci.count >= 4, let pos = Position(fen: fen) else { return nil }
    var board = Board(position: pos)
    let s = Square(String(uci.prefix(2))), e = Square(String(uci.dropFirst(2).prefix(2)))
    guard var m = board.move(pieceAt: s, to: e) else { return nil }
    if uci.count == 5, let k = Piece.Kind(rawValue: uci.suffix(1).uppercased()) { m = board.completePromotion(of: m, to: k) }
    return m.san
  }
}
