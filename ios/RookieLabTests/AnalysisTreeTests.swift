import XCTest
@testable import RookieLab

/// 深入分析的走法樹：往下一步照這個局面最早的走法；走不同的棋開分支；分支走到底再用引擎
@MainActor
final class AnalysisTreeTests: XCTestCase {
  private func line(_ ucis: [String]) -> [Ply] {
    var f = AnalysisModel.standard
    return ucis.enumerated().map { i, u in let p = ChessLine.ply(fen: f, uci: u, index: i)!; f = p.fenAfter; return p }
  }

  func testBranchAndReturnToOriginal() {
    let game = line(["e2e4", "e7e5", "g1f3", "b8c6"])
    let m = AnalysisModel(plies: game, at: 2)
    XCTAssertEqual(m.next?.uci, "g1f3", "預設照原本的對局")
    m.play(uci: "d2d4")                       // 第 3 手開分支
    XCTAssertEqual(m.plies.map(\.uci), ["e2e4", "e7e5", "d2d4"])
    m.play(uci: "e5d4")                       // 分支裡再走一步
    m.step(-1); m.step(-1)                    // 退回分岔點
    XCTAssertEqual(m.cursor, 2)
    m.step(1)
    XCTAssertEqual(m.last?.uci, "g1f3", "回到分岔點往下，恢復原本的對局")
    m.step(1)
    XCTAssertEqual(m.last?.uci, "b8c6")
  }

  func testNestedBranchFollowsEarliestOfThatBranch() {
    let m = AnalysisModel(plies: line(["e2e4", "e7e5"]), at: 1)
    m.play(uci: "c7c5")                       // 分支 A：1…c5
    m.play(uci: "g1f3")                       // A 的後續 2.Nf3
    m.step(-1)                                // 回到 1…c5 之後
    m.play(uci: "b1c3")                       // A 裡再岔出 2.Nc3
    m.step(-1)                                // 回到 1…c5 之後
    m.step(1)
    XCTAssertEqual(m.last?.uci, "g1f3", "分支裡也照最早走的那一步（不是原本對局）")
    m.step(-1); m.step(-1)                    // 回到 1.e4 之後
    m.step(1)
    XCTAssertEqual(m.last?.uci, "e7e5", "最上層恢復原本的對局")
  }

  func testPlayingAnExistingMoveRejoinsThatLine() {
    let m = AnalysisModel(plies: line(["e2e4", "e7e5", "g1f3"]), at: 1)
    m.play(uci: "c7c5")
    m.step(-1)
    m.play(uci: "e7e5")                       // 自己走回原本的步
    XCTAssertEqual(m.plies.map(\.uci), ["e2e4", "e7e5", "g1f3"], "接回原本那條，後面的步都在")
  }
}
