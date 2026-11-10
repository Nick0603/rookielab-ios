import SwiftUI

struct OpeningCoursesView: View {
  @State private var progress = OpeningCourseProgress.shared
  @State private var review = OpeningReviewStore.shared
  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 26) {
        if let id = progress.recent, progress.enrolled(id), let course = OpeningCourse.all.first(where: { $0.id == id }) {
          NavigationLink { OpeningCourseView(course: course) } label: {
            HStack {
              Image(systemName: "play.circle.fill").font(.title).foregroundStyle(Brand.orange)
              VStack(alignment: .leading, spacing: 4) {
                Text("繼續學習").font(.caption).foregroundStyle(.secondary)
                Text(course.family.text + " · " + (course.side == .white ? String(localized: "執白") : String(localized: "執黑"))).font(.headline)
              }
              Spacer()
              Image(systemName: "chevron.right").foregroundStyle(.secondary)
            }.padding().background(.background, in: RoundedRectangle(cornerRadius: 16))
          }.buttonStyle(.plain).padding(.horizontal)
        }
        courseShelf(.white)
        courseShelf(.black)
        VStack(alignment: .leading, spacing: 16) {
          Text("探索與實戰").font(.title3.bold())
          NavigationLink { OpeningAnalysisView(account: OpeningRoute.learner) } label: { Label("開局分析板", systemImage: "square.grid.3x3") }
          NavigationLink { OpeningPracticeView() } label: { Label("我的實戰開局與複習", systemImage: "chart.bar") }
          if !review.active(account: OpeningRoute.learner).isEmpty {
            Text("\(review.due(account: OpeningRoute.learner).count) 條路線到期，到「練習」一起複習。").font(.subheadline).foregroundStyle(.secondary)
          }
        }.padding(.horizontal)
      }.padding(.vertical, 16)
    }.background(Brand.paper).navigationTitle("開局")
  }

  private func courseShelf(_ side: Side) -> some View {
    VStack(alignment: .leading, spacing: 12) {
      Text(side == .white ? String(localized: "執白課程") : String(localized: "執黑課程"))
        .font(.title2.bold()).padding(.horizontal)
      ScrollView(.horizontal) {
        LazyHStack(spacing: 16) {
          ForEach(OpeningCourse.all.filter { $0.side == side }) { course in
            NavigationLink { OpeningCourseView(course: course) } label: {
              OpeningCourseCard(course: course, completed: progress.quizCompletedStages(course))
            }.buttonStyle(.plain).accessibilityIdentifier("course-card-" + course.id)
          }
        }.scrollTargetLayout().padding(.horizontal)
      }.scrollTargetBehavior(.viewAligned).scrollIndicators(.hidden)
    }
  }
}

private struct OpeningCourseCard: View {
  let course: OpeningCourse
  let completed: Int
  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      BoardView(fen: course.coverFEN, flipped: course.side == .black)
        .frame(width: 232, height: 232).allowsHitTesting(false).accessibilityHidden(true)
      VStack(alignment: .leading, spacing: 9) {
        Text(course.family.text).font(.headline)
        Text("\(course.side == .white ? String(localized: "執白") : String(localized: "執黑")) · \(course.variants.count) 種變化")
          .font(.caption).foregroundStyle(.secondary)
        ProgressView(value: Double(completed), total: Double(max(1, course.quizStages.count))).tint(Brand.orange)
        Text("已完成 \(completed)／\(course.quizStages.count) 關")
          .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
      }.padding(14)
    }
    .frame(width: 232).background(.background, in: RoundedRectangle(cornerRadius: 16))
    .clipShape(RoundedRectangle(cornerRadius: 16))
    .overlay(RoundedRectangle(cornerRadius: 16).stroke(Color.primary.opacity(0.08)))
    .accessibilityElement(children: .combine)
  }
}

struct OpeningCourseView: View {
  let course: OpeningCourse
  @State private var progress = OpeningCourseProgress.shared
  @State private var showRecall = false
  @State private var activeStage: OpeningCourse.Stage?
  private var current: Int { course.quizStages.firstIndex { !progress.quizComplete(course, stage: $0) } ?? course.quizStages.count }
  private let positions: [CGFloat] = [-42, 0, 42, 0]
  var body: some View {
    ScrollView {
      VStack(spacing: 22) {
        Text(course.side == .white ? String(localized: "執白") : String(localized: "執黑")).font(.subheadline).foregroundStyle(.secondary)
        if !progress.enrolled(course.id) {
          Image(systemName: "flag.checkered").font(.system(size: 48)).foregroundStyle(Brand.orange)
          Text("每關 6～8 個情境，走一步就有回饋，自動接下一題。").multilineTextAlignment(.center).font(.title3)
          Button("開始這個開局") { progress.enroll(course.id) }
            .buttonStyle(.borderedProminent).tint(Brand.orange).controlSize(.large)
        } else {
          Text("已完成 \(progress.quizCompletedStages(course))／\(course.quizStages.count) 關").font(.headline)
          if course.quizStages.filter({ !$0.mixed }).allSatisfy({ progress.quizComplete(course, stage: $0) }) {
            Button("變化快練") { showRecall = true }.buttonStyle(.borderedProminent).tint(Brand.orange)
            Text("隨機出現一種變化，練下一步。").font(.caption).foregroundStyle(.secondary)
          }
          ForEach(Array(course.quizStages.enumerated()), id: \.element.id) { index, stage in
            let complete = progress.quizComplete(course, stage: stage)
            let unlocked = progress.quizUnlocked(course, index: index)
            VStack(spacing: 8) {
              Button { activeStage = stage } label: {
                ZStack {
                  Circle().fill(complete ? Color.green : unlocked ? Brand.orange : Color(.tertiarySystemFill)).frame(width: 76, height: 76)
                  Image(systemName: complete ? "checkmark" : unlocked ? (stage.isReview ? "brain.head.profile" : "play.fill") : "lock.fill")
                    .font(.title2.bold()).foregroundStyle(unlocked || complete ? .white : .secondary)
                }
              }
              .buttonStyle(.plain).disabled(!unlocked)
              .accessibilityLabel("第 \(index + 1) 關・\(stage.title)")
              .accessibilityIdentifier("course-stage-" + stage.id)
              Text("第 \(index + 1) 關").font(.caption).foregroundStyle(.secondary)
              Text(stage.title).font(.subheadline.weight(.semibold)).multilineTextAlignment(.center).frame(width: 230)
              if index == current { Text("從這裡繼續").font(.caption).foregroundStyle(Brand.orange) }
            }
            .offset(x: positions[index % positions.count])
            if index + 1 < course.quizStages.count {
              Path { path in
                path.move(to: CGPoint(x: 140 + positions[index % positions.count], y: 0))
                path.addLine(to: CGPoint(x: 140 + positions[(index + 1) % positions.count], y: 34))
              }.stroke(Color.secondary.opacity(0.3), style: StrokeStyle(lineWidth: 4, dash: [5, 6])).frame(width: 280, height: 34)
            }
          }
        }
      }.frame(maxWidth: .infinity).padding(.horizontal, 18).padding(.vertical, 24)
    }
    .background(Brand.paper)
    .navigationTitle(course.family.text).navigationBarTitleDisplayMode(.inline)
    .onAppear { progress.visit(course.id) }
    .navigationDestination(isPresented: $showRecall) {
      if let mixed = course.stages.last { OpeningCourseLessonView(course: course, stage: mixed, recall: true) }
    }
    .navigationDestination(item: $activeStage) { stage in
      OpeningCourseLessonView(course: course, stage: stage)
    }
  }
}


struct OpeningCourseLessonView: View {
  let course: OpeningCourse
  let stage: OpeningCourse.Stage
  var recall = false
  var body: some View {
    if let lesson = OpeningQuizLesson.all.first(where: { $0.courseID == course.id && $0.stageID == (recall ? "mixed" : stage.id) }) {
      OpeningQuizView(course: course, lesson: lesson)
    } else {
      ContentUnavailableView("準備課程資料", systemImage: "square.grid.3x3", description: Text("請返回開局列表，再次開啟課程。"))
    }
  }
}
