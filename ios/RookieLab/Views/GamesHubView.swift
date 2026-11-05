import SwiftUI

struct GamesHubView: View {
  @Environment(AppModel.self) private var app
  @State private var importPGN = false
  var body: some View {
    @Bindable var app = app
    VStack(spacing: 0) {
      Picker("對局或報告", selection: $app.showReport) { Text("對局").tag(false); Text("報告").tag(true) }.pickerStyle(.segmented).padding(.horizontal).padding(.vertical, 8)
      Menu {
        Button("匯入的對局") { app.useImported() }
        ForEach(app.accounts) { account in Button("\(account.platform.name) · \(account.username)") { app.use(account) } }
      } label: { Label(app.usingImported ? String(localized: "匯入的對局") : app.account?.username ?? String(localized: "尚無對局"), systemImage: "folder").font(.caption).padding(.bottom, 8) }
      if (app.games.isEmpty || (app.showReport && app.reportGames.isEmpty)) && !app.loading {
        ContentUnavailableView {
          Label(app.showReport ? String(localized: "先加入一些對局") : String(localized: "看懂你下過的棋"), systemImage: "square.and.arrow.down")
        } description: {
          Text(app.showReport ? String(localized: "匯入對局或加入棋站帳號後，就能整理自己的報告。") : String(localized: "不需要登入。貼上 PGN、分享對局，或選擇加入公開棋站帳號。"))
        } actions: {
          Button("匯入 PGN") { importPGN = true }.buttonStyle(.borderedProminent).tint(Brand.orange)
          NavigationLink("加入棋站帳號") { OpeningAccountView() }
          Button("先學開局") { app.tab = .openings }
        }
      } else if app.showReport { ReportView().id(app.sourceID) }
      else { GamesView().id(app.sourceID) }
    }
    .navigationTitle("對局")
    .toolbar { ToolbarItem(placement: .topBarTrailing) { Button { importPGN = true } label: { Label("匯入 PGN", systemImage: "doc.badge.plus") } } }
    .sheet(isPresented: $importPGN) { ImportPGNView() }
  }
}

struct ImportPGNView: View {
  @Environment(AppModel.self) private var app
  @Environment(\.dismiss) private var dismiss
  @State private var text = ""
  @State private var side = Side.white
  @State private var error = false
  var body: some View {
    NavigationStack {
      Form {
        Section("貼上完整棋譜") { TextEditor(text: $text).font(.footnote.monospaced()).frame(minHeight: 220) }
        Section { Picker("你執哪一方", selection: $side) { Text("執白").tag(Side.white); Text("執黑").tag(Side.black) }.pickerStyle(.segmented) } footer: { Text("報告會以選定的一方計算。不同玩家的棋譜請勿混為自己的表現。") }
        if error { Text("這段棋譜無法完整讀取，請確認是合法的 PGN。").foregroundStyle(.red) }
      }
      .navigationTitle("匯入 PGN").navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
        ToolbarItem(placement: .confirmationAction) { Button("匯入") {
          if let game = ImportedGames.parse(text, side: side) { app.addImported(game); dismiss() } else { error = true }
        }.disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) }
      }
    }
  }
}
