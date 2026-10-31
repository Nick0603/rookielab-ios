import SwiftUI

/// 複習題庫總覽：題目從你的對局裡錯失的機會來，照 Anki 的方式排
/// 今天要練 → 沒走到的隔幾題、隔天再出 → 答對隔 1 天、3 天、越隔越久 → 連續答對 3 次就學會，移出題庫
struct ReviewPoolView: View {
  @Environment(AppModel.self) private var app
  @State private var store = ReviewStore.shared
  @State private var session: PracticeView.Session?
  @State private var confirm: ReviewCard?

  var body: some View {
    List {
      Section { summary }
      group("今天待練", store.dueCards, empty: "今天的都練完了", icon: "play.circle")
      if !store.doneToday.isEmpty { group("今天已練", store.doneToday, empty: nil, icon: "checkmark.circle") }
      group("複習中", store.waiting.filter { $0.lastDay != Day.number() }, empty: "練過的題會放在這裡，到了時間再出", icon: "clock")
      if !store.unstarted.isEmpty { group("未開始", store.unstarted, empty: nil, icon: "tray") }
      group("已熟練", store.masteredCards, empty: "自己連續走對 3 次的題會移到這裡", icon: "checkmark.seal")
    }
    .navigationTitle("複習題庫")
    .navigationDestination(for: ReviewCard.self) { c in
      if let g = app.games.first(where: { $0.id == c.gameId }) { ReviewView(game: g, startAt: c.ply) } else { Text("這局不在目前的帳號裡").foregroundStyle(.secondary) }
    }
    .fullScreenCover(item: $session) { s in PuzzleSessionView(title: s.title, items: s.items) }
    .confirmationDialog("從題庫移除這題？", isPresented: Binding(get: { confirm != nil }, set: { if !$0 { confirm = nil } }), titleVisibility: .visible) {
      Button("移除", role: .destructive) { if let c = confirm { withAnimation { store.remove(c.id) } }; confirm = nil }
    }
  }

  private var summary: some View {
    VStack(alignment: .leading, spacing: 12) {
      HStack(spacing: 0) {
        stat("\(store.dueCards.count)", "今天待練", Brand.orange)
        stat("\(store.doneToday.count)", "今天已練", .green)
        stat("\(store.waiting.count)", "複習中")
        stat("\(store.masteredCards.count)", "已熟練", Color(hex: 0x15803D))
      }
      Text("題目是你對局裡錯過的好機會：當時有勝勢、只差一步。練過的進「複習中」，隔 1 天、3 天、再久一點再出；自己連續走對 \(ReviewStore.graduate) 次就「已熟練」。看了答案的這一輪隔 \(PuzzleSessionView.againAfter) 題再走一次。")
        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
      if !store.dueCards.isEmpty {
        Button { session = .init(title: "今日複習", items: store.session().map(PuzzleItem.init(card:))) } label: {
          Label("練今天的 \(min(store.dueCards.count, PracticeView.daily)) 題", systemImage: "play.fill").font(.headline).frame(maxWidth: .infinity, minHeight: 44)
        }
        .buttonStyle(.borderedProminent).tint(Brand.orange)
      }
    }
    .padding(.vertical, 4)
  }

  private func stat(_ n: String, _ label: String, _ color: Color = Brand.ink) -> some View {
    VStack(spacing: 2) {
      Text(n).font(.title2.bold().monospacedDigit()).foregroundStyle(color)
      Text(label).font(.caption).foregroundStyle(.secondary)
    }
    .frame(maxWidth: .infinity)
  }

  @ViewBuilder private func group(_ title: String, _ cards: [ReviewCard], empty: String?, icon: String) -> some View {
    Section {
      if cards.isEmpty, let empty {
        Text(empty).font(.subheadline).foregroundStyle(.secondary)
      }
      ForEach(cards) { c in
        NavigationLink(value: c) { row(c) }
          .swipeActions(edge: .trailing) { Button(role: .destructive) { confirm = c } label: { Label("移除", systemImage: "trash") } }
          .swipeActions(edge: .leading) {
            Button { session = .init(title: "練這題", items: [PuzzleItem(card: c)]) } label: { Label("練這題", systemImage: "play") }.tint(Brand.orange)
          }
      }
    } header: {
      Label("\(title)（\(cards.count)）", systemImage: icon)
    }
  }

  private func row(_ c: ReviewCard) -> some View {
    HStack(spacing: 10) {
      VStack(alignment: .leading, spacing: 2) {
        Text("vs \(c.opponent)・第 \(c.moveNumber) 手").font(.subheadline.weight(.semibold)).foregroundStyle(Brand.ink)
        Text("\(c.date.formatted(.dateTime.year().month().day()))・你走了 \(c.played)").font(.caption).foregroundStyle(.secondary)
      }
      Spacer(minLength: 6)
      VStack(alignment: .trailing, spacing: 3) {
        Text(next(c)).font(.caption.weight(.medium)).foregroundStyle(c.mastered ? .green : Brand.ink.opacity(0.8))
        if !c.mastered && !c.isNew {
          HStack(spacing: 3) {
            ForEach(0..<ReviewStore.graduate, id: \.self) { i in Circle().fill(i < c.streak ? Color.green : Color(.secondarySystemFill)).frame(width: 6, height: 6) }
          }
        }
      }
    }
  }

  private func next(_ c: ReviewCard) -> String {
    if c.mastered { return "已熟練" }
    if c.isNew { return "未開始" }
    if c.lastDay == Day.number() && c.due > Day.number() { return "今天已練" }
    let d = c.due - Day.number()
    return d <= 0 ? "今天" : d == 1 ? "明天" : "\(d) 天後"
  }
}
