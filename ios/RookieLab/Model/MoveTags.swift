import Foundation

/// 每一步「做了什麼」的名稱（捉雙、得子、防守、躲開攻擊…）：快速復盤播每一步時講，不只說好棋、壞棋。
/// 有網站解說（關鍵步）就用解說的標題（戰術名稱最準）；其他步照走法本身判斷，都在播放前算好
enum MoveTags {
  private static let value: [String: Int] = ["P": 1, "N": 3, "B": 3, "R": 5, "Q": 9, "K": 100]
  private static let zh: [String: String] = ["P": "兵", "N": "馬", "B": "象", "R": "車", "Q": "后", "K": "王"]

  static func tag(_ p: Ply, explanation e: ExplainJS.Explanation?) -> String {
    // 解說的標題：戰術名稱、送子、漏看威脅…（太籠統的「好棋」「局面變差」不用）
    if let h = e?.headline, !["好棋", "局面變差"].contains(h) { return h }
    if p.isCheckmate { return "將殺" }
    let before = FEN.pieces(p.fenBefore), after = FEN.pieces(p.fenAfter)
    guard let code = before[p.from] else { return "調整位置" }
    let me = String(code.prefix(1)), kind = String(code.suffix(1))
    let opp = me == "w" ? "b" : "w"
    if kind == "K" && abs(Int(p.from.unicodeScalars.first!.value) - Int(p.to.unicodeScalars.first!.value)) == 2 {
      return p.to.hasPrefix("g") ? "入堡（短）" : "入堡（長）"
    }
    if p.uci.count == 5 { return "升變" }
    if p.san.contains("+") { return p.captured != nil ? "吃子帶將軍" : "將軍" }
    if let c = p.captured?.uppercased() {
      let got = value[c] ?? 0, mine = value[kind] ?? 0
      let defended = attacked(p.fenAfter, p.to, by: opp)
      if got > mine || !defended { return "得子：吃\(zh[c] ?? "子")" }
      return got == mine ? "兌子" : "吃\(zh[c] ?? "子")"
    }
    // 你的子被攻擊的總值：走完變少就是防守；被攻擊的那顆走開就是躲開攻擊
    let threatened = { (fen: String) -> [String] in
      pieces(fen, of: me).filter { $0.value != "\(me)K" && attacked(fen, $0.key, by: opp) }.map(\.key)
    }
    let hitBefore = threatened(withSide(p.fenBefore, opp))
    let hitAfter = threatened(p.fenAfter)
    if hitBefore.contains(p.from) && !hitAfter.contains(p.to) { return "躲開攻擊：\(zh[kind] ?? "")走開" }
    let worth = { (sqs: [String], pos: [String: String]) in sqs.reduce(0) { $0 + (value[String(pos[$1]?.suffix(1) ?? "")] ?? 0) } }
    if worth(hitAfter, after) < worth(hitBefore, before) { return "防守" }
    // 走完攻擊對手比自己大的子
    let targets = FEN.targets(fen: withSide(p.fenAfter, me == "w" ? .white : .black), from: p.to)
    if let big = targets.compactMap({ after[$0] }).filter({ $0.hasPrefix(opp) && (value[String($0.suffix(1))] ?? 0) > (value[kind] ?? 0) && $0.suffix(1) != "K" }).first {
      return "攻擊對手的\(zh[String(big.suffix(1))] ?? "子")"
    }
    if p.moveNumber <= 12 {
      if ["N", "B"].contains(kind), p.from.hasSuffix(me == "w" ? "1" : "8") { return "出子" }
      if kind == "P", ["d4", "e4", "d5", "e5", "c4", "c5"].contains(p.to) { return "佔中央" }
    }
    if kind == "P", Grading.phase(moveNumber: p.moveNumber, fen: p.fenBefore) == .endgame { return "推兵" }
    return "調整位置"
  }

  // MARK: 小工具

  private static func pieces(_ fen: String, of color: String) -> [String: String] { FEN.pieces(fen).filter { $0.value.hasPrefix(color) } }

  /// 換成另一方走（看對手能攻擊哪裡）；吃過路兵的格子清掉
  private static func withSide(_ fen: String, _ side: String) -> String {
    var f = fen.split(separator: " ").map(String.init)
    guard f.count >= 4 else { return fen }
    f[1] = side; f[3] = "-"
    return f.joined(separator: " ")
  }
  private static func withSide(_ fen: String, _ side: Side) -> String { withSide(fen, side == .white ? "w" : "b") }

  /// 某一格是不是被這一方攻擊（用那一方的合法走法看吃不吃得到）
  private static func attacked(_ fen: String, _ sq: String, by color: String) -> Bool {
    let f = withSide(fen, color)
    return pieces(f, of: color).contains { FEN.targets(fen: f, from: $0.key).contains(sq) }
  }
}
