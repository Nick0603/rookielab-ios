import SwiftUI

struct GamesHubView: View {
  var body: some View { GamesView() }
}

struct ImportPGNView: View {
  @Environment(AppModel.self) private var app
  @Environment(\.dismiss) private var dismiss
  @State private var text = Self.prefill
  @State private var side = Side.white
  /// 商店截圖用：-prefillPGN "<棋譜>" 預先填好（模擬器鍵盤打長棋譜會掉字）
  private static var prefill: String {
    #if DEBUG
    let args = ProcessInfo.processInfo.arguments
    if let i = args.firstIndex(of: "-prefillPGN"), args.indices.contains(i + 1) { return args[i + 1] }
    #endif
    return ""
  }
  @State private var error = false
  var body: some View {
    NavigationStack {
      Form {
        Section("貼上完整棋譜") {
          PasteButton(payloadType: String.self) { values in text = values.joined(separator: "\n") }
            .accessibilityIdentifier("single-game-paste-pgn")
          TextEditor(text: $text).font(.footnote.monospaced()).frame(minHeight: 220)
            .autocorrectionDisabled().textInputAutocapitalization(.never).keyboardType(.asciiCapable)
        }
        Section { Picker("你執哪一方", selection: $side) { Text("執白").tag(Side.white); Text("執黑").tag(Side.black) }.pickerStyle(.segmented) } footer: { Text("分析會以選定的一方呈現。") }
        if error { Text("這段棋譜無法完整讀取，請確認是合法的 PGN。").foregroundStyle(.red) }
      }
      .trackedScreen("import_pgn").navigationTitle("匯入 PGN").navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
        ToolbarItem(placement: .confirmationAction) { Button("匯入") {
          if let game = ImportedGames.parse(text, side: side) { app.addImported(game); dismiss() } else { error = true }
        }.disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) }
      }
    }
  }
}
