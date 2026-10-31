import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// 分享延伸：從 Chess.com、Lichess 分享過來的內容裡找出對局連結，交給主程式（rookielab://import?url=…）。
/// 叫不起主程式時，顯示連結讓使用者複製，到 App 裡貼上
final class ShareViewController: UIViewController {
  private let state = ShareState()

  override func viewDidLoad() {
    super.viewDidLoad()
    let host = UIHostingController(rootView: ShareView(state: state, open: { [weak self] in self?.openApp() }, close: { [weak self] in self?.done() }))
    addChild(host)
    host.view.frame = view.bounds
    host.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
    view.addSubview(host.view)
    host.didMove(toParent: self)
    Task { await load() }
  }

  private func load() async {
    var texts: [String] = []
    for item in extensionContext?.inputItems as? [NSExtensionItem] ?? [] {
      if let t = item.attributedContentText?.string { texts.append(t) }
      for p in item.attachments ?? [] {
        if p.hasItemConformingToTypeIdentifier(UTType.url.identifier), let u = try? await p.loadItem(forTypeIdentifier: UTType.url.identifier) as? URL {
          texts.append(u.absoluteString)
        } else if p.hasItemConformingToTypeIdentifier(UTType.plainText.identifier), let t = try? await p.loadItem(forTypeIdentifier: UTType.plainText.identifier) as? String {
          texts.append(t)
        }
      }
    }
    let link = ShareLink.find(in: texts.joined(separator: " "))
    await MainActor.run {
      state.link = link
      state.loaded = true
      if link != nil { openApp() }
    }
  }

  /// 從延伸叫起主程式：延伸裡不能直接用 UIApplication.shared，沿著 responder chain 找到它，
  /// 用 Objective-C runtime 呼叫 openURL:options:completionHandler:（iOS 18 以後舊的 openURL: 已經沒作用）
  private func openApp() {
    guard let link = state.link, var c = URLComponents(string: "rookielab://import") else { return }
    c.queryItems = [URLQueryItem(name: "url", value: link)]
    guard let url = c.url, let appClass = NSClassFromString("UIApplication") else { return }
    let sel = NSSelectorFromString("openURL:options:completionHandler:")
    var r: UIResponder? = self
    while let cur = r {
      if cur.isKind(of: appClass), cur.responds(to: sel) {
        typealias Open = @convention(c) (AnyObject, Selector, URL, NSDictionary, (@convention(block) (Bool) -> Void)?) -> Void
        let open = unsafeBitCast(cur.method(for: sel), to: Open.self)
        open(cur, sel, url, NSDictionary(), { [weak self] ok in
          DispatchQueue.main.async { if ok { self?.done() } else { self?.state.failed = true } }
        })
        return
      }
      r = cur.next
    }
    state.failed = true
  }

  private func done() { extensionContext?.completeRequest(returningItems: nil) }
}

enum ShareLink {
  /// chess.com/game/live/123、chess.com/game/daily/123、chess.com/analysis/game/live/123、
  /// lichess.org/AbCdEfGh、lichess.org/game/AbCdEfGh/black、lichess.org/AbCdEfGhWxYz（12 碼：後 4 碼是玩家）
  static func find(in text: String) -> String? {
    let patterns = [
      #"https?://(www\.)?chess\.com/(analysis/)?game/(live|daily)/\d+[^\s]*"#,
      #"https?://(www\.)?chess\.com/(live|daily)/game/\d+[^\s]*"#,
      #"https?://(www\.)?lichess\.org/(game/|embed/game/)?(?!(training|analysis|practice|streamer|tutorial|features|settings|tourname|broadcas|insights)\b)[A-Za-z0-9]{8}([A-Za-z0-9]{4})?(?![A-Za-z0-9])[^\s]*"#,
    ]
    for p in patterns {
      if let r = text.range(of: p, options: .regularExpression) { return String(text[r]) }
    }
    return nil
  }
}

@MainActor @Observable
final class ShareState {
  var link: String?
  var loaded = false
  var failed = false
}

struct ShareView: View {
  let state: ShareState
  let open: () -> Void
  let close: () -> Void
  @State private var copied = false

  var body: some View {
    NavigationStack {
      VStack(spacing: 16) {
        if !state.loaded {
          ProgressView()
        } else if let link = state.link {
          Image(systemName: "checkmark.circle.fill").font(.system(size: 44)).foregroundStyle(.orange)
          Text("收到對局了").font(.headline)
          Text(link).font(.footnote.monospaced()).foregroundStyle(.secondary).lineLimit(2).multilineTextAlignment(.center)
          Button(action: open) { Text("在 Rookie Lab 打開").frame(maxWidth: .infinity, minHeight: 44) }
            .buttonStyle(.borderedProminent).tint(.orange)
          if state.failed {
            Text("打不開 App 的話：複製連結，到 Rookie Lab 的「對局」頁按右上角貼上。").font(.footnote).foregroundStyle(.secondary).multilineTextAlignment(.center)
            Button(copied ? "已複製" : "複製連結") { UIPasteboard.general.string = link; copied = true }
          }
        } else {
          Image(systemName: "questionmark.circle").font(.system(size: 44)).foregroundStyle(.secondary)
          Text("這裡沒有對局連結").font(.headline)
          Text("在 Chess.com 或 Lichess 的對局頁按分享，再選 Rookie Lab。").font(.footnote).foregroundStyle(.secondary).multilineTextAlignment(.center)
        }
      }
      .padding(24)
      .frame(maxWidth: .infinity, maxHeight: .infinity)
      .navigationTitle("Rookie Lab").navigationBarTitleDisplayMode(.inline)
      .toolbar { ToolbarItem(placement: .cancellationAction) { Button("關閉", action: close) } }
    }
  }
}
