import SwiftUI

/// 復盤前的載入畫面：先把整局分析完（每一步的評級、解說都備好），播放時才不會卡。
/// 等待時畫面一直有東西在變：小棋盤快速播這一局、卡片輪流講「現在在看第幾手」與西洋棋小知識、進度條數字一路跳上去
struct AnalyzingView: View {
  /// nil：不知道進度（載入對局），只放動畫
  let progress: Double?
  let status: String
  let plies: Int?
  var note = String(localized: "分析完會從頭快速播，停在重點分析")
  var tips = AnalyzingView.gameTips
  /// 有的話小棋盤會快速播這一局
  var line: ChessLine? = nil
  var flipped = false
  /// 第一張卡先出小知識（沒有分析進度可講的時候）
  var factFirst = false
  @State private var card = 0
  @State private var shown = 0.0
  @State private var replay = 0
  @State private var started = false

  /// 同一局換到下一段載入畫面（載入對局 → 分析 → 準備解說）時，棋盤、卡片、進度條接著上一段，不從頭來
  private struct Memo {
    var replay: Int { didSet { at = Date() } }
    var card: Int { didSet { at = Date() } }
    var shown: Double { didSet { at = Date() } }
    var at = Date()
    init(replay: Int, card: Int, shown: Double) { self.replay = replay; self.card = card; self.shown = shown }
  }
  private static var memo: [String: Memo] = [:]
  private var memoKey: String? { line.map { "\($0.startFen)|\($0.plies.count)|\($0.plies.last?.uci ?? "")" } }

  static let reportTips = [String(localized: "正在看每一局…"), String(localized: "找出你最常丟分的地方…"), String(localized: "整理開局、中局、殘局的表現…"), String(localized: "挑出最值得練的一件事…")]
  static let gameTips = [String(localized: "正在看每一步棋…"), String(localized: "找出好棋與錯失的機會…"), String(localized: "準備每一步的解說…"), String(localized: "挑出這局最值得練的重點…")]

  /// 西洋棋小知識（都是規則或公認的事實，等待時輪流出現）
  static let facts = [
    String(localized: "白方第一步有 20 種走法：16 種兵步、4 種馬步。"),
    String(localized: "雙方各走 4 步之後，可能的棋局約有 2880 億種。"),
    String(localized: "最快的將殺只要 2 手，叫做「愚人殺」。"),
    String(localized: "入堡是唯一一次同時移動兩顆子的走法。"),
    String(localized: "兵是唯一不能後退的棋子。"),
    String(localized: "兵走到底線可以升變成后、車、象或馬，大多數時候選后。"),
    String(localized: "吃過路兵：對方的兵一次走兩格停在你的兵旁邊，下一步可以像它只走一格那樣吃掉它。"),
    String(localized: "「將死」源自波斯語 shāh māt，意思是「國王無路可走」。"),
    String(localized: "后加王殺單王，最多 10 步就能將死。"),
    String(localized: "車加王殺單王，最多 16 步就能將死。"),
    String(localized: "三次出現同一個局面，可以要求和棋。"),
    String(localized: "連續 50 步雙方都沒吃子、也沒動兵，可以要求和棋。"),
    String(localized: "正式比賽「摸子走子」：手碰到自己的子，就要走那顆子。"),
    String(localized: "殘局的王是很強的子：把王走到中間幫忙。"),
    String(localized: "開放的局面象比較強，封閉的局面馬比較好用。"),
    String(localized: "雙象在殘局通常比一象一馬更強。"),
    String(localized: "開局的三個原則：佔中央、出子、早點入堡。"),
    String(localized: "每一步先問自己：對手剛剛那步想做什麼？"),
    String(localized: "被將軍時只有三種解法：王走開、擋住、吃掉將軍的子。"),
    String(localized: "白方先走，在高手對局裡勝率比黑方高一點。"),
  ]

  /// 現在分析到第幾手（照進度推算）
  private var analysingPly: Ply? {
    guard let line, let progress, !line.plies.isEmpty else { return nil }
    return line.plies[min(line.plies.count - 1, Int(progress * Double(line.plies.count)))]
  }

  private var replayFen: String { line.map { $0.fen(at: replay) } ?? "" }

  var body: some View {
    VStack(spacing: 14) {
      Spacer(minLength: 8)
      HStack(spacing: 10) {
        Image("accent-bishop").resizable().scaledToFit().accessibilityHidden(true).frame(width: line == nil ? 72 : 40, height: line == nil ? 72 : 40)
        Text(status.contains("/") ? String(localized: "分析這局中") : status).font(.title3.bold()).foregroundStyle(Brand.ink).multilineTextAlignment(.center)
      }
      if let line {
        // 小棋盤：快速播這一局（等的時候先看一遍整局）
        BoardView(fen: replayFen, flipped: flipped, highlight: replay > 0 ? [line.plies[replay - 1].from, line.plies[replay - 1].to] : [])
          .frame(width: 250, height: 250)
          .shadow(color: Brand.ink.opacity(0.12), radius: 10, y: 4)
          .task(id: line.plies.count) {
            while !Task.isCancelled {
              try? await Task.sleep(nanoseconds: replay >= line.plies.count ? 1_800_000_000 : 420_000_000)
              replay = replay >= line.plies.count ? 0 : replay + 1
              if let k = memoKey { Self.memo[k, default: Memo(replay: 0, card: 0, shown: 0)].replay = replay }
            }
          }
      }
      cardView.frame(maxWidth: 320).frame(minHeight: 76)
      if let progress {
        VStack(spacing: 6) {
          bar(shown).frame(maxWidth: 280)
          HStack(spacing: 0) {
            Text("\(Int((shown * 100).rounded()))%").contentTransition(.numericText(value: shown))
            if let plies { Text(String(localized: "・共 \(plies) 步")) }
          }
          .font(.caption.monospacedDigit().weight(.semibold)).foregroundStyle(.secondary)
        }
        .onChange(of: progress, initial: true) { _, v in
          // 進度只往前走（換段時不倒退）
          let next = max(v, shown)
          withAnimation(.easeOut(duration: 0.5)) { shown = next }
          if let k = memoKey { Self.memo[k, default: Memo(replay: 0, card: 0, shown: 0)].shown = next }
        }
        Text(note).font(.footnote).foregroundStyle(.secondary).multilineTextAlignment(.center)
      } else {
        ProgressView().tint(Brand.orange)
      }
      Spacer()
    }
    .padding(.horizontal, 24)
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .background(Brand.paper)
    .task {
      if !started {
        started = true
        if let k = memoKey, let m = Self.memo[k], Date().timeIntervalSince(m.at) < 5 {
          replay = m.replay; card = m.card; shown = m.shown
        } else if factFirst || progress == nil {
          // 沒有分析進度可講（讀存檔、準備解說）：先出一則小知識
          card = 1 + 2 * Int.random(in: 0..<Self.facts.count)
        }
      }
      // 第一次換卡快一點，短短的等待也看得到變化
      try? await Task.sleep(nanoseconds: 1_500_000_000)
      while !Task.isCancelled {
        withAnimation(.easeInOut(duration: 0.4)) { card += 1 }
        if let k = memoKey { Self.memo[k, default: Memo(replay: 0, card: 0, shown: 0)].card = card }
        try? await Task.sleep(nanoseconds: 4_000_000_000)
      }
    }
  }

  /// 輪流的卡片：偶數張講「現在在做什麼」，奇數張是小知識
  @ViewBuilder private var cardView: some View {
    let fact = card % 2 == 1
    let text: String = {
      if fact { return Self.facts[(card / 2) % Self.facts.count] }
      if let p = analysingPly { return String(localized: "正在看第 \(p.moveNumber) 手 \(p.san)") + "・" + tips[(card / 2) % tips.count] }
      return tips[(card / 2) % tips.count]
    }()
    HStack(alignment: .top, spacing: 10) {
      Image(systemName: fact ? "lightbulb.fill" : "magnifyingglass").font(.title3).foregroundStyle(fact ? Brand.orange : Brand.teal).frame(width: 24)
      VStack(alignment: .leading, spacing: 2) {
        Text(fact ? String(localized: "西洋棋小知識") : String(localized: "現在在做什麼")).font(.caption.weight(.bold)).foregroundStyle(fact ? Brand.orange : Brand.teal)
        Text(text).font(.subheadline).foregroundStyle(Brand.ink).fixedSize(horizontal: false, vertical: true)
      }
      Spacer(minLength: 0)
    }
    .padding(12)
    .background(Color.white, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    .id(card).transition(.asymmetric(insertion: .move(edge: .trailing).combined(with: .opacity), removal: .move(edge: .leading).combined(with: .opacity)))
  }

  /// 進度條：圓角、橘色，上面一道光一直滑過去（看得出還在動）
  private func bar(_ v: Double) -> some View {
    GeometryReader { g in
      ZStack(alignment: .leading) {
        Capsule().fill(Brand.cream)
        Capsule().fill(LinearGradient(colors: [Brand.orange, Brand.orange.opacity(0.75)], startPoint: .leading, endPoint: .trailing))
          .frame(width: max(10, g.size.width * v))
          .overlay {
            Capsule().fill(LinearGradient(colors: [.clear, .white.opacity(0.55), .clear], startPoint: .leading, endPoint: .trailing))
              .frame(width: 60)
              .phaseAnimator([false, true]) { s, on in s.offset(x: on ? g.size.width : -60) } animation: { _ in .linear(duration: 1.4) }
          }
          .clipShape(Capsule())
      }
    }
    .frame(height: 10)
  }
}
