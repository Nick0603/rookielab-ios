import AVFoundation
import SwiftUI
import UIKit

struct Arrow: Hashable { let from: String; let to: String; let color: Color }

/// 盤面上的一顆子。id 跨局面不變，換局面時同一顆子才會「滑過去」，不是消失再出現
struct PlacedPiece: Identifiable, Equatable {
  let id: Int
  var code: String
  var square: String

  /// 舊局面 → 新局面：沒動的保留；同種的子配到最近的空出來的格子（入堡時王和車都會滑）；
  /// 兵走到底線變成別的子算同一顆（升變）；配不到的舊子是被吃掉，配不到的新子是新出現
  static func diff(_ old: [PlacedPiece], to new: [String: String], nextId: inout Int) -> [PlacedPiece] {
    var out: [PlacedPiece] = []
    var arrived = new
    var left: [PlacedPiece] = []
    for o in old {
      if new[o.square] == o.code { out.append(o); arrived.removeValue(forKey: o.square) } else { left.append(o) }
    }
    func dist(_ a: String, _ b: String) -> Int {
      let x = Array(a.utf8), y = Array(b.utf8)
      return abs(Int(x[0]) - Int(y[0])) + abs(Int(x[1]) - Int(y[1]))
    }
    for (sq, code) in arrived.sorted(by: { $0.key < $1.key }) {
      var pick = left.indices.filter { left[$0].code == code }.min { dist(left[$0].square, sq) < dist(left[$1].square, sq) }
      if pick == nil, code.last != "P", sq.hasSuffix("1") || sq.hasSuffix("8") {
        pick = left.indices.filter { left[$0].code == "\(code.first!)P" }.min { dist(left[$0].square, sq) < dist(left[$1].square, sq) }
      }
      if let k = pick {
        out.append(PlacedPiece(id: left[k].id, code: code, square: sq))
        left.remove(at: k)
      } else {
        out.append(PlacedPiece(id: nextId, code: code, square: sq))
        nextId += 1
      }
    }
    return out
  }
}

/// 棋盤：棋子（cburnett）會滑動、箭頭、評級徽章。
/// 給了 onMove 就可以下棋：點一下選子再點目的地，或直接拖；legalTargets 決定能走到哪幾格
struct BoardView: View {
  let fen: String
  var flipped = false
  var arrows: [Arrow] = []
  var highlight: [String] = []
  /// 提示要動的那顆子：一閃一閃的綠圈
  var pulse: String? = nil
  var badge: (square: String, cls: MoveClass)?
  var legalTargets: ((String) -> [String])?
  var onMove: ((String, String) -> Void)?
  /// 沒拿起子的左右滑：換上一步／下一步（-1、1）。可以走棋時棋盤自己分辨是走棋還是換步
  var onSwipe: ((Int) -> Void)? = nil

  @State private var placed: [PlacedPiece] = []
  @State private var nextId = 0
  @State private var shownFen = ""
  @State private var selected: String?
  @State private var dragging: (id: Int, at: CGPoint)?
  /// 將死：被將死的王（閃紅、倒下）
  @State private var mated: String?
  @State private var matePulse = false

  var body: some View {
    GeometryReader { geo in
      let s = geo.size.width / 8
      let targets = selected.flatMap { legalTargets?($0) } ?? []
      let occupied = Set(placed.map(\.square))
      ZStack(alignment: .topLeading) {
        // 格子
        ForEach(0..<64, id: \.self) { i in
          let (f, r) = (i % 8, i / 8)
          let sq = square(f, r)
          Rectangle()
            .fill((f + r) % 2 == 0 ? Brand.lightSquare : Brand.darkSquare)
            .overlay(highlight.contains(sq) ? Color.yellow.opacity(0.35) : .clear)
            .overlay(selected == sq ? Color.yellow.opacity(0.45) : .clear)
            .frame(width: s, height: s)
            .offset(x: CGFloat(f) * s, y: CGFloat(r) * s)
        }
        // 座標
        ForEach(0..<8, id: \.self) { k in
          Text(rankLabel(k)).font(.system(size: s * 0.2, weight: .semibold)).foregroundStyle(k % 2 == 0 ? Brand.darkSquare : Brand.lightSquare)
            .offset(x: 2, y: CGFloat(k) * s + 1)
          Text(fileLabel(k)).font(.system(size: s * 0.2, weight: .semibold)).foregroundStyle(k % 2 == 1 ? Brand.darkSquare : Brand.lightSquare)
            .offset(x: CGFloat(k) * s + s - s * 0.2, y: 8 * s - s * 0.26)
        }
        if let sq = pulse {
          let p = point(sq, s)
          HintPulse(size: s).position(x: p.x, y: p.y).allowsHitTesting(false)
        }
        // 能走的格子：空格一個點、能吃的一圈
        ForEach(targets, id: \.self) { t in
          let p = point(t, s)
          Group {
            if occupied.contains(t) {
              Circle().stroke(Color.black.opacity(0.22), lineWidth: s * 0.08).frame(width: s * 0.9, height: s * 0.9)
            } else {
              Circle().fill(Color.black.opacity(0.2)).frame(width: s * 0.3, height: s * 0.3)
            }
          }
          .position(x: p.x, y: p.y)
          .allowsHitTesting(false)
        }
        // 將死：王那一格閃紅
        if let m = mated {
          let p = point(m, s)
          Rectangle().fill(Color.red.opacity(matePulse ? 0.55 : 0.25)).frame(width: s, height: s).position(x: p.x, y: p.y)
            .allowsHitTesting(false)
        }
        // 棋子
        ForEach(placed) { pc in
          let p = dragging?.id == pc.id ? dragging!.at : point(pc.square, s)
          let down = pc.square == mated && pc.code.last == "K"
          Image("piece-\(pc.code)").resizable().interpolation(.high)
            .frame(width: s, height: s)
            .rotationEffect(.degrees(down ? 75 : 0), anchor: .bottom)
            .scaleEffect(dragging?.id == pc.id ? 1.25 : down ? 0.9 : 1)
            .position(x: p.x, y: p.y)
            .zIndex(dragging?.id == pc.id ? 10 : 1)
            .transition(.opacity.combined(with: .scale(scale: 0.6)))
            .allowsHitTesting(false)
        }
        // 箭頭
        ForEach(arrows, id: \.self) { a in
          ArrowShape(from: point(a.from, s), to: point(a.to, s), width: s * 0.16)
            .fill(a.color.opacity(0.85))
            .allowsHitTesting(false)
            .transition(.opacity)
        }
        // 將死的「#」標記（跟 chess.com 一樣在王的右上角）
        if let m = mated {
          let p = point(m, s)
          Text("#").font(.system(size: s * 0.3, weight: .heavy)).foregroundStyle(.white)
            .frame(width: s * 0.42, height: s * 0.42).background(Color.red, in: Circle())
            .overlay(Circle().stroke(.white, lineWidth: 1.5))
            .position(x: p.x + s * 0.36, y: p.y - s * 0.36)
            .transition(.scale.combined(with: .opacity))
            .zIndex(21).allowsHitTesting(false)
        }
        // 評級徽章：棋子落地之後才跳出來
        if let b = badge {
          let p = point(b.square, s)
          GradeBadge(cls: b.cls, size: s * 0.42)
            .position(x: p.x + s * 0.36, y: p.y - s * 0.36)
            .transition(.scale(scale: 0.3).combined(with: .opacity).animation(.spring(response: 0.3, dampingFraction: 0.6).delay(0.16)))
            .id("\(b.square)\(b.cls)\(fen)")
            .zIndex(20)
            .allowsHitTesting(false)
        }
      }
      .contentShape(Rectangle())
      .gesture(onMove == nil ? nil : dragGesture(s))
    }
    .aspectRatio(1, contentMode: .fit)
    .clipShape(RoundedRectangle(cornerRadius: 6))
    .onAppear { sync(animated: false) }
    .onChange(of: fen) { sync(animated: true) }
    .accessibilityLabel("棋盤")
  }

  /// 局面換了：用 diff 對應每顆子，滑過去
  private func sync(animated: Bool) {
    guard fen != shownFen else { return }
    shownFen = fen
    selected = nil
    var id = nextId
    let next = PlacedPiece.diff(placed, to: FEN.pieces(fen), nextId: &id)
    nextId = id
    if animated {
      withAnimation(.easeInOut(duration: 0.2)) { placed = next }
    } else {
      placed = next
    }
    // 將死：棋子落地後王倒下、那一格閃紅
    let m = FEN.matedKing(fen)
    if m != mated {
      if let m {
        Task {
          try? await Task.sleep(nanoseconds: animated ? 250_000_000 : 0)
          withAnimation(.spring(response: 0.45, dampingFraction: 0.55)) { mated = m }
          withAnimation(.easeInOut(duration: 0.6).repeatCount(3, autoreverses: true)) { matePulse = true }
          Haptics.bump()
        }
      } else {
        mated = nil
        matePulse = false
      }
    }
  }

  // MARK: 下棋

  private func dragGesture(_ s: CGFloat) -> some Gesture {
    DragGesture(minimumDistance: 0)
      .onChanged { v in
        let from = squareAt(v.startLocation, s)
        if dragging == nil {
          guard let from, let pc = placed.first(where: { $0.square == from }), canPick(from) else { return }
          if hypot(v.translation.width, v.translation.height) < 4 { return }
          selected = from
          dragging = (pc.id, v.location)
        } else {
          dragging?.at = v.location
        }
      }
      .onEnded { v in
        let start = squareAt(v.startLocation, s), end = squareAt(v.location, s)
        if dragging != nil {
          // 拖放：放在能走的格子就走，不然彈回去
          let from = selected
          dragging = nil
          if let from, let end, end != from, (legalTargets?(from) ?? []).contains(end) {
            var t = Transaction(); t.disablesAnimations = true
            withTransaction(t) { commit(from, end) }
          } else {
            withAnimation(.spring(response: 0.25)) { selected = from }
          }
          return
        }
        // 沒拿起子、橫向滑：換步
        if let onSwipe, abs(v.translation.width) > 24, abs(v.translation.width) > abs(v.translation.height) * 1.5 {
          onSwipe(v.translation.width < 0 ? 1 : -1)
          return
        }
        // 點一下：選子 → 點目的地
        guard let sq = end, sq == start else { return }
        if let from = selected, (legalTargets?(from) ?? []).contains(sq) { commit(from, sq); return }
        let had = selected != nil
        selected = canPick(sq) && selected != sq ? sq : nil
        if selected != nil { Haptics.tick() } else if had || placed.contains(where: { $0.square == sq }) { Haptics.bump() }
      }
  }

  private func canPick(_ sq: String) -> Bool { !(legalTargets?(sq) ?? []).isEmpty }

  private func commit(_ from: String, _ to: String) {
    selected = nil
    onMove?(from, to)
  }

  private func squareAt(_ p: CGPoint, _ s: CGFloat) -> String? {
    let f = Int(p.x / s), r = Int(p.y / s)
    guard (0..<8).contains(f), (0..<8).contains(r) else { return nil }
    return square(f, r)
  }

  private func square(_ f: Int, _ r: Int) -> String {
    let file = flipped ? 7 - f : f, rank = flipped ? r + 1 : 8 - r
    return "\(Character(UnicodeScalar(97 + file)!))\(rank)"
  }

  private func fileLabel(_ k: Int) -> String { String(Character(UnicodeScalar(97 + (flipped ? 7 - k : k))!)) }
  private func rankLabel(_ k: Int) -> String { "\(flipped ? k + 1 : 8 - k)" }

  private func point(_ sq: String, _ s: CGFloat) -> CGPoint {
    let chars = Array(sq)
    guard chars.count == 2, let a = chars[0].asciiValue, let r = chars[1].wholeNumberValue else { return .zero }
    let f = Int(a) - 97
    let col = flipped ? 7 - f : f, row = flipped ? r - 1 : 8 - r
    return CGPoint(x: (CGFloat(col) + 0.5) * s, y: (CGFloat(row) + 0.5) * s)
  }
}

/// 箭頭：一條粗線＋三角形箭頭，終點縮一點不蓋住棋子中心
struct ArrowShape: Shape {
  let from: CGPoint, to: CGPoint, width: CGFloat
  func path(in rect: CGRect) -> Path {
    let dx = to.x - from.x, dy = to.y - from.y
    let len = max(sqrt(dx * dx + dy * dy), 1)
    let ux = dx / len, uy = dy / len
    let head = width * 2.4
    let end = CGPoint(x: to.x - ux * width * 0.6, y: to.y - uy * width * 0.6)
    let base = CGPoint(x: end.x - ux * head, y: end.y - uy * head)
    let nx = -uy, ny = ux
    var p = Path()
    p.move(to: CGPoint(x: from.x + nx * width / 2, y: from.y + ny * width / 2))
    p.addLine(to: CGPoint(x: base.x + nx * width / 2, y: base.y + ny * width / 2))
    p.addLine(to: CGPoint(x: base.x + nx * width * 1.3, y: base.y + ny * width * 1.3))
    p.addLine(to: end)
    p.addLine(to: CGPoint(x: base.x - nx * width * 1.3, y: base.y - ny * width * 1.3))
    p.addLine(to: CGPoint(x: base.x - nx * width / 2, y: base.y - ny * width / 2))
    p.addLine(to: CGPoint(x: from.x - nx * width / 2, y: from.y - ny * width / 2))
    p.closeSubpath()
    return p
  }
}

/// 評級的圓形徽章（顏色、符號與網站相同）
struct GradeBadge: View {
  let cls: MoveClass
  var size: CGFloat = 22
  var body: some View {
    ZStack {
      Circle().fill(cls.color)
      Circle().stroke(.white.opacity(0.9), lineWidth: max(1, size * 0.08))
      if let s = cls.symbol {
        Text(s).font(.system(size: size * 0.5, weight: .heavy)).foregroundStyle(.white).minimumScaleFactor(0.5)
      } else {
        Image(systemName: cls.systemImage).font(.system(size: size * 0.48, weight: .bold)).foregroundStyle(.white)
      }
    }
    .frame(width: size, height: size)
    .shadow(color: .black.opacity(0.3), radius: 1.5, y: 1)
    .accessibilityLabel(cls.zh)
  }
}

/// 走子音效（scripts/make-ios-sounds.py 合成）。跟著靜音鍵，不打斷使用者正在聽的音樂
enum Sounds {
  enum Theme: String, CaseIterable, Identifiable {
    case soft, tap, crisp, off
    var id: String { rawValue }
    var zh: String {
      switch self {
      case .soft: "柔和木頭"
      case .tap: "輕點"
      case .crisp: "清脆"
      case .off: "關閉"
      }
    }
  }

  static let key = "moveSound"

  @MainActor private static var players: [String: AVAudioPlayer] = [:]
  @MainActor private static var ready = false

  @MainActor private static func player(_ name: String) -> AVAudioPlayer? {
    if !ready {
      try? AVAudioSession.sharedInstance().setCategory(.ambient, options: [.mixWithOthers])
      ready = true
    }
    if let p = players[name] { return p }
    guard let u = Bundle.main.url(forResource: name, withExtension: "wav"), let p = try? AVAudioPlayer(contentsOf: u) else { return nil }
    p.prepareToPlay()
    players[name] = p
    return p
  }

  static var theme: Theme {
    get { Theme(rawValue: UserDefaults.standard.string(forKey: key) ?? "") ?? .soft }
    set { UserDefaults.standard.set(newValue.rawValue, forKey: key) }
  }

  /// 往前走一步才出聲（倒退、跳步不響）
  @MainActor static func play(for ply: Ply?, forward: Bool = true) {
    guard forward, let ply else { return }
    play(ply.san.contains("+") || ply.san.contains("#") ? "check" : ply.captured != nil ? "capture" : "move")
  }

  /// App 一開就先載入目前選的聲音（第一次播放時才讀檔，會讓第一步頓一下）
  @MainActor static func preload() {
    for k in ["move", "capture", "check"] { _ = player("\(theme.rawValue)-\(k)") }
  }

  @MainActor static func play(_ kind: String, theme t: Theme = theme) {
    guard t != .off, let p = player("\(t.rawValue)-\(kind)") else { return }
    p.currentTime = 0
    p.play()
  }
}

/// 導覽列上的喇叭：一鍵靜音／打開走子音效（打開時用上次選的聲音）
struct SoundToggle: View {
  @AppStorage(Sounds.key) private var theme = Sounds.Theme.soft.rawValue
  @AppStorage("lastMoveSound") private var last = Sounds.Theme.soft.rawValue

  var body: some View {
    let off = theme == Sounds.Theme.off.rawValue
    Button {
      if off { theme = last } else { last = theme; theme = Sounds.Theme.off.rawValue }
      Haptics.tick()
    } label: {
      Image(systemName: off ? "speaker.slash" : "speaker.wave.2")
    }
    .accessibilityLabel(off ? "打開走子音效" : "關閉走子音效")
  }
}

enum Haptics {
  // 重複用同一個產生器（每次 new 一個會有延遲）
  @MainActor private static let selection = UISelectionFeedbackGenerator()
  @MainActor private static let impact = UIImpactFeedbackGenerator(style: .medium)
  @MainActor static func tick() { selection.selectionChanged(); selection.prepare() }
  @MainActor static func bump() { impact.impactOccurred(); impact.prepare() }
}

/// 提示：綠色的圈一閃一閃，一眼看到要動哪顆子
private struct HintPulse: View {
  let size: CGFloat
  @State private var on = false
  var body: some View {
    RoundedRectangle(cornerRadius: size * 0.12)
      .fill(Brand.bestArrow.opacity(on ? 0.45 : 0.15))
      .overlay(RoundedRectangle(cornerRadius: size * 0.12).stroke(Brand.bestArrow, lineWidth: size * 0.08))
      .frame(width: size * 0.96, height: size * 0.96)
      .scaleEffect(on ? 1 : 0.88)
      .animation(.easeInOut(duration: 0.6).repeatForever(autoreverses: true), value: on)
      .onAppear { on = true }
  }
}
