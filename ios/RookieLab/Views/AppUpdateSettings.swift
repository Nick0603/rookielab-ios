import StoreKit
import SwiftUI

struct AppUpdateSettings: View {
  @State private var updates = AppUpdateService.shared
  var body: some View {
    Form {
      Section {
        LabeledContent("目前版本", value: "\(updates.version) (\(updates.build))")
        if !updates.status.isEmpty { Text(updates.status).foregroundStyle(.secondary) }
        Button("檢查更新") { Task { await updates.refresh(force: true) } }.disabled(updates.busy)
        Link("前往更新", destination: updates.updateURL)
      }
    }.navigationTitle("App 版本與更新").task { await updates.refresh() }
  }
}

struct RequiredAppUpdateView: View {
  @State private var updates = AppUpdateService.shared
  var body: some View {
    NavigationStack {
      ScrollView {
        VStack(alignment: .leading, spacing: 24) {
          Image(systemName: "arrow.down.app").font(.largeTitle).foregroundStyle(Brand.orange)
          Text("請更新後再開始新分析").font(.title.bold())
          Text("目前版本 \(updates.version)，需要 \(updates.minimum) 或更新版本。")
          if !updates.reason.isEmpty { Text(updates.reason) }
          Link("前往更新", destination: updates.updateURL).buttonStyle(.borderedProminent).tint(Brand.orange)
          Button("重新檢查") { Task { await updates.refresh(force: true) } }.disabled(updates.busy)
          if !updates.status.isEmpty { Text(updates.status).font(.footnote).foregroundStyle(.secondary) }
          NavigationLink("查看過往分析") { ArchivedAnalysesView() }
          Button("管理訂閱") { Task { if let scene = UIApplication.shared.connectedScenes.first as? UIWindowScene { try? await AppStore.showManageSubscriptions(in: scene) } } }
          Button("恢復購買") { Task { await Premium.shared.restore() } }
          Link("聯絡我們", destination: URL(string: "https://rookielab.io/feedback/")!)
        }.padding(28).frame(maxWidth: 600, alignment: .leading)
      }.navigationTitle("App 更新")
    }.accessibilityIdentifier("required-app-update")
  }
}

private struct ArchivedAnalysesView: View {
  @State private var games: [GameSummary] = []
  var body: some View {
    List(games) { game in NavigationLink(game.versusTitle) { ReviewView(game: game, archivedOnly: true) } }
      .navigationTitle("過往分析")
      .task {
        let all = ImportedGames.load() + AccountStore.all().flatMap { GameCache.load($0) ?? [] }
        var seen = Set<String>()
        games = all.filter { seen.insert($0.id).inserted && AnalysisStore.load($0.id) != nil }.sorted { $0.endedAt > $1.endedAt }
      }
  }
}
