import XCTest
@testable import RookieLab

/// 產生殘局教材的示範棋路：雙方都照引擎下（寫教材用，印到檔案）
final class LessonLineTests: XCTestCase {
  func testPrintLines() async throws {
    var out = ""
    for e in EndgameBasic.all {
      var fen = e.fen
      var sans: [String] = [], ucis: [String] = []
      for _ in 0..<40 {
        guard FEN.hasMoves(fen), let u = await StockfishService.shared.analyse(fen: fen, nodes: 400_000, multipv: 1, priority: .interactive).first?.best,
              let p = ChessLine.ply(fen: fen, uci: u, index: 0) else { break }
        sans.append(p.san); ucis.append(u); fen = p.fenAfter
        if p.isCheckmate { break }
        if FEN.pieces(fen).values.contains(where: { $0 == "wQ" }) && e.key == "kp" { break }
      }
      out += "== \(e.key) \(e.fen)\n\(sans.joined(separator: " "))\n\(ucis.joined(separator: ","))\n"
    }
    try? out.write(toFile: NSTemporaryDirectory() + "lessons.txt", atomically: true, encoding: .utf8)
  }
}

/// 教材的每一步都要是合法的
final class EndgameLessonTests: XCTestCase {
  func testLessonsLegal() throws {
    for l in EndgameLesson.all {
      let e = try XCTUnwrap(EndgameBasic.all.first { $0.key == l.key })
      var fen = e.fen
      for (i, s) in l.steps.enumerated() {
        let p = try XCTUnwrap(ChessLine.ply(fen: fen, uci: s.uci, index: 0), "\(l.key) 第 \(i + 1) 步 \(s.uci) 不合法 @ \(fen)")
        fen = p.fenAfter
      }
    }
  }
}
