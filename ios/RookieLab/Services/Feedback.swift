import Foundation
import StoreKit
import SwiftUI
import UIKit

/// 使用體驗回饋：欄位跟網站 src/lib/feedback/schema.ts 一樣，送到同一個 POST /api/feedback（存 D1、問題低分寄信）。
/// 設計見 docs/feedback-flow.md
enum Feedback {
  static let tasks: [(String, String)] = [
    ("review", "復盤一局"), ("report", "看分析報告"), ("daily", "每日複習"), ("puzzles", "主題謎題"),
    ("board", "分析板"), ("other", "其他"),
  ]
  static let done: [(String, String)] = [("yes", "有"), ("partly", "部分完成"), ("no", "沒有")]
  static let types: [(String, String)] = [("bug", "遇到問題或錯誤"), ("idea", "想要的功能"), ("confuse", "哪裡看不懂"), ("note", "只是想說說感想")]
  static let bands: [(String, String)] = [
    ("A", "550 以下"), ("B", "551–850"), ("C", "851–1150"), ("D", "1151–1450"), ("E", "1451–1750"), ("F", "1751 以上"), ("unknown", "不確定"),
  ]

  struct Question: Identifiable { let key: String; let label: String; var hint: String? = nil; var required = false; var long = false; var id: String { key } }

  static let branch: [String: [Question]] = [
    "bug": [
      .init(key: "what", label: "發生了什麼事？", required: true, long: true),
      .init(key: "expected", label: "你原本預期會怎樣？"),
      .init(key: "where", label: "是哪一局、哪一步？", hint: "貼對局網址，或寫「第 12 手」"),
    ],
    "idea": [
      .init(key: "want", label: "你想要什麼？", required: true, long: true),
      .init(key: "now", label: "現在你是怎麼做到這件事的？", hint: "例如用 chess.com、別的 App，或還沒辦法做到", long: true),
    ],
    "confuse": [
      .init(key: "which", label: "哪一段看不懂？", required: true, long: true),
      .init(key: "meant", label: "你覺得它應該是在說什麼？", long: true),
    ],
    "note": [],
  ]
  static let common: [Question] = [
    .init(key: "helpful", label: "最有幫助的一件事"),
    .init(key: "change", label: "最想改的一件事", long: true),
  ]

  /// 分數 → 分數段（網站 prescription.ts 的 BANDS）
  static func band(_ rating: Int?) -> String {
    guard let r = rating else { return "unknown" }
    return r <= 550 ? "A" : r <= 850 ? "B" : r <= 1150 ? "C" : r <= 1450 ? "D" : r <= 1750 ? "E" : "F"
  }

  static var version: String {
    let v = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
    let b = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?"
    return "ios-\(v)(\(b))"
  }

  @MainActor static var device: String {
    "\(UIDevice.current.model); iOS \(UIDevice.current.systemVersion); \(Int(UIScreen.main.bounds.width))x\(Int(UIScreen.main.bounds.height))"
  }

  @MainActor static func context(app: AppModel) -> [String: String] {
    [
      "accounts": "\(app.accounts.count)",
      "rating": app.games.first?.myRating.map { "\($0)" } ?? "",
      "platform": app.account?.platform.rawValue ?? "",
      "cores": "\(ProcessInfo.processInfo.activeProcessorCount)",
      "memoryGB": String(format: "%.1f", Double(ProcessInfo.processInfo.physicalMemory) / 1_073_741_824),
      "reviewCards": "\(ReviewStore.shared.cards.count)",
      "streak": "\(ReviewStore.shared.streak)",
      "locale": Locale.current.identifier,
    ]
  }

  struct Payload: Encodable {
    let score: Int, task: String, done: String, type: String, trigger: String
    let answers: [String: String]
    let band: String?, email: String?, interview: Bool
    let page: String, locale: String, version: String, device: String
    let context: [String: String]?
    let logs: [AppLog.Entry]?
  }

  enum SendError: LocalizedError {
    case rate, invalid(String), network
    var errorDescription: String? {
      switch self {
      case .rate: "送太多次了，過幾分鐘再試"
      case let .invalid(f): "有一題還沒填（\(f)）"
      case .network: "暫時送不出去，檢查網路後再試"
      }
    }
  }

  static func send(_ p: Payload) async throws {
    var req = URLRequest(url: GameSources.site.appendingPathComponent("api/feedback"))
    req.httpMethod = "POST"
    req.setValue("application/json", forHTTPHeaderField: "Content-Type")
    req.httpBody = try JSONEncoder().encode(p)
    guard let (d, r) = try? await URLSession.shared.data(for: req), let code = (r as? HTTPURLResponse)?.statusCode else { throw SendError.network }
    if code == 429 { throw SendError.rate }
    if code == 400 { throw SendError.invalid((try? JSONDecoder().decode([String: String].self, from: d))?["error"] ?? "?") }
    guard code == 200 else { throw SendError.network }
    UserDefaults.standard.set(Day.number(), forKey: "feedbackSent")
  }

  // MARK: 小卡什麼時候出現：最多 3 天一次；送過回饋 14 天內不出現

  static var promptAllowed: Bool {
    let d = UserDefaults.standard, today = Day.number()
    if let sent = d.object(forKey: "feedbackSent") as? Int, today - sent < 14 { return false }
    if let shown = d.object(forKey: "feedbackPrompted") as? Int, today - shown < 3 { return false }
    return true
  }

  static func markPrompted() { UserDefaults.standard.set(Day.number(), forKey: "feedbackPrompted") }
}

/// 最近的操作紀錄（換頁、打開哪個畫面、錯誤），回饋勾選「附上診斷資料」才送。不記任何輸入框的內容
enum AppLog {
  struct Entry: Codable { let t: Double; let k: String; let m: String }
  @MainActor private(set) static var entries: [Entry] = []

  @MainActor static func add(_ kind: String, _ message: String) {
    entries.append(Entry(t: Date().timeIntervalSince1970 * 1000, k: String(kind.prefix(12)), m: String(message.prefix(300))))
    if entries.count > 60 { entries.removeFirst(entries.count - 60) }
    Telemetry.breadcrumb("\(kind): \(message.prefix(120))")
  }
}

// MARK: - 畫面

/// 回饋（App 的評分）：先選星星。4、5 顆星：謝謝＋請到 App Store 留評價；3 顆以下：寫一句哪裡可以更好（選填 Email），送到 /api/feedback。
/// 刻意做得很簡單：一頁、右上角一定關得掉；不用表單的下拉、分段選擇（以前那種表單會卡住）
struct FeedbackForm: View {
  @Environment(AppModel.self) private var app
  @Environment(\.dismiss) private var dismiss
  @Environment(\.requestReview) private var requestReview
  let trigger: String
  let task: String
  @State var score: Int
  @State private var text = ""
  @State private var email = ""
  @State private var attach = true
  @State private var sending = false
  @State private var error: String?
  @State private var sent = false
  @FocusState private var focused: Bool

  init(trigger: String, score: Int = 0, task: String = "review") {
    self.trigger = trigger
    self.task = task
    _score = State(initialValue: score)
  }

  private var happy: Bool { score >= 4 }

  var body: some View {
    NavigationStack {
      ScrollView {
        VStack(spacing: 18) {
          if sent { thanks } else { ask }
        }
        .padding(20)
        .frame(maxWidth: .infinity)
      }
      .scrollDismissesKeyboard(.interactively)
      .background(Brand.paper)
      .navigationTitle("給我們回饋").navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .cancellationAction) { Button(sent ? "完成" : "關閉") { dismiss() } }
      }
    }
    .onAppear { AppLog.add("open", "feedback:\(trigger)") }
    .onChange(of: score) { _, s in
      // 4、5 顆星：直接記下分數、謝謝你，請你到 App Store 留評價
      if s >= 4 && !sent { Task { await submit() } }
    }
    .task { if score >= 4 && !sent { await submit() } }
  }

  private var stars: some View {
    HStack(spacing: 10) {
      ForEach(1...5, id: \.self) { n in
        Button { score = n; Haptics.tick() } label: {
          Image(systemName: n <= score ? "star.fill" : "star").font(.system(size: 34)).foregroundStyle(n <= score ? Brand.orange : .gray.opacity(0.45))
        }
        .buttonStyle(.plain).accessibilityLabel("\(n) 顆星")
      }
    }
  }

  @ViewBuilder private var ask: some View {
    Image("coach-think").resizable().scaledToFit().frame(width: 96, height: 96)
    Text("Rookie Lab 用起來如何？").font(.title3.bold()).foregroundStyle(Brand.ink)
    stars
    if score > 0 && !happy {
      VStack(alignment: .leading, spacing: 8) {
        Text("哪裡可以更好？").font(.subheadline.weight(.semibold))
        TextEditor(text: $text)
          .focused($focused)
          .frame(minHeight: 110)
          .scrollContentBackground(.hidden)
          .padding(8)
          .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 10))
        TextField("Email（選填，只用來回覆你）", text: $email)
          .keyboardType(.emailAddress).textInputAutocapitalization(.never).autocorrectionDisabled()
          .padding(10)
          .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 10))
        Toggle("附上診斷資料（裝置、版本、最近的操作）", isOn: $attach).font(.footnote)
      }
      if let error { Text(error).font(.footnote).foregroundStyle(.red) }
      Button { focused = false; Task { await submit() } } label: {
        HStack { if sending { ProgressView().tint(.white) }; Text("送出") }
          .font(.headline).frame(maxWidth: .infinity, minHeight: 48)
      }
      .buttonStyle(.borderedProminent).tint(Brand.orange)
      .disabled(sending || text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    }
  }

  @ViewBuilder private var thanks: some View {
    Image(happy ? "coach-cheer" : "coach-happy").resizable().scaledToFit().frame(width: 110, height: 110)
    Text("謝謝你！").font(.title2.bold()).foregroundStyle(Brand.ink)
    if happy {
      Text("喜歡的話，到 App Store 留個評價，讓更多想變強的棋友找到 Rookie Lab。").font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)
      Button { requestReview(); dismiss() } label: {
        Label("到 App Store 留評價", systemImage: "star.bubble").font(.headline).frame(maxWidth: .infinity, minHeight: 48)
      }
      .buttonStyle(.borderedProminent).tint(Brand.orange)
    } else {
      Text(email.isEmpty ? "每一則都會看，改好的會出現在之後的版本。" : "改好之後會寄信告訴你。").font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)
    }
  }

  private func submit() async {
    guard !sending else { return }
    sending = true
    error = nil
    defer { sending = false }
    let note = text.trimmingCharacters(in: .whitespacesAndNewlines)
    let p = Feedback.Payload(
      score: score, task: Feedback.tasks.contains { $0.0 == task } ? task : "other", done: "yes", type: "note", trigger: trigger,
      answers: note.isEmpty ? [:] : ["change": note],
      band: Feedback.band(app.games.first?.myRating), email: email.isEmpty ? nil : email, interview: false,
      page: "ios:\(trigger)", locale: "zh", version: Feedback.version, device: Feedback.device,
      context: attach ? Feedback.context(app: app) : nil, logs: attach ? AppLog.entries : nil)
    do {
      try await Feedback.send(p)
      Telemetry.log("feedback_sent", ["score": score, "trigger": trigger])
      withAnimation { sent = true }
    } catch {
      // 高分只是記分數：送不出去也直接謝謝（不擋著）
      if happy { withAnimation { sent = true } } else { self.error = (error as? LocalizedError)?.errorDescription ?? "暫時送不出去，等一下再試" }
    }
  }
}

/// 用完一段之後的小卡：「這次用起來如何？」點分數就打開表單（分數已帶入）
struct FeedbackPromptCard: View {
  let trigger: String
  let task: String
  @State private var hidden = !Feedback.promptAllowed
  @State private var form: Int?

  var body: some View {
    if !hidden {
      VStack(alignment: .leading, spacing: 8) {
        HStack {
          Text("Rookie Lab 用起來如何？").font(.subheadline.weight(.semibold))
          Spacer()
          Button { Feedback.markPrompted(); withAnimation { hidden = true } } label: { Image(systemName: "xmark").font(.caption.weight(.bold)).foregroundStyle(.secondary) }
            .buttonStyle(.plain).accessibilityLabel("不用了")
        }
        HStack {
          ForEach(1...5, id: \.self) { n in
            Button { Feedback.markPrompted(); form = n } label: {
              Image(systemName: "star").font(.title3).foregroundStyle(Brand.orange).frame(maxWidth: .infinity)
            }
            .buttonStyle(.plain).accessibilityLabel("\(n) 分")
          }
        }
      }
      .padding(12)
      .background(Brand.cream, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
      .sheet(item: Binding(get: { form.map { ScoreBox(n: $0) } }, set: { form = $0?.n })) { b in
        FeedbackForm(trigger: trigger, score: b.n, task: task).onDisappear { hidden = true }
      }
    }
  }

  private struct ScoreBox: Identifiable { let n: Int; var id: Int { n } }
}
