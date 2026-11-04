import Foundation
import SwiftUI

enum Platform: String, Codable, CaseIterable, Identifiable {
  case chesscom, lichess
  var id: String { rawValue }
  var name: String { self == .chesscom ? "Chess.com" : "Lichess" }
}

enum GameResult: String, Codable { case win, loss, draw }
enum Side: String, Codable { case white, black }

/// 一局的摘要（跟網站的 GameSummary 同一份資料）
struct GameSummary: Identifiable, Codable, Hashable {
  let id: String
  let platform: Platform
  let endedAt: Date
  let color: Side
  let opponent: String
  let myRating: Int?
  let opponentRating: Int?
  let result: GameResult
  let timeClass: String
  let timeControl: String
  let pgn: String
  let url: URL?
  /// 我這一方的結束方式（chess.com 的結果代碼：checkmated、resigned、timeout、win…；Lichess 轉成同一套）
  var termination: String? = nil
  /// 對手那一方的結束方式（resigned＝對手投降）；舊的快取沒有這欄，chess.com 的再看棋譜標頭
  var opponentEnd: String? = nil

  /// 導覽列標題：執白／執黑 vs 對手
  var versusTitle: String { color == .white ? String(localized: "執白 vs \(opponent)") : String(localized: "執黑 vs \(opponent)") }

  /// 使用者時區的日期
  var dateText: String { endedAt.formatted(date: .numeric, time: .omitted) }

  /// PGN 標頭
  func tag(_ name: String) -> String? {
    guard let r = pgn.range(of: "[\(name) \""), let e = pgn[r.upperBound...].firstIndex(of: "\"") else { return nil }
    return String(pgn[r.upperBound..<e])
  }

  /// 開局原文：chess.com 放在 ECOUrl，Lichess 放在 Opening
  var openingRaw: String? {
    if let u = tag("ECOUrl"), let last = u.split(separator: "/").last {
      return (String(last).removingPercentEncoding ?? String(last)).replacingOccurrences(of: "-", with: " ")
    }
    return tag("Opening")
  }

  /// 對手投降（我贏）
  var opponentResigned: Bool {
    result == .win && (opponentEnd == "resigned" || (tag("Termination") ?? "").range(of: "resignation", options: .caseInsensitive) != nil)
  }

  /// 超時輸的（chess.com「won on time」、Lichess「Time forfeit」）
  var lostOnTime: Bool { result == .loss && (termination == "timeout" || (tag("Termination") ?? "").range(of: "on time|time forfeit", options: [.regularExpression, .caseInsensitive]) != nil) }
}

struct Account: Codable, Hashable, Identifiable {
  let platform: Platform
  let username: String
  var id: String { "\(platform.rawValue):\(username.lowercased())" }
}

/// 每一步的評級：跟網站 src/lib/analysis/classification.ts 同一套（chess.com 的 10 種）
enum MoveClass: String, Codable, CaseIterable {
  case brilliant, great, best, excellent, good, book, inaccuracy, mistake, miss, blunder

  var zh: String {
    switch self {
    case .brilliant: String(localized: "傑出")
    case .great: String(localized: "好棋")
    case .best: String(localized: "最佳")
    case .excellent: String(localized: "優秀")
    case .good: String(localized: "不錯")
    case .book: String(localized: "開局理論")
    case .inaccuracy: String(localized: "不精確")
    case .mistake: String(localized: "失誤")
    case .miss: String(localized: "錯失良機")
    case .blunder: String(localized: "嚴重失誤")
    }
  }

  var color: Color {
    switch self {
    case .brilliant: Color(hex: 0x1BACA6)
    case .great: Color(hex: 0x5C8BB0)
    case .best: Color(hex: 0x81B64C)
    case .excellent: Color(hex: 0x2FA37C)
    case .good: Color(hex: 0x8FA382)
    case .book: Color(hex: 0xA88865)
    case .inaccuracy: Color(hex: 0xE8B33D)
    case .mistake: Color(hex: 0xF08C35)
    case .miss: Color(hex: 0xFF6F61)
    case .blunder: Color(hex: 0xE5392A)
    }
  }

  /// 徽章裡的符號；沒有符號的用 SF Symbol
  var symbol: String? {
    switch self {
    case .brilliant: "!!"
    case .great: "!"
    case .inaccuracy: "?!"
    case .mistake: "?"
    case .blunder: "??"
    default: nil
    }
  }

  var systemImage: String {
    switch self {
    case .best: "star.fill"
    case .excellent: "hand.thumbsup.fill"
    case .good: "checkmark"
    case .book: "book.fill"
    case .miss: "xmark"
    default: "circle"
    }
  }

  /// 復盤播放時會停下來的「關鍵步」
  var isKey: Bool { [.brilliant, .great, .mistake, .miss, .blunder].contains(self) }
  var isBad: Bool { [.mistake, .miss, .blunder].contains(self) }
}

/// 引擎的一條線（走棋方視角）
struct EngineLine: Hashable, Codable {
  var cp: Int?
  var mate: Int?
  var pv: [String]
  var best: String? { pv.first }
}

/// 一步棋分析完的結果
struct MoveRecord: Hashable, Codable {
  let ply: Int
  let san: String
  let uci: String
  let mover: Side
  let cls: MoveClass
  /// 走的那一方視角的勝率
  let winBefore: Double
  let winAfter: Double
  let accuracy: Double
  /// 該走的（引擎第一名）與也不錯的第二選擇（UCI）
  let bestUci: String?
  let bestSan: String?
  let altUci: String?
  let altSan: String?
}

extension Color {
  init(hex: UInt32, opacity: Double = 1) {
    self.init(.sRGB, red: Double((hex >> 16) & 0xFF) / 255, green: Double((hex >> 8) & 0xFF) / 255, blue: Double(hex & 0xFF) / 255, opacity: opacity)
  }
}

/// 品牌色：跟標誌（棋格＋橘色箭頭，src/components/BrandMark.tsx）同一組。
/// 橘＝主要按鈕與重點（標誌的箭頭）；深青＝第二品牌色；棋盤用標誌的兩種青色調
enum Brand {
  static let orange = Color(hex: 0xE8711F)
  static let teal = Color(hex: 0x1F6F78)
  static let tealLight = Color(hex: 0xCFE3E5)
  static let ink = Color(hex: 0x2A2522)
  static let paper = Color(hex: 0xFFF7EF)
  static let cream = Color(hex: 0xF6F1EA)
  static let lightSquare = Color(hex: 0xE2EEEF)
  static let darkSquare = Color(hex: 0x6FA2A8)
  static let bestArrow = Color(hex: 0x22C55E)
  static let altArrow = Color(hex: 0xBBF7D0, opacity: 0.85)
}
