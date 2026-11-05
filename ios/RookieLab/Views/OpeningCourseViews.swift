import SwiftUI

struct OpeningCoursesView: View {
  @State private var side = Side.white
  @State private var progress = OpeningCourseProgress.shared
  @State private var review = OpeningReviewStore.shared
  var body: some View {
    List {
      if let id = progress.recent, let course = OpeningCourse.all.first(where: { $0.id == id }) {
        Section("繼續學習") { NavigationLink { OpeningCourseView(course: course) } label: { courseRow(course) } }
      }
      Section {
        Picker("執棋顏色", selection: $side) { Text("執白").tag(Side.white); Text("執黑").tag(Side.black) }.pickerStyle(.segmented)
        Text(side == .white ? String(localized: "從自己的第一步開始，學主線與不同回應。") : String(localized: "對手先走第一步，再練黑方的回應。")).font(.caption).foregroundStyle(.secondary)
      }
      ForEach(side == .black ? ["e4", "d4"] : ["all"], id: \.self) { first in
        Section(first == "all" ? String(localized: "開局課程") : String(localized: "應對 1.\(first)")) {
          ForEach(OpeningCourse.all.filter { $0.side == side && (first == "all" || $0.variants.first?.steps.first?.san == first) }) { course in
            NavigationLink { OpeningCourseView(course: course) } label: { courseRow(course) }
          }
        }
      }
      Section("探索與實戰") {
        NavigationLink { OpeningAnalysisView(account: OpeningRoute.learner) } label: { Label("開局分析板", systemImage: "square.grid.3x3") }
        NavigationLink { OpeningPracticeView() } label: { Label("我的實戰開局與複習", systemImage: "chart.bar") }
      }
      Section { Text("首批提供義大利、倫敦系統、蘇格蘭的白黑角色課程。每套都有主線與分支；其他開局仍可到分析板探索。").font(.caption).foregroundStyle(.secondary) }
      if !review.active(account: OpeningRoute.learner).isEmpty {
        Section("開局複習") {
          Text("\(review.due(account: OpeningRoute.learner).count) 條路線到期，到「練習」一起複習。").font(.subheadline)
        }
      }
    }.navigationTitle("開局")
  }
  private func courseRow(_ course: OpeningCourse) -> some View {
    VStack(alignment: .leading, spacing: 5) {
      Text(course.family.text).font(.headline)
      Text("\(course.side == .white ? String(localized: "執白") : String(localized: "執黑")) · \(course.variants.count) 種變化 · 最多第 \(course.maxTurn) 手").font(.caption).foregroundStyle(.secondary)
      ProgressView(value: Double(progress.entry(course.id).completed.count), total: Double(course.stages.count)).tint(Brand.orange)
    }.padding(.vertical, 4)
  }
}

struct OpeningCourseView: View {
  let course: OpeningCourse
  @State private var progress = OpeningCourseProgress.shared
  var body: some View {
    List {
      Section {
        Text(course.goal.text)
        Text(course.side == .white ? String(localized: "你練白方，黑方會自動回應。") : String(localized: "你練黑方，先看白方的第一步，再選擇回應。"))
          .font(.subheadline).foregroundStyle(.secondary)
        Picker("完整練習終點", selection: Binding(get: { min(progress.entry(course.id).turn ?? course.maxTurn, course.maxTurn) }, set: { progress.selectTurn(course.id, turn: $0) })) {
          ForEach(1...course.maxTurn, id: \.self) { n in Text("第 \(n) 手").tag(n) }
        }
      } footer: { Text("手數以白黑各走一步計算。每關會顯示你實際要走幾步；可以先練短一點，再延長。") }
      Section("學習進程") {
        ForEach(Array(course.stages.enumerated()), id: \.element.id) { index, stage in
          let enoughDepth = (progress.entry(course.id).turn ?? course.maxTurn) >= course.minimumTurn(stage)
          let unlocked = progress.unlocked(course, index: index) && enoughDepth
          NavigationLink { OpeningCourseLessonView(course: course, stage: stage) } label: {
            HStack(spacing: 12) {
              Image(systemName: progress.entry(course.id).completed.contains(stage.id) ? "checkmark.circle.fill" : unlocked ? "play.circle" : "lock.circle").foregroundStyle(unlocked ? Brand.orange : .secondary)
              VStack(alignment: .leading, spacing: 4) {
                Text("\(index + 1). \(stage.title)")
                if !enoughDepth { Text("請將終點調到第 \(course.minimumTurn(stage)) 手以上").font(.caption).foregroundStyle(.secondary) }
                Text(stage.mixed ? String(localized: "辨認已學的不同回應，從第一步串起來") : String(localized: "先看棋盤圖解，再自己走")).font(.caption).foregroundStyle(.secondary)
              }
            }
          }.disabled(!unlocked)
        }
      }
      Section("記住哪些變化") {
        ForEach(Array(course.variants.enumerated()), id: \.element.id) { _, variation in
          let route = course.route(variation: course.variants.firstIndex(where: { $0.id == variation.id })!, count: (progress.entry(course.id).turn ?? course.maxTurn) * 2)
          let card = OpeningReviewStore.shared.active(account: OpeningRoute.learner).first { $0.route.moves == route.moves && $0.route.side == route.side }
          HStack { Text(variation.name); Spacer(); Text(card?.mastered == true ? String(localized: "已熟練") : card != nil ? String(localized: "待鞏固") : String(localized: "尚未練習")).font(.caption).foregroundStyle(.secondary) }
        }
      }
    }
    .navigationTitle(course.family.text).navigationBarTitleDisplayMode(.inline)
    .onAppear { progress.visit(course.id) }
  }
}

struct OpeningCourseLessonView: View {
  let course: OpeningCourse
  let stage: OpeningCourse.Stage
  @State private var step = 0
  @State private var progress = OpeningCourseProgress.shared
  private var count: Int { min(stage.plies, (progress.entry(course.id).turn ?? course.maxTurn) * 2) }
  private var route: OpeningRoute { course.route(variation: stage.variation, count: count) }
  private var plies: [Ply] { route.plies }
  var body: some View {
    GeometryReader { geo in
      VStack(spacing: 12) {
        if !stage.mixed { ProgressView(value: Double(step + 1), total: Double(max(1, plies.count))).padding(.horizontal).tint(Brand.orange) }
        if !stage.mixed, let ply = plies[safe: step] {
          BoardView(fen: ply.fenAfter, flipped: course.side == .black, arrows: [Arrow(from: ply.from, to: ply.to, color: Brand.orange)] + (course.variants[stage.variation].steps[step].marks ?? []).map { Arrow(from: $0.from, to: $0.to, color: $0.kind == "attack" ? .red : .blue) }, highlight: [ply.from, ply.to])
            .frame(width: min(geo.size.width - 28, geo.size.height * 0.55), height: min(geo.size.width - 28, geo.size.height * 0.55))
          ScrollView {
            VStack(alignment: .leading, spacing: 12) {
              Text("\(ply.moveNumber)\(ply.mover == .white ? "." : "…") \(ply.san)").font(.title3.bold().monospaced())
              Text(course.variants[stage.variation].steps[step].text).font(.body)
              if let facts = course.variants[stage.variation].steps[step].facts?.text, !facts.isEmpty { Text(facts).font(.subheadline).foregroundStyle(.secondary) }
              Text("\(ply.from) → \(ply.to)").font(.caption.monospaced()).foregroundStyle(.secondary)
            }.frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal)
          }
        } else {
          ContentUnavailableView("分辨不同變化", systemImage: "arrow.triangle.branch", description: Text("對手會從剛學過的回應中選擇。先看清楚局面，再走下一步。"))
        }
        Spacer(minLength: 0)
      }.frame(maxWidth: .infinity)
    }
    .safeAreaInset(edge: .bottom) {
      HStack {
        if !stage.mixed {
          Button("上一步") { step = max(0, step - 1) }.disabled(step == 0).buttonStyle(.bordered)
          if step + 1 < count { Button("下一步") { step += 1 }.buttonStyle(.borderedProminent).tint(Brand.orange) }
        }
        if stage.mixed || step + 1 >= count {
          NavigationLink { OpeningCoursePracticeView(course: course, stage: stage, count: count) } label: { Text("自己走 \(route.plies.filter { $0.mover == course.side }.count) 步") }.buttonStyle(.borderedProminent).tint(Brand.orange)
        }
      }.padding(12).frame(maxWidth: .infinity).background(.bar)
    }
    .navigationTitle(stage.title).navigationBarTitleDisplayMode(.inline).toolbar(.hidden, for: .tabBar)
    .onAppear { step = min(progress.entry(course.id).lesson[stage.id] ?? 0, max(0, count - 1)) }
    .onChange(of: step) { _, value in progress.lesson(course.id, stage: stage.id, step: value) }
  }
}

struct OpeningCoursePracticeView: View {
  let course: OpeningCourse
  let stage: OpeningCourse.Stage
  let count: Int
  @State private var rounds: [OpeningRoute] = []
  @State private var index = 0
  @State private var roundID = 0
  @State private var done = false
  @State private var progress = OpeningCourseProgress.shared
  @Environment(\.dismiss) private var dismiss
  private var learnedRoutes: [OpeningRoute] {
    course.variants.indices.filter { index in
      index == stage.variation || progress.entry(course.id).completed.contains(index == 0 ? "main" : course.variants[index].id)
    }.map { course.route(variation: $0, count: count) }
  }
  var body: some View {
    Group {
      if done {
        VStack(spacing: 16) {
          Label("這一關學完了", systemImage: "checkmark.circle.fill").font(.title2).foregroundStyle(.green)
          Text("學過的變化已加入每日複習。隔一段時間再自己走，慢慢記熟。").multilineTextAlignment(.center)
          Button("回到課程") { dismiss() }.buttonStyle(.borderedProminent).tint(Brand.orange)
        }.padding()
      } else if let route = rounds[safe: index] {
        let checkpoint = progress.entry(course.id).practice[stage.id]
        OpeningExerciseView(route: route, review: false, completion: {
          let completed = progress.entry(course.id).rounds?[stage.id] ?? []
          let remaining = rounds.filter { !completed.contains($0.moves.joined(separator: " ")) }
          if !remaining.isEmpty { rounds = remaining; index = 0; roundID += 1 }
          else { progress.complete(course.id, stage: stage.id); done = true }
        }, alternatives: stage.mixed ? rounds : learnedRoutes, at: checkpoint?.moves == route.moves ? checkpoint?.cursor ?? 0 : 0,
        clean: checkpoint?.moves == route.moves ? checkpoint?.clean ?? true : true,
        title: stage.mixed ? String(localized: "混合變化練習") : stage.title,
        onResult: { actual, clean in
          progress.finishedRound(course.id, stage: stage.id, moves: actual.moves)
          if OpeningReviewStore.shared.add(actual) { OpeningReviewStore.shared.answer(actual.id, clean: clean) }
        }, onProgress: { actual, cursor, clean in progress.practice(course.id, stage: stage.id, route: actual, cursor: cursor, clean: clean) })
          .id(roundID)
      }
    }
    .onAppear {
      guard rounds.isEmpty else { return }
      let offered = stage.mixed ? course.variants.indices.map { course.route(variation: $0, count: count) }.shuffled() : [course.route(variation: stage.variation, count: count)]
      let completed = progress.entry(course.id).rounds?[stage.id] ?? []
      var seen = Set<String>()
      rounds = offered.filter { seen.insert($0.moves.joined(separator: " ")).inserted && !completed.contains($0.moves.joined(separator: " ")) }
      if rounds.isEmpty { progress.complete(course.id, stage: stage.id); done = true; return }
      if let checkpoint = progress.entry(course.id).practice[stage.id], !completed.contains(checkpoint.moves.joined(separator: " ")) {
        if let i = rounds.firstIndex(where: { $0.moves == checkpoint.moves }) { rounds.swapAt(0, i) }
        else if let resumed = learnedRoutes.first(where: { $0.moves == checkpoint.moves }) { rounds.insert(resumed, at: 0) }
      }
    }
  }
}
