import SwiftUI
import UIKit

/// 分析棋盤的狀態：一條走法（從 startFen 開始），cursor 是目前看到第幾步。
/// 在中間走了不同的棋，後面的就換成新的走法（跟 Lichess 分析板一樣，不留分支，保持簡單）
@MainActor @Observable
final class AnalysisModel {
  private(set) var startFen: String
  private(set) var plies: [Ply]
  var cursor: Int { didSet { if cursor != oldValue { analyse() } } }
  private(set) var lines: [EngineLine] = []
  /// 這個局面資料庫裡大家走什麼（候選步用）
  private(set) var db: Explorer.Result?
  private var dbTask: Task<Void, Never>?
  private(set) var depth = 0
  private(set) var thinking = false
  /// 每個局面算完的結果（評上一步用）
  private var finals: [String: [EngineLine]] = [:]
  private var task: Task<Void, Never>?

  nonisolated static let standard = "rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1"

  init(startFen: String = AnalysisModel.standard, plies: [Ply] = [], at: Int? = nil) {
    self.startFen = startFen
    self.plies = plies
    cursor = min(at ?? plies.count, plies.count)
  }

  var fen: String { cursor == 0 ? startFen : plies[cursor - 1].fenAfter }
  var last: Ply? { cursor > 0 ? plies[cursor - 1] : nil }
  var next: Ply? { cursor < plies.count ? plies[cursor] : nil }

  func targets(_ from: String) -> [String] { FEN.targets(fen: fen, from: from) }

  /// 走一步；兵走到底線要先問升變成什麼（回 true 表示要問）
  func needsPromotion(_ from: String, _ to: String) -> Bool {
    guard let code = FEN.pieces(fen)[from], code.last == "P" else { return false }
    return to.hasSuffix("8") || to.hasSuffix("1")
  }

  func move(_ from: String, _ to: String, promotion: String = "") {
    let uci = from + to + promotion
    if let n = next, n.uci == uci { cursor += 1; Sounds.play(for: n); return }
    guard let p = ChessLine.ply(fen: fen, uci: uci, index: cursor) else { return }
    plies = Array(plies.prefix(cursor)) + [p]
    cursor += 1
    Haptics.tick()
    Sounds.play(for: p)
  }

  /// 走 UCI（候選步用）
  func play(uci: String) {
    move(String(uci.prefix(2)), String(uci.dropFirst(2).prefix(2)), promotion: uci.count == 5 ? String(uci.suffix(1)) : "")
  }

  struct Candidate: Identifiable {
    let san: String
    let uci: String
    /// 引擎排第幾（從 0 開始），不是引擎的步是 nil
    let rank: Int?
    let eval: String?
    /// 跟最佳步差多少勝率（百分點）
    let gap: Int?
    /// 資料庫裡走這步的比例（%）
    let share: Int?
    var id: String { uci }
  }

  /// 可以走的步：引擎前三名在前，再補資料庫裡大家常走、引擎沒列到的
  var candidates: [Candidate] {
    var out: [Candidate] = []
    let total = db?.total ?? 0
    func share(_ uci: String) -> Int? {
      guard total >= 10, let m = db?.moves.first(where: { $0.uci == uci }) else { return nil }
      return m.games * 100 / total
    }
    for (i, l) in lines.prefix(3).enumerated() {
      guard let u = l.best, !out.contains(where: { $0.uci == u }), let san = FEN.san(fen: fen, uci: u) else { continue }
      out.append(Candidate(san: san, uci: u, rank: i, eval: evalText(l), gap: Difficulty.winGap(lines, index: i), share: share(u)))
    }
    if total >= 10, let moves = db?.moves {
      for m in moves.prefix(6) where !out.contains(where: { $0.uci == m.uci }) && out.count < 6 {
        out.append(Candidate(san: m.san, uci: m.uci, rank: nil, eval: nil, gap: nil, share: m.games * 100 / total))
      }
    }
    return out
  }

  func step(_ d: Int) {
    let n = min(max(0, cursor + d), plies.count)
    guard n != cursor else { return }
    let forward = n == cursor + 1
    cursor = n
    Haptics.tick()
    Sounds.play(for: last, forward: forward)
  }

  func load(fen: String) -> Bool {
    guard FEN.valid(fen) else { return false }
    startFen = fen
    plies = []
    cursor = 0
    analyse()
    return true
  }

  func load(pgn: String) -> Bool {
    guard let line = ChessLine(pgn: pgn) else { return false }
    startFen = line.startFen
    plies = line.plies
    cursor = plies.count
    analyse()
    return true
  }

  func reset() { _ = load(fen: Self.standard) }

  // MARK: 引擎

  /// 換局面就重算：舊的那個直接收尾，深度一路往上即時更新
  func analyse() {
    task?.cancel()
    let f = fen
    dbTask?.cancel()
    db = nil
    dbTask = Task { [weak self] in
      try? await Task.sleep(nanoseconds: 120_000_000)
      guard !Task.isCancelled else { return }
      let r = await Explorer.fetch(fen: f, band: "all")
      guard let self, !Task.isCancelled, self.fen == f else { return }
      self.db = r
    }
    lines = finals[f] ?? []
    depth = 0
    if last?.isCheckmate == true { thinking = false; return }
    thinking = true
    task = Task { [weak self] in
      await StockfishService.shared.stopInteractive()
      try? await Task.sleep(nanoseconds: 60_000_000)
      guard !Task.isCancelled else { return }
      let out = await StockfishService.shared.analyse(fen: f, nodes: 3_000_000, multipv: 3, priority: .interactive) { ls, d in
        Task { @MainActor [weak self] in
          guard let self, self.fen == f else { return }
          self.lines = ls
          self.depth = d
        }
      }
      guard let self, !Task.isCancelled, self.fen == f else { return }
      if !out.isEmpty { self.lines = out; self.finals[f] = out }
      self.thinking = false
    }
  }

  func stop() { task?.cancel(); Task { await StockfishService.shared.stopInteractive() } }

  /// 上一步的評級（前後兩個局面都算完才有）
  var lastRecord: MoveRecord? {
    guard let p = last, let b = finals[p.fenBefore], let a = finals[p.fenAfter] ?? (p.isCheckmate ? [] : nil) else { return nil }
    return Grading.record(p, before: b, after: a)
  }

  /// 白方視角的勝率與評分
  var whiteWin: Double {
    guard let e = lines.first else { return 0.5 }
    let w = Grading.winProb(e)
    return FEN.sideToMove(fen) == .white ? w : 1 - w
  }

  func evalText(_ l: EngineLine) -> String {
    let k = FEN.sideToMove(fen) == .white ? 1 : -1
    return Grading.evalText(cp: l.cp.map { $0 * k }, mate: l.mate.map { $0 * k })
  }
}

/// 分析棋盤：自己擺、自己走，引擎即時給前兩名，資料庫看大家怎麼走
struct AnalysisBoardView: View {
  @State private var model: AnalysisModel
  @State private var flipped: Bool
  @State private var promo: (from: String, to: String)?
  @State private var showDb = false
  @State private var showPaste = false
  @State private var pasted = ""
  @State private var pasteError = false

  /// 從單局復盤切過來時有值：左上角顯示「回到復盤・第 N 手」，一鍵回到原本的那一步
  private let returnLabel: String?
  @Environment(\.dismiss) private var dismiss

  init(startFen: String = AnalysisModel.standard, line: [Ply] = [], at: Int? = nil, orientation: Side = .white, returnLabel: String? = nil) {
    self.returnLabel = returnLabel
    _model = State(initialValue: AnalysisModel(startFen: startFen, plies: line, at: at))
    _flipped = State(initialValue: orientation == .black)
  }

  var body: some View {
    // 跟復盤同一種排法：棋盤 → 棋譜 → 解說區（引擎、候選步、大家怎麼走）→ 最下面的操作列
    VStack(spacing: 0) {
      HStack(spacing: 6) {
        EvalBar(white: model.whiteWin, flipped: flipped)
        ZStack {
          BoardView(fen: model.fen, flipped: flipped, arrows: arrows,
                    highlight: model.last.map { [$0.from, $0.to] } ?? [],
                    badge: model.lastRecord.flatMap { r in model.last.map { ($0.to, r.cls) } },
                    legalTargets: { model.targets($0) },
                    onMove: { from, to in
                      if model.needsPromotion(from, to) { promo = (from, to) } else { model.move(from, to) }
                    })
          if let p = promo { PromotionPicker(white: FEN.sideToMove(model.fen) == .white) { k in
            promo = nil
            if let k { model.move(p.from, p.to, promotion: k) }
          } }
        }
      }
      .frame(height: ReviewContent.boardRow)
      .padding(.horizontal, 12).padding(.top, 6)
      moveStrip.padding(.vertical, 2)
      Divider()
      ScrollView {
        VStack(alignment: .leading, spacing: 12) {
          engineCard
          CandidateStrip(items: model.candidates, thinking: model.thinking && model.lines.isEmpty) { model.play(uci: $0) }
          DbChip(fen: model.fen, played: model.next?.san, rating: nil, engine: model.lines) { showDb = true }
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
      }
      .scrollBounceBehavior(.basedOnSize)
    }
    .safeAreaInset(edge: .bottom, spacing: 0) {
      HStack(spacing: 6) {
        if returnLabel != nil {
          // 從復盤進來的：左下角直接回復盤
          Button { dismiss() } label: {
            Label("回到復盤", systemImage: "arrow.uturn.backward").font(.subheadline.weight(.semibold)).lineLimit(1)
              .padding(.horizontal, 10).frame(minHeight: 44)
              .background(Color(.secondarySystemFill), in: RoundedRectangle(cornerRadius: 10, style: .continuous)).foregroundStyle(Brand.ink)
          }
          .buttonStyle(.plain)
        } else {
          Button { model.step(-999) } label: { barIcon("backward.end", "回到開始") }.buttonStyle(.plain)
        }
        Button {
          Haptics.bump()
          if let b = model.lines.first?.best { model.play(uci: b) }
        } label: {
          Text("走最佳步").font(.headline).frame(maxWidth: .infinity, minHeight: 48)
            .background(Brand.orange, in: RoundedRectangle(cornerRadius: 12, style: .continuous)).foregroundStyle(.white)
        }
        .buttonStyle(.plain).disabled(model.lines.first?.best == nil)
        Button { flipped.toggle() } label: { barIcon("arrow.up.arrow.down", "翻轉棋盤") }.buttonStyle(.plain)
        RepeatButton(action: { model.step(-1) }) { barIcon("chevron.left", "上一步（按住快退）") }
        RepeatButton(action: { model.step(1) }) { barIcon("chevron.right", "下一步（按住快轉）") }
      }
      .padding(.horizontal, 10).padding(.top, 8).padding(.bottom, 4)
      .background(.bar)
      .overlay(alignment: .top) { Divider() }
    }
    .background(Brand.paper)
    .toolbar(returnLabel == nil ? .automatic : .hidden, for: .tabBar)
    .navigationTitle(returnLabel == nil ? "分析" : "深入分析").navigationBarTitleDisplayMode(.inline)
    .navigationBarBackButtonHidden(returnLabel != nil)
    .toolbar {
      if let returnLabel {
        ToolbarItem(placement: .topBarLeading) {
          Button { dismiss() } label: {
            HStack(spacing: 4) {
              Image(systemName: "chevron.backward").font(.body.weight(.semibold))
              Text(returnLabel).font(.subheadline.weight(.semibold)).lineLimit(1)
            }
            .fixedSize()
          }
            .accessibilityLabel("回到復盤")
        }
      }
      ToolbarItem(placement: .topBarTrailing) { SoundToggle() }
      ToolbarItem(placement: .topBarTrailing) {
        Menu {
          Button { showPaste = true } label: { Label("貼上 FEN 或 PGN", systemImage: "doc.on.clipboard") }
          Button { UIPasteboard.general.string = model.fen } label: { Label("複製 FEN", systemImage: "doc.on.doc") }
          Button(role: .destructive) { model.reset() } label: { Label("回到初始局面", systemImage: "arrow.counterclockwise") }
        } label: { Image(systemName: "ellipsis.circle") }
      }
    }
    .onAppear { model.analyse() }
    .onDisappear { model.stop() }
    .sheet(isPresented: $showDb) {
      ExplorerSheet(fen: model.fen, played: model.next?.san, playedByOpp: false, best: model.lines.first?.best.flatMap { FEN.san(fen: model.fen, uci: $0) }, rating: nil)
        .presentationDetents([.medium, .large])
    }
    .sheet(isPresented: $showPaste) {
      NavigationStack {
        VStack(alignment: .leading, spacing: 10) {
          TextEditor(text: $pasted).font(.footnote.monospaced()).frame(minHeight: 140)
            .padding(6).background(Brand.cream, in: RoundedRectangle(cornerRadius: 10))
          if pasteError { Text("看不懂這段，請貼上 FEN 或 PGN。").font(.footnote).foregroundStyle(.red) }
          Spacer()
        }
        .padding()
        .navigationTitle("貼上 FEN 或 PGN").navigationBarTitleDisplayMode(.inline)
        .toolbar {
          ToolbarItem(placement: .cancellationAction) { Button("取消") { showPaste = false } }
          ToolbarItem(placement: .confirmationAction) {
            Button("載入") {
              let t = pasted.trimmingCharacters(in: .whitespacesAndNewlines)
              let ok = t.contains("/") && !t.contains("[") && !t.contains(".") ? model.load(fen: t) : model.load(pgn: t)
              pasteError = !ok
              if ok { showPaste = false; pasted = "" }
            }
          }
        }
        .onAppear { if let s = UIPasteboard.general.string, pasted.isEmpty { pasted = s } }
      }
      .presentationDetents([.medium])
    }
  }

  private var arrows: [Arrow] {
    var out: [Arrow] = []
    if model.lines.count > 1, let alt = Grading.secondChoice(model.lines)?.best {
      out.append(Arrow(from: String(alt.prefix(2)), to: String(alt.dropFirst(2).prefix(2)), color: Brand.altArrow))
    }
    if let b = model.lines.first?.best { out.append(Arrow(from: String(b.prefix(2)), to: String(b.dropFirst(2).prefix(2)), color: Brand.bestArrow.opacity(0.75))) }
    return out
  }

  /// 第一步一樣的線只留一條（換局面時引擎的舊回覆可能混進來）
  private var uniqueLines: [EngineLine] {
    var seen = Set<String>()
    return model.lines.filter { seen.insert($0.best ?? "").inserted }
  }

  /// 引擎前兩名：評分＋接下來的幾步（SAN）
  private var engineCard: some View {
    VStack(alignment: .leading, spacing: 4) {
      HStack(spacing: 6) {
        Image(systemName: "cpu").font(.caption).foregroundStyle(.secondary)
        Text(model.thinking ? "計算中・深度 \(model.depth)" : "深度 \(max(model.depth, 1))").font(.caption2).foregroundStyle(.secondary).monospacedDigit()
        if model.thinking { ProgressView().controlSize(.mini) }
        Spacer()
      }
      ForEach(Array(uniqueLines.prefix(2).enumerated()), id: \.offset) { i, l in
        HStack(spacing: 8) {
          Text(model.evalText(l)).font(.caption.monospacedDigit().bold()).frame(minWidth: 44)
            .padding(.vertical, 3).background(i == 0 ? Brand.ink : Color.gray.opacity(0.5), in: RoundedRectangle(cornerRadius: 5)).foregroundStyle(.white)
          Text(FEN.sanLine(fen: model.fen, pv: l.pv, max: 8).joined(separator: " ")).font(.caption.monospaced()).lineLimit(1).foregroundStyle(Brand.ink)
        }
      }
      if model.lines.isEmpty { Text(model.last?.isCheckmate == true ? "將死" : "…").font(.caption).foregroundStyle(.secondary).frame(height: 40) }
    }
    .padding(10)
    .frame(minHeight: 78, alignment: .top)
    .background(Brand.cream, in: RoundedRectangle(cornerRadius: 10))
  }

  /// 棋譜滾輪：左右滑，停在中間的那一步就是現在看的
  private var moveStrip: some View {
    let items = [MoveWheel.Item(id: 0, number: nil, san: "開始")] + model.plies.enumerated().map { i, p in
      MoveWheel.Item(id: i + 1, number: p.mover == .white ? "\(p.moveNumber)." : i == 0 ? "\(p.moveNumber)…" : nil, san: p.san)
    }
    return MoveWheel(items: items, selection: Binding(get: { model.cursor }, set: { model.cursor = $0 }))
  }

  private func barIcon(_ name: String, _ label: String) -> some View {
    Image(systemName: name).font(.system(size: 18, weight: .semibold)).foregroundStyle(Brand.ink)
      .frame(width: 48, height: 48).contentShape(Rectangle()).accessibilityLabel(label)
  }

  private func ctrl(_ icon: String, _ label: String, action: @escaping () -> Void) -> some View {
    Button(action: action) {
      Image(systemName: icon).font(.system(size: 15, weight: .semibold)).frame(maxWidth: .infinity, minHeight: 44)
        .background(Brand.cream, in: RoundedRectangle(cornerRadius: 9))
    }
    .buttonStyle(.plain).foregroundStyle(Brand.ink).accessibilityLabel(label)
  }
}

/// 可以走的步：引擎前三名（評分、跟最佳步差多少）＋資料庫大家常走的（比例），點一下就走
struct CandidateStrip: View {
  let items: [AnalysisModel.Candidate]
  let thinking: Bool
  let play: (String) -> Void

  var body: some View {
    ScrollView(.horizontal, showsIndicators: false) {
      HStack(spacing: 6) {
        if items.isEmpty {
          Text(thinking ? "計算中…" : "沒有可以走的步").font(.caption).foregroundStyle(.secondary).padding(.horizontal, 4)
        }
        ForEach(items) { c in
          Button { play(c.uci) } label: {
            VStack(alignment: .leading, spacing: 1) {
              HStack(spacing: 4) {
                if c.rank == 0 { Image(systemName: "star.fill").font(.system(size: 9)).foregroundStyle(Brand.bestArrow) }
                Text(c.san).font(.subheadline.weight(.semibold))
              }
              Text(detail(c)).font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 10).padding(.vertical, 5)
            .background(c.rank == 0 ? Brand.bestArrow.opacity(0.12) : Brand.cream, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
          }
          .buttonStyle(.plain).foregroundStyle(Brand.ink)
        }
      }
      .scrollTargetLayout()
    }
    .scrollTargetBehavior(.viewAligned)
    .scrollBounceBehavior(.basedOnSize, axes: .vertical)
    .frame(height: 44)
    .animation(.snappy, value: items.map(\.uci))
  }

  private func detail(_ c: AnalysisModel.Candidate) -> String {
    var parts: [String] = []
    if let e = c.eval { parts.append(c.rank == 0 ? e : "\(e)・\(Grading.gapText(c.gap ?? 0))") }
    if let s = c.share { parts.append("大家 \(s)%") }
    return parts.joined(separator: " ")
  }
}

/// 升變：直接蓋在棋盤上選
struct PromotionPicker: View {
  let white: Bool
  let pick: (String?) -> Void
  var body: some View {
    ZStack {
      Color.black.opacity(0.35).onTapGesture { pick(nil) }
      HStack(spacing: 10) {
        ForEach(["q", "r", "b", "n"], id: \.self) { k in
          Button { pick(k) } label: {
            Image("piece-\(white ? "w" : "b")\(k.uppercased())").resizable().frame(width: 56, height: 56)
              .padding(6).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
          }
          .accessibilityLabel(Explain.pieceZh[k] ?? k)
        }
      }
    }
    .transition(.opacity)
  }
}
