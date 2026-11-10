import SwiftUI

struct OpeningQuizView: View {
  let course: OpeningCourse
  let lesson: OpeningQuizLesson
  @State private var session: OpeningQuizSession
  @Environment(\.dismiss) private var dismiss
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  init(course: OpeningCourse, lesson: OpeningQuizLesson) {
    self.course = course; self.lesson = lesson
    _session = State(initialValue: OpeningQuizSession(course: course, lesson: lesson))
  }
  var body: some View {
    GeometryReader { geo in
      VStack(spacing: 14) {
        Label(status, systemImage: icon).font(.title3.bold()).foregroundStyle(tint)
          .accessibilityIdentifier("opening-quiz-status")
        ProgressView(value: session.fraction).tint(Brand.orange).padding(.horizontal)
        BoardView(fen: session.fen, flipped: course.side == .black, arrows: arrows,
          legalTargets: { session.acceptsMove ? FEN.targets(fen: session.fen, from: $0) : [] },
          onMove: session.acceptsMove ? { from, to in session.move(from + to) } : nil)
          .transaction { if reduceMotion { $0.disablesAnimations = true } }
          .accessibilityElement(children: .ignore).accessibilityLabel("開局練習棋盤")
          .accessibilityIdentifier("opening-quiz-board")
          .frame(width: max(1, min(geo.size.width - 28, geo.size.height * 0.68)), height: max(1, min(geo.size.width - 28, geo.size.height * 0.68)))
        if session.phase == .complete {
          Text("獨立答對 \(session.state.independent) 次 · 共作答 \(session.state.answered) 題")
            .font(.subheadline).foregroundStyle(.secondary)
          Label("完成一個關卡", systemImage: "checkmark.seal.fill").font(.headline).foregroundStyle(.green)
        } else {
          Text("\(lesson.questions.count) 個情境").font(.caption).foregroundStyle(.secondary)
        }
        Spacer(minLength: 0)
      }.frame(maxWidth: .infinity).padding(.top, 12)
    }
    .background(Brand.paper).navigationTitle(lesson.title.text).navigationBarTitleDisplayMode(.inline)
    .toolbar(.hidden, for: .tabBar)
    .safeAreaInset(edge: .bottom) {
      HStack(spacing: 12) {
        if session.phase == .complete {
          Button("再練一次") { session = OpeningQuizSession(course: course, lesson: lesson) }.buttonStyle(.bordered)
          Button("回到關卡路徑") { dismiss() }.buttonStyle(.borderedProminent).tint(Brand.orange)
        } else {
          Button(session.paused ? String(localized: "繼續") : String(localized: "暫停")) { session.pause() }.buttonStyle(.bordered)
          Button("提示") { session.showHint() }.buttonStyle(.bordered).disabled(!session.acceptsMove)
        }
      }.frame(maxWidth: .infinity, minHeight: 44).padding(12).background(.bar)
    }
    .task(id: session.tickKey) {
      guard session.needsTick else { return }
      do { try await Task.sleep(for: .milliseconds(session.delay)) } catch { return }
      guard !Task.isCancelled else { return }; session.tick()
    }
    .onChange(of: session.phase) { _, phase in
      if phase == .correct { Haptics.success() }
      else if phase == .incorrect { Haptics.error() }
    }
    .task { await StockfishService.shared.holdBackground(true) }
    .onDisappear {
      session.save()
      Task { await StockfishService.shared.holdBackground(false) }
    }
  }
  private var status: String {
    if session.paused { return String(localized: "已暫停") }
    switch session.phase {
    case .context: return String(localized: "先看一遍")
    case .demo: return String(localized: "看這一步")
    case .answer, .transition: return String(localized: "換你走")
    case .correct: return String(localized: "答對了！")
    case .incorrect, .correction: return String(localized: "再看這一步")
    case .assisted: return String(localized: "完成這一步")
    case .complete: return String(localized: "本關完成")
    }
  }
  private var icon: String {
    switch session.phase {
    case .correct, .complete: "checkmark.circle.fill"
    case .incorrect, .correction: "xmark.circle"
    default: "square.grid.3x3"
    }
  }
  private var tint: Color {
    switch session.phase {
    case .correct, .complete: .green
    case .incorrect, .correction, .assisted: Brand.orange
    default: .primary
    }
  }
  private var arrows: [Arrow] {
    guard session.arrow, let ply = ChessLine.ply(fen: session.state.current.fen, uci: session.state.current.uci, index: 0) else { return [] }
    return [Arrow(from: ply.from, to: ply.to, color: Brand.orange)]
  }
}
