import SwiftUI

struct SingleGameImportMethods: View {
  @Environment(AppModel.self) private var app
  @Environment(\.dismiss) private var dismiss
  @State private var link = ""
  @State private var pgn = false
  @State private var error: String?
  var body: some View {
    NavigationStack {
      Form {
        Section("對局連結") {
          TextField("貼上 Chess.com 或 Lichess 對局網址", text: $link)
            .textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.URL)
            .accessibilityIdentifier("single-game-link-input")
          PasteButton(payloadType: String.self) { strings in link = strings.joined(separator: " "); error = nil }
          Text("先複製棋局網址，再貼到上方；也可以直接輸入。剪貼簿沒有文字時，貼上按鈕不會啟用。")
            .font(.footnote).foregroundStyle(.secondary)
          if let error { Text(error).foregroundStyle(.red) }
          Button("匯入對局連結") {
            guard GameLink.find(in: link) != nil else {
              error = String(localized: "請輸入 Chess.com 或 Lichess 的棋局網址；PGN 請使用下方入口。")
              return
            }
            let value = link; dismiss()
            Task { await app.importLink(value) }
          }.accessibilityIdentifier("single-game-link-submit")
        }
        Section {
          Button("貼上 PGN 棋譜") { pgn = true }
          NavigationLink("從棋站分享一局") { SingleGameShareHelp() }
        }
      }.trackedScreen("import_methods").navigationTitle("匯入方式").navigationBarTitleDisplayMode(.inline)
        .toolbar { ToolbarItem(placement: .cancellationAction) { Button("關閉") { dismiss() } } }
        .sheet(isPresented: $pgn) { ImportPGNView() }
    }
  }
}
