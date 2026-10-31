import SwiftUI

/// 復盤前的載入畫面：先把整局分析完（每一步的評級、解說都備好），播放時才不會卡。
/// 小橘在想、進度條、輪流換的說明，讓人知道在做什麼、大概多久
struct AnalyzingView: View {
  /// nil：不知道進度（載入對局），只放動畫
  let progress: Double?
  let status: String
  let plies: Int?
  var note = "分析完會從頭快速播，停在重點分析"
  var tips = AnalyzingView.gameTips
  @State private var bob = false
  @State private var tip = 0

  static let reportTips = ["正在看每一局…", "找出你最常丟分的地方…", "整理開局、中局、殘局的表現…", "挑出最值得練的一件事…"]
  static let gameTips = ["正在看每一步棋…", "找出好棋與錯失的機會…", "準備每一步的解說…", "挑出這局最值得練的重點…"]

  var body: some View {
    VStack(spacing: 18) {
      Spacer()
      Image("coach-think").resizable().scaledToFit().frame(width: 130, height: 130)
        .offset(y: bob ? -6 : 6)
        .animation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true), value: bob)
      Text(status.hasPrefix("第一次") || status.hasPrefix("準備") || status.hasPrefix("載入") || status.hasPrefix("分析最近") ? status : "分析這局中").font(.title3.bold()).foregroundStyle(Brand.ink).multilineTextAlignment(.center)
      Text(tips[tip % tips.count]).font(.subheadline).foregroundStyle(.secondary)
        .id(tip).transition(.opacity.combined(with: .move(edge: .bottom)))
      if let progress {
        VStack(spacing: 6) {
          ProgressView(value: progress).tint(Brand.orange).frame(maxWidth: 260)
            .animation(.linear(duration: 0.25), value: progress)
          Text("\(Int(progress * 100))%" + (plies.map { "・共 \($0) 步" } ?? "")).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
        }
        Text(note).font(.footnote).foregroundStyle(.secondary).padding(.top, 6)
      } else {
        ProgressView().tint(Brand.orange)
      }
      Spacer()
      Spacer()
    }
    .padding(.horizontal, 24)
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .background(Brand.paper)
    .onAppear { bob = true }
    .task {
      while !Task.isCancelled {
        try? await Task.sleep(nanoseconds: 2_200_000_000)
        withAnimation(.easeInOut(duration: 0.35)) { tip += 1 }
      }
    }
  }
}
