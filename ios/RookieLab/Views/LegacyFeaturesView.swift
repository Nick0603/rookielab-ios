import SwiftUI

/// Existing routes and learning data stay reachable without competing with the first-run task.
struct LegacyFeaturesView: View {
  var body: some View {
    List {
      Section {
        NavigationLink("開局課程") { OpeningCoursesView() }
        NavigationLink("練習與複習") { PracticeView() }
        NavigationLink("跨局報告") { ReportView() }
        NavigationLink("自由分析板") { AnalysisBoardView() }
      } footer: {
        Text("原有課程、練習進度與複習排程保留在這裡。")
      }
    }.navigationTitle("先前版本功能")
  }
}

struct LegacyDestination: View {
  let tab: AppTab
  @ViewBuilder var body: some View {
    switch tab {
    case .practice: PracticeView()
    case .openings: OpeningCoursesView()
    case .report: ReportView()
    case .analysis: AnalysisBoardView()
    default: LegacyFeaturesView()
    }
  }
}

struct SingleGameShareHelp: View {
  var body: some View {
    List {
      Section("分享連結") {
        Text("在 Chess.com 或 Lichess 打開一局，點分享，選 Rookie Lab。請分享對局連結，不是圖片或 GIF。")
      }
      Section("貼上棋譜") {
        Text("在「復盤」點「匯入一局」，貼上完整 PGN，選擇你執白或執黑。")
      }
    }.navigationTitle("分享對局")
  }
}
