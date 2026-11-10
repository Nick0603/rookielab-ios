import XCTest
import CryptoKit
@testable import RookieLab

final class RemoteAnalysisTests: XCTestCase {
  private let fixture = #"{"schema":2,"pgnHash":"961d530b0dbe1691304f573e8d0fe330d0b9ab1d5c13952dc435afe4991299ff","engine":"Stockfish 19 Lite WASM","seconds":1.815,"requestedDepth":12,"plies":6,"positions":[{"ply":0,"fen":"rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1","cpWhite":31,"mateWhite":null,"depth":12,"nodes":12743,"pv":["e2e4","c7c5","b1c3","b8c6","g1f3","e7e6","d2d4","c5d4","f3d4","g8f6","c1g5"]},{"ply":1,"fen":"rnbqkbnr/pppppppp/8/8/4P3/8/PPPP1PPP/RNBQKBNR b KQkq - 0 1","cpWhite":34,"mateWhite":null,"depth":12,"nodes":23297,"pv":["e7e5","g1f3","b8c6","d2d4","e5d4","f3d4","g8f6","d4c6","b7c6","e4e5","d8e7","d1d4","f6d5"]},{"ply":2,"fen":"rnbqkbnr/pppp1ppp/8/4p3/4P3/8/PPPP1PPP/RNBQKBNR w KQkq - 0 2","cpWhite":28,"mateWhite":null,"depth":12,"nodes":31743,"pv":["g1f3","b8c6","b1c3","g8f6","d2d4","e5d4","f3d4","f8b4","d4c6","b7c6","f1d3","d7d5","e4d5","d8e7","d1e2","c6d5"]},{"ply":3,"fen":"rnbqkbnr/pppp1ppp/8/4p3/4P3/5N2/PPPP1PPP/RNBQKB1R b KQkq - 1 2","cpWhite":27,"mateWhite":null,"depth":12,"nodes":40763,"pv":["g8f6","b1c3","b8c6","d2d4","e5d4","f3d4","f8b4","d4c6","d7c6"]},{"ply":4,"fen":"r1bqkbnr/pppp1ppp/2n5/4p3/4P3/5N2/PPPP1PPP/RNBQKB1R w KQkq - 2 3","cpWhite":34,"mateWhite":null,"depth":12,"nodes":22033,"pv":["d2d4","e5d4","f3d4","g8f6","d4c6","d7c6","d1d8","e8d8","b1c3","f8b4","c1g5"]},{"ply":5,"fen":"r1bqkbnr/pppp1ppp/2n5/1B2p3/4P3/5N2/PPPP1PPP/RNBQK2R b KQkq - 3 3","cpWhite":30,"mateWhite":null,"depth":12,"nodes":55902,"pv":["a7a6","b5a4","g8f6","e1g1","b7b5","a4b3","c8b7","f1e1"]},{"ply":6,"fen":"r1bqkbnr/1ppp1ppp/p1n5/1B2p3/4P3/5N2/PPPP1PPP/RNBQK2R w KQkq - 0 4","cpWhite":31,"mateWhite":null,"depth":12,"nodes":42774,"pv":["b5a4","g8f6","d2d3","d7d6","e1g1","c8d7","c2c3","c6e7","a4d7","d8d7","a2a4","e7g6"]}]}"#
  private func response(_ line: ChessLine, change: (inout [String: Any]) -> Void = { _ in }) throws -> RemoteAnalysisClient.Response {
    var value = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(fixture.utf8)) as? [String: Any])
    value["pgnHash"] = SHA256.hash(data: Data(RemoteAnalysisClient.pgn(line).utf8)).map { String(format: "%02x", $0) }.joined()
    change(&value)
    return try JSONDecoder().decode(RemoteAnalysisClient.Response.self, from: JSONSerialization.data(withJSONObject: value))
  }
  func testLiveFixtureMapsBlackScoreAndLegalPV() throws {
    let line = try XCTUnwrap(ChessLine(pgn: "1. e4 e5 2. Nf3 Nc6 3. Bb5 a6 *"))
    let result = try response(line)
    let evals = try RemoteAnalysisClient.validate(result, pgn: RemoteAnalysisClient.pgn(line), line: line)
    XCTAssertEqual(evals.count, 7)
    XCTAssertEqual(evals[1]?.first?.cp, result.positions[1].cpWhite.map { -$0 })
    XCTAssertEqual(evals[0]?.first?.cp, result.positions[0].cpWhite)
  }
  func testRejectsWrongHashAndIncompleteAndIllegalPV() throws {
    let line = try XCTUnwrap(ChessLine(pgn: "1. e4 e5 2. Nf3 Nc6 3. Bb5 a6 *"))
    let pgn = RemoteAnalysisClient.pgn(line)
    let badHash = try response(line) { $0["pgnHash"] = "wrong" }
    XCTAssertThrowsError(try RemoteAnalysisClient.validate(badHash, pgn: pgn, line: line))
    let missing = try response(line) { $0["positions"] = [] }
    XCTAssertThrowsError(try RemoteAnalysisClient.validate(missing, pgn: pgn, line: line))
    for edit in ["depth", "pv", "cpWhite", "fen"] {
      let bad = try response(line) { value in
        var rows = value["positions"] as! [[String: Any]]
        if edit == "depth" { rows[0][edit] = 1 }
        if edit == "pv" { rows[0][edit] = ["e2e5"] }
        if edit == "cpWhite" { rows[0][edit] = Int.min }
        if edit == "fen" { rows[0][edit] = line.fen(at: 1) }
        value["positions"] = rows
      }
      XCTAssertThrowsError(try RemoteAnalysisClient.validate(bad, pgn: pgn, line: line), edit)
    }
  }
  func testOnlyMainlineAndStartingPositionLeavePhone() throws {
    let line = try XCTUnwrap(ChessLine(pgn: "[White \"Private player\"]\n[Site \"https://private.example\"]\n\n1. e4 {private comment} e5 *"))
    let text = RemoteAnalysisClient.pgn(line)
    XCTAssertFalse(text.contains("Private")); XCTAssertFalse(text.contains("private"))
    let reconstructed = try XCTUnwrap(ChessLine(pgn: text))
    XCTAssertEqual(reconstructed.plies.map(\.uci), line.plies.map(\.uci))
    XCTAssertEqual(reconstructed.startFen, line.startFen)
  }
}
