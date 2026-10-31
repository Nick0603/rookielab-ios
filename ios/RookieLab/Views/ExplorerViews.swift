import SwiftUI

/// 一直看得到的「大家怎麼走」：這個局面最多人走的那一步與比例，點了打開完整的走法資料庫。
/// 一律看全部分段：單一分段局數少，常常明明有人下過卻顯示沒人下過。
/// 資料庫沒有（或太少）時改顯示引擎建議與難易度，不只說「沒人下過」
struct DbChip: View {
  let fen: String
  let played: String?
  let rating: Int?
  /// 這個局面已經算好的引擎前幾名（有的話資料庫查不到時直接用）
  var engine: [EngineLine]? = nil
  let open: () -> Void
  @State private var result: Explorer.Result?
  @State private var loadedFen = ""

  private static let minGames = 10

  var body: some View {
    Button(action: open) {
      HStack(spacing: 6) {
        if let r = result, loadedFen == fen, let top = r.moves.first, r.total >= Self.minGames {
          Image(systemName: "person.2.fill").foregroundStyle(Brand.orange)
          Text("大家走 ").foregroundStyle(.secondary) + Text(top.san).bold() + Text(" \(top.games * 100 / r.total)%").foregroundStyle(.secondary)
          if let p = played {
            let share = r.moves.first(where: { $0.san == p }).map { Double($0.games) / Double(r.total) } ?? 0
            Circle().fill(share >= 0.15 ? Color.green : Color.orange).frame(width: 7, height: 7)
          }
        } else if result != nil, loadedFen == fen {
          Image(systemName: "cpu").foregroundStyle(Brand.orange)
          if let lines = engine, let b = lines.first?.best, let san = FEN.san(fen: fen, uci: b) {
            // 資料庫沒有這個局面：只給引擎建議，不標難易度（沒有資料就不下結論）
            Text("引擎建議 ").foregroundStyle(.secondary) + Text(san).bold()
          } else {
            Text("新的局面・看引擎建議").foregroundStyle(.secondary)
          }
        } else {
          Image(systemName: "person.2.fill").foregroundStyle(Brand.orange)
          Text("大家怎麼走…").foregroundStyle(.secondary)
        }
        Spacer(minLength: 0)
        Image(systemName: "chevron.up").font(.caption2.weight(.semibold)).foregroundStyle(.tertiary)
      }
      .font(.caption)
      .lineLimit(1)
      .padding(.horizontal, 10).frame(minHeight: 36)
      .background(Brand.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
      .overlay(RoundedRectangle(cornerRadius: 8).stroke(Brand.orange.opacity(0.35)))
    }
    .buttonStyle(.plain)
    .task(id: fen) {
      // 滑棋譜時一路換局面：停下來 0.4 秒才查，滑的過程不會一直發請求
      try? await Task.sleep(nanoseconds: 400_000_000)
      guard !Task.isCancelled else { return }
      let r = await Explorer.fetch(fen: fen, band: "all")
      result = r ?? Explorer.Result(total: 0, moves: [])
      loadedFen = fen
    }
  }
}

/// 這個局面：引擎推薦前三步（跟最佳步差多少勝率、好不好找），加上資料庫裡各分段大家走哪一步
struct ExplorerSheet: View {
  let fen: String
  let played: String?
  let playedByOpp: Bool
  let best: String?
  let rating: Int?
  var platform: Platform = .lichess
  @State private var band = "all"
  @State private var result: Explorer.Result?
  @State private var loading = true
  @State private var lines: [EngineLine]?

  var body: some View {
    NavigationStack {
      List {
        engineSection
        databaseSection
      }
      .listStyle(.insetGrouped)
      .navigationTitle("這個局面怎麼走").navigationBarTitleDisplayMode(.inline)
    }
    .onAppear { band = Explorer.band(for: rating, platform: platform) }
    .task(id: band) {
      loading = true
      result = await Explorer.fetch(fen: fen, band: band)
      loading = false
    }
    .task {
      lines = await StockfishService.shared.analyse(fen: fen, nodes: 400_000, multipv: 3, priority: .interactive)
    }
  }

  // MARK: 引擎推薦

  private var engineSection: some View {
    Section {
      if let lines, !lines.isEmpty {
        ForEach(Array(lines.enumerated()), id: \.offset) { i, l in
          engineRow(i, l, lines)
        }
      } else if lines == nil {
        HStack { ProgressView(); Text("計算中…").foregroundStyle(.secondary) }
      } else {
        Text("這個局面已經結束。").foregroundStyle(.secondary)
      }
    } header: {
      Text("引擎推薦")
    } footer: {
      Text("跟最佳步比：一樣好、差一點、明顯變差、大幅變差。難易度看下面選的分段裡有多少人走了最佳步（四成以上好找、一成五以下不容易找到）；這個局面少於 \(Explorer.minForDifficulty) 局就不標。")
    }
  }

  private func engineRow(_ i: Int, _ l: EngineLine, _ all: [EngineLine]) -> some View {
    let san = l.best.flatMap { FEN.san(fen: fen, uci: $0) } ?? "—"
    let gap = Difficulty.winGap(all, index: i)
    let f = l.best.flatMap { Explorer.findability(result, uci: $0) }
    return VStack(alignment: .leading, spacing: 4) {
      HStack(spacing: 8) {
        Text("\(i + 1)").font(.caption.bold()).frame(width: 20, height: 20)
          .background(i == 0 ? Brand.bestArrow : Color.gray.opacity(0.4), in: Circle()).foregroundStyle(.white)
        Text(san).font(.headline)
        if san == played { tag(playedByOpp ? "對手走的" : "你走的", .blue) }
        Spacer()
        Text(i == 0 ? "最佳" : Grading.gapText(gap))
          .font(.subheadline.monospacedDigit().weight(.semibold))
          .foregroundStyle(i == 0 || gap <= 2 ? Brand.bestArrow : gap <= 6 ? .orange : .red)
      }
      // 難易度只看資料庫：這一段的玩家多少人走了這步；局數不夠就不標
      if let f {
        HStack(spacing: 6) {
          if i == 0 { tag(f.label, f.color) }
          Text("這一段 \(Int((f.share * 100).rounded()))% 的人走這步（\(f.games.formatted()) 局）").font(.caption).foregroundStyle(.secondary)
        }
      }
      Text(FEN.sanLine(fen: fen, pv: l.pv, max: 6).joined(separator: " ")).font(.caption.monospaced()).foregroundStyle(.secondary).lineLimit(1)
    }
    .padding(.vertical, 2)
  }

  // MARK: 資料庫

  private var databaseSection: some View {
    Section {
      ScrollView(.horizontal, showsIndicators: false) {
        HStack(spacing: 6) {
          ForEach(Explorer.bands, id: \.key) { b in
            Button(b.label) { band = b.key }
              .font(.caption.weight(band == b.key ? .semibold : .regular))
              .buttonStyle(.bordered).buttonBorderShape(.capsule)
              .tint(band == b.key ? Brand.orange : .secondary)
          }
        }
      }
      .scrollBounceBehavior(.basedOnSize, axes: .vertical)
      .listRowInsets(EdgeInsets(top: 8, leading: 12, bottom: 8, trailing: 12))
      if loading && result == nil { ProgressView().frame(maxWidth: .infinity) }
      if let r = result {
        if r.total == 0 {
          Text("資料庫裡沒有人下過這個局面，看上面的引擎推薦。").font(.subheadline).foregroundStyle(.secondary)
        } else {
          if let b = best, r.total >= 30 {
            let share = Double(r.moves.first(where: { $0.san == b })?.games ?? 0) / Double(r.total)
            (Text("這一段的玩家，\(Int(share * 100))% 走了最佳步 \(b)：") + Text(share >= 0.4 ? "好找" : share >= 0.15 ? "有點難" : "不容易找到").bold().foregroundColor(share >= 0.4 ? .green : share >= 0.15 ? .orange : .red))
              .font(.subheadline)
          }
          ForEach(r.moves.prefix(8), id: \.uci) { m in
            let share = Double(m.games) / Double(r.total)
            VStack(alignment: .leading, spacing: 4) {
              HStack {
                Text(m.san).bold()
                if m.san == best { tag("最佳", .green) }
                if m.san == played { tag(playedByOpp ? "對手走的" : "你走的", .blue) }
                Spacer()
                Text("\(Int(share * 100))% · \(m.games.formatted()) 局").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
              }
              GeometryReader { g in
                Capsule().fill(Brand.cream).overlay(alignment: .leading) {
                  Capsule().fill(m.san == best ? Color.green : m.san == played ? Color.blue : Color.gray).frame(width: max(4, g.size.width * share))
                }
              }.frame(height: 6)
            }
          }
        }
      } else if !loading {
        Text("資料庫暫時查不到，稍後再試。").foregroundStyle(.secondary)
      }
    } header: {
      Text("大家怎麼走")
    } footer: {
      Text("Lichess 快棋以上的對局，分數是 Lichess 分數\(platform == .chesscom ? "（你的 chess.com 分數已換算）" : "")。")
    }
  }

  private func tag(_ s: String, _ c: Color) -> some View {
    Text(s).font(.caption2.weight(.semibold)).padding(.horizontal, 6).padding(.vertical, 2).background(c.opacity(0.15), in: Capsule()).foregroundStyle(c)
  }
}
