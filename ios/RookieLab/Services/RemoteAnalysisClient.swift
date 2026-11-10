import Foundation
import CryptoKit
import Security
import SwiftUI

/// Private opt-in pilot: only the whole-game first pass uses HTTPS. Interactive searches stay local.
enum RemoteAnalysisClient {
  static let origin = URL(string: "https://srv2114137.hstgr.cloud/rookielab-analysis/")!
  static let cacheSuffix = "-remote-lite-v2"
  static func cacheID(_ game: GameSummary) -> String {
    game.id + cacheSuffix + "-" + SHA256.hash(data: Data(game.pgn.utf8)).map { String(format: "%02x", $0) }.joined()
  }
  // The remote pilot is paused. Previously paired devices also use on-device review.
  static let enabled = false
  private static let service = "io.rookielab.remote-analysis"
  static var token: String? {
    let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                            kSecAttrAccount as String: "pilot", kSecReturnData as String: true]
    var value: CFTypeRef?
    guard SecItemCopyMatching(q as CFDictionary, &value) == errSecSuccess, let data = value as? Data else { return nil }
    return String(data: data, encoding: .utf8)
  }
  static func disconnect() {
    SecItemDelete([kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                   kSecAttrAccount as String: "pilot"] as CFDictionary)
    UserDefaults.standard.set(false, forKey: "remoteAnalysis.enabled")
  }
  struct PilotError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
  }
  private static func request(_ path: String, body: Data, authenticated: Bool) async throws -> Data {
    var r = URLRequest(url: origin.appendingPathComponent(path), timeoutInterval: 150)
    r.httpMethod = "POST"; r.httpBody = body
    r.setValue("application/json", forHTTPHeaderField: "Content-Type")
    if authenticated {
      guard let token else { throw PilotError(message: "請先在設定配對遠端復盤") }
      r.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
    }
    let (data, response) = try await URLSession.shared.data(for: r)
    try Task.checkCancellation()
    let code = (response as? HTTPURLResponse)?.statusCode ?? 0
    guard code == 200 else {
      throw PilotError(message: code == 401 ? "遠端配對已失效，請重新配對" : code == 429 ? "遠端復盤忙碌，請稍後重試" : "遠端復盤暫時無法使用（\(code)）")
    }
    guard data.count <= 4_000_000 else { throw PilotError(message: "遠端結果過大") }
    return data
  }
  static func pair(code: String) async throws {
    let data = try await request("v1/pair", body: JSONSerialization.data(withJSONObject: ["code": code.trimmingCharacters(in: .whitespacesAndNewlines)]), authenticated: false)
    struct Pair: Decodable { let token: String }
    let value = try JSONDecoder().decode(Pair.self, from: data).token
    guard value.count >= 32 else { throw PilotError(message: "配對回應無效") }
    disconnect()
    let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                            kSecAttrAccount as String: "pilot", kSecValueData as String: Data(value.utf8),
                            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly]
    guard SecItemAdd(q as CFDictionary, nil) == errSecSuccess else { throw PilotError(message: "無法儲存配對") }
    UserDefaults.standard.set(true, forKey: "remoteAnalysis.enabled")
  }
  struct Response: Decodable {
    let schema: Int
    let pgnHash: String
    let engine: String
    let requestedDepth: Int
    let plies: Int
    let seconds: Double
    let positions: [Row]
  }
  struct Row: Decodable {
    let ply: Int
    let fen: String
    let cpWhite: Int?
    let mateWhite: Int?
    let depth: Int?
    let pv: [String]?
    let terminal: String?
  }
  /// Reconstruct PGN from the parsed legal mainline; no names, links, clocks or comments leave the phone.
  static func pgn(_ line: ChessLine) -> String {
    let tags = "[SetUp \"1\"]\n[FEN \"\(line.startFen)\"]\n\n"
    return tags + line.plies.map { "\($0.moveNumber)\($0.mover == .white ? "." : "...") \($0.san)" }.joined(separator: " ") + " *"
  }
  static func validate(_ result: Response, pgn: String, line: ChessLine) throws -> [[EngineLine]?] {
    let hash = SHA256.hash(data: Data(pgn.utf8)).map { String(format: "%02x", $0) }.joined()
    guard result.schema == 2, result.pgnHash == hash, !result.engine.isEmpty,
          result.requestedDepth == AnalysisStore.quickDepth, result.plies == line.plies.count,
          result.positions.count == line.plies.count + 1, result.seconds.isFinite, result.seconds >= 0 else {
      throw PilotError(message: "遠端結果與棋譜不符")
    }
    return try result.positions.enumerated().map { k, row in
      // En passant FEN may use either the legal-capture or raw-target convention.
      func normalized(_ fen: String) -> String { fen.split(separator: " ").enumerated().filter { $0.offset != 3 }.map { String($0.element) }.joined(separator: " ") }
      guard row.ply == k, normalized(row.fen) == normalized(line.fen(at: k)) else { throw PilotError(message: "遠端局面順序不符") }
      if let terminal = row.terminal {
        guard k == line.plies.count, ["1-0", "0-1", "1/2-1/2"].contains(terminal) else { throw PilotError(message: "無效終局") }
        return []
      }
      guard (row.cpWhite == nil) != (row.mateWhite == nil), (row.depth ?? 0) >= AnalysisStore.quickDepth,
            let pv = row.pv, !pv.isEmpty, pv.count <= 256,
            (-1_000_000...1_000_000).contains(row.cpWhite ?? 0), (-10_000...10_000).contains(row.mateWhite ?? 0) else { throw PilotError(message: "遠端分析未完成") }
      var fen = line.fen(at: k)
      for uci in pv {
        guard let step = ChessLine.ply(fen: fen, uci: uci, index: 0) else { throw PilotError(message: "遠端候選走法無效") }
        fen = step.fenAfter
      }
      let sign = line.fen(at: k).split(separator: " ")[1] == "w" ? 1 : -1
      return [EngineLine(cp: row.cpWhite.map { $0 * sign }, mate: row.mateWhite.map { $0 * sign }, pv: pv)]
    }
  }
  static func firstPass(_ line: ChessLine) async throws -> [[EngineLine]?] {
    let text = pgn(line)
    let data = try await request("v1/analyze", body: JSONSerialization.data(withJSONObject: ["pgn": text, "depth": AnalysisStore.quickDepth]), authenticated: true)
    return try validate(JSONDecoder().decode(Response.self, from: data), pgn: text, line: line)
  }
}

struct RemoteAnalysisSettings: View {
  @AppStorage("remoteAnalysis.enabled") private var enabled = false
  @State private var code = ""
  @State private var status = ""
  @State private var pairing = false
  var body: some View {
    Form {
      Section {
        Toggle("遠端復盤試驗", isOn: $enabled).disabled(RemoteAnalysisClient.token == nil)
        Text("整局初步評估在遠端執行；精算、深入分析與延伸解說仍使用手機引擎。遠端模式需要網路。")
          .font(.footnote).foregroundStyle(.secondary)
      }
      Section("配對") {
        SecureField("測試配對碼", text: $code).textInputAutocapitalization(.never).autocorrectionDisabled()
        Button("連接伺服器") {
          pairing = true
          Task {
            defer { pairing = false }
            do { try await RemoteAnalysisClient.pair(code: code); enabled = true; code = ""; status = "已連接" }
            catch { status = error.localizedDescription }
          }
        }.disabled(pairing || code.isEmpty)
        if !status.isEmpty { Text(status).font(.footnote) }
        Button("中斷配對", role: .destructive) { RemoteAnalysisClient.disconnect(); enabled = false; status = "" }
      }
      Section("資料處理") {
        Text("啟用後會將去除姓名、帳號、連結與註解的棋譜，透過 HTTPS 傳至自有伺服器運算。棋譜與結果不持久保存；配對憑證存於此裝置鑰匙圈，七天到期，伺服器重啟需重新配對。")
      }
    }.trackedScreen("remote_settings").navigationTitle("遠端復盤試驗")
  }
}
