import Charts
import SwiftUI

/// 點一下走一步；按住就連續走（先停 0.35 秒，之後每 0.1 秒一步），放開就停
struct RepeatButton<Label: View>: View {
  let action: () -> Void
  @ViewBuilder let label: () -> Label
  @State private var timer: Task<Void, Never>?
  @State private var pressed = false

  var body: some View {
    label()
      .opacity(pressed ? 0.5 : 1)
      .contentShape(Rectangle())
      .gesture(
        DragGesture(minimumDistance: 0)
          .onChanged { _ in
            guard !pressed else { return }
            pressed = true
            action()
            timer = Task {
              try? await Task.sleep(nanoseconds: 350_000_000)
              while !Task.isCancelled {
                action()
                try? await Task.sleep(nanoseconds: 100_000_000)
              }
            }
          }
          .onEnded { _ in
            pressed = false
            timer?.cancel()
          }
      )
      .accessibilityAddTraits(.isButton)
      .accessibilityAction { action() }
  }
}

/// 棋譜滾輪：左右滑動時停在中間那一格就是目前的步；選到的固定在正中間
struct MoveWheel: View {
  struct Item: Identifiable {
    let id: Int
    let number: String?
    let san: String
    var badge: MoveClass? = nil
    var sub: String? = nil
    var subHighlight = false
  }

  let items: [Item]
  @Binding var selection: Int
  static let itemWidth: CGFloat = 78

  @State private var position: Int?

  var body: some View {
    GeometryReader { g in
      ScrollView(.horizontal, showsIndicators: false) {
        LazyHStack(spacing: 0) {
          ForEach(items) { it in
            cell(it).frame(width: Self.itemWidth)
              .id(it.id)
              .onTapGesture { withAnimation(.snappy) { position = it.id } }
          }
        }
        .scrollTargetLayout()
      }
      // 左右留半個畫面寬：第一步、最後一步也停得到正中間
      .safeAreaPadding(.horizontal, max(0, (g.size.width - Self.itemWidth) / 2))
      .scrollTargetBehavior(.viewAligned)
      .scrollPosition(id: $position, anchor: .center)
      .scrollBounceBehavior(.basedOnSize, axes: .vertical)
      .background(alignment: .center) {
        // 正中間的選取框（固定不動，棋譜從它下面滑過）
        Capsule().fill(Brand.orange.opacity(0.16)).frame(width: Self.itemWidth - 6, height: 34)
      }
    }
    .frame(height: 40)
    .onAppear { position = selection }
    .onChange(of: position) { _, p in if let p, p != selection { selection = p } }
    .onChange(of: selection) { _, s in if position != s { withAnimation(.snappy) { position = s } } }
  }

  private func cell(_ it: Item) -> some View {
    let on = it.id == selection
    return VStack(spacing: 0) {
      HStack(spacing: 2) {
        if let n = it.number { Text(n).foregroundStyle(.secondary) }
        Text(it.san).fontWeight(on ? .bold : .regular).lineLimit(1).minimumScaleFactor(0.7)
        if let b = it.badge { GradeBadge(cls: b, size: 12) }
      }
      .font(.caption.monospacedDigit())
      if let s = it.sub {
        Text(s).font(.system(size: 9).monospacedDigit()).foregroundStyle(it.subHighlight ? Brand.orange : Color.secondary.opacity(0.8))
      }
    }
    .foregroundStyle(Brand.ink)
    .frame(maxWidth: .infinity, minHeight: 36)
    .contentShape(Rectangle())
  }
}

/// 分數走勢（chess.com Game Review 那條圖）：淺色是白方的勝率、深色是黑方；
/// 紅點是你的失誤、青點是好棋，橘線是現在看的這一步；點或滑動跳到那一步
struct EvalGraph: View {
  /// 每個局面白方的勝率（0–1），還沒算到的是 nil
  let white: [Double?]
  let current: Int
  let marks: [(ply: Int, cls: MoveClass)]
  let flipped: Bool
  let jump: (Int) -> Void

  var body: some View {
    EvalChart(white: white, marks: marks.map { Mark(ply: $0.ply, bad: $0.cls.isBad) }, flipped: flipped).equatable()
      .overlay {
        GeometryReader { g in
          let x = g.size.width * CGFloat(current) / CGFloat(max(white.count - 1, 1))
          Rectangle().fill(Brand.orange).frame(width: 2).position(x: x, y: g.size.height / 2)
          Rectangle().fill(.clear).contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0).onChanged { v in
              let k = Int((v.location.x / max(g.size.width, 1) * CGFloat(max(white.count - 1, 1))).rounded())
              jump(min(max(0, k), white.count - 1))
            })
        }
      }
      .frame(height: 64)
      .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
      .accessibilityLabel("分數走勢")
  }

  struct Mark: Equatable { let ply: Int; let bad: Bool }
}

/// 分數走勢的圖本身（不含現在這一步）：資料一樣就不重畫
private struct EvalChart: View, Equatable {
  let white: [Double?]
  let marks: [EvalGraph.Mark]
  let flipped: Bool

  var body: some View {
    let pts = white.enumerated().compactMap { i, w in w.map { (i, flipped ? 1 - $0 : $0) } }
    Chart {
      ForEach(pts, id: \.0) { i, w in
        AreaMark(x: .value("手", i), yStart: .value("下", 0), yEnd: .value("勝率", w))
          .foregroundStyle(Color(hex: 0xF4EFE6)).interpolationMethod(.monotone)
      }
      RuleMark(y: .value("均勢", 0.5)).foregroundStyle(Color.gray.opacity(0.5)).lineStyle(StrokeStyle(lineWidth: 0.5, dash: [3, 3]))
      ForEach(marks, id: \.ply) { m in
        if let w = white[safe: m.ply + 1] ?? nil {
          PointMark(x: .value("手", m.ply + 1), y: .value("勝率", flipped ? 1 - w : w))
            .foregroundStyle(m.bad ? Color.red : Color(hex: 0x1BACA6)).symbolSize(28)
        }
      }
    }
    .chartXScale(domain: 0...max(white.count - 1, 1))
    .chartYScale(domain: 0...1)
    .chartXAxis(.hidden).chartYAxis(.hidden)
    .chartPlotStyle { $0.background(Brand.ink) }
  }
}
