/// Three static chess decorations shared with the web and native asset generator.
enum ChessAccentAsset {
  static func name(_ state: String) -> String {
    switch state {
    case "happy", "cheer": "accent-rook"
    case "think", "teach", "point": "accent-bishop"
    default: "accent-pawn"
    }
  }
}
