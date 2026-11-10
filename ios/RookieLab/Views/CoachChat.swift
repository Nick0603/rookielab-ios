import SwiftUI
#if canImport(FoundationModels)
import FoundationModels
#endif

/// 問教練：用手機上的 Apple 語言模型（Foundation Models，iOS 26 以上、支援 Apple Intelligence 的機型），免費、不連網。
/// 只根據這一步的引擎資料與網站解說回答，不讓模型自己推棋步（小模型推棋會亂講）
enum AICoach {
  static var available: Bool {
    #if canImport(FoundationModels)
    if #available(iOS 26, *) { return SystemLanguageModel.default.isAvailable }
    #endif
    return false
  }

  /// 給模型的事實：都是引擎與規則算好的
  static func facts(_ r: MoveRecord, ply p: Ply, me: Side, explanation e: ExplainJS.Explanation?, bestLine: [String]) -> String {
    let who = p.mover == me ? "使用者" : "對手"
    var lines = [
      "走這步的是：\(who)（\(p.mover == .white ? "白方" : "黑方")），第 \(p.moveNumber) 手",
      "這一步：\(p.san)（從 \(p.from) 走到 \(p.to)）",
      "評級：\(r.cls.zh)",
      "走之前局面：\(Grading.standing(r.winBefore))（走這步那一方的勝率 \(Int(r.winBefore * 100))%）",
      "走之後局面：\(Grading.standing(r.winAfter))（勝率 \(Int(r.winAfter * 100))%）",
    ]
    if let b = r.bestSan, b != p.san { lines.append("引擎認為最好的一步：\(b)") }
    if !bestLine.isEmpty { lines.append("最好的一步之後引擎預期的走法：\(bestLine.prefix(4).joined(separator: " "))") }
    if let e {
      lines.append("解說標題：\(e.headline)")
      lines += e.plainReasons.prefix(4).map { "解說：\($0)" }
    }
    lines.append("局面 FEN：\(p.fenBefore)")
    return lines.joined(separator: "\n")
  }

  static let suggestions = [
    String(localized: "為什麼這步不好？"),
    String(localized: "我該怎麼想才找得到更好的一步？"),
    String(localized: "下次遇到類似的局面要注意什麼？"),
  ]
}

struct CoachChatSheet: View {
  let facts: String
  @Environment(\.dismiss) private var dismiss
  @State private var question = ""
  @State private var turns: [(q: String, a: String)] = []
  @State private var busy = false

  var body: some View {
    NavigationStack {
      ScrollView {
        VStack(alignment: .leading, spacing: 14) {
          HStack(alignment: .top, spacing: 10) {
            Image("accent-bishop").resizable().scaledToFit().accessibilityHidden(true).frame(width: 44, height: 44)
            Text("想問這一步什麼都可以。我只根據引擎的分析回答，不會自己亂猜棋步。").font(.subheadline).foregroundStyle(Brand.ink.opacity(0.8))
          }
          if turns.isEmpty {
            ForEach(AICoach.suggestions, id: \.self) { s in
              Button { ask(s) } label: {
                Text(s).font(.subheadline).frame(maxWidth: .infinity, alignment: .leading).padding(12)
                  .background(Brand.cream, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
              }
              .disabled(busy)
            }
          }
          ForEach(Array(turns.enumerated()), id: \.offset) { _, t in
            Text(t.q).font(.subheadline.weight(.semibold)).foregroundStyle(Brand.orange)
            Text(t.a.isEmpty ? "…" : t.a).font(.body).foregroundStyle(Brand.ink).fixedSize(horizontal: false, vertical: true)
          }
        }
        .padding()
      }
      .safeAreaInset(edge: .bottom) {
        HStack {
          TextField("問教練…", text: $question).textFieldStyle(.roundedBorder).submitLabel(.send).onSubmit { ask(question) }
          Button { ask(question) } label: { Image(systemName: "arrow.up.circle.fill").font(.title2) }
            .disabled(busy || question.trimmingCharacters(in: .whitespaces).isEmpty)
        }
        .padding().background(.bar)
      }
      .navigationTitle("問教練").navigationBarTitleDisplayMode(.inline)
      .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } } }
    }
  }

  private func ask(_ q: String) {
    let q = q.trimmingCharacters(in: .whitespaces)
    guard !q.isEmpty, !busy else { return }
    question = ""
    turns.append((q, ""))
    busy = true
    Telemetry.log("coach_ask", ["n": turns.count])
    #if canImport(FoundationModels)
    if #available(iOS 26, *) {
      let k = turns.count - 1
      let instructions = """
      你是 Rookie Lab 的西洋棋教練，對象是正在進步中的玩家。
      只能根據「事實」回答；事實裡沒有的棋步、變化、評分不要自己推算或編造，看不出來就直說。
      語氣溫暖、直接、正面，像陪對方一起看棋；不說教，不用「其實」「本來就」，不用「考、答錯、失敗」這類字。
      用使用者提問的語言回答，最多 4 句。
      """
      let prompt = "事實：\n\(facts)\n\n問題：\(q)"
      Task {
        do {
          let session = LanguageModelSession(instructions: instructions)
          for try await part in session.streamResponse(to: prompt) { turns[k].a = part.content }
        } catch {
          turns[k].a = String(localized: "教練現在沒辦法回答，稍後再試一次。")
        }
        busy = false
      }
      return
    }
    #endif
    busy = false
  }
}
