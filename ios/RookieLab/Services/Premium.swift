import StoreKit
import SwiftUI

/// Premium 訂閱（StoreKit 2）：問教練、每天不限組數的練習、20 局跨局報告。原本免費的功能都維持免費
@MainActor @Observable
final class Premium {
  static let shared = Premium()
  static let ids = ["io.rookielab.app.premium.yearly", "io.rookielab.app.premium.monthly"]

  private(set) var products: [Product] = []
  /// 有訂閱（含免費試用中）；離線時沿用上次確認的結果
  private(set) var active = UserDefaults.standard.bool(forKey: "premiumActive")
  private var updates: Task<Void, Never>?

  func start() {
    guard updates == nil else { return }
    // 在別的裝置買、續訂、退款：App 開著時也收得到
    updates = Task {
      for await r in Transaction.updates {
        if case let .verified(t) = r { await t.finish() }
        await refresh()
      }
    }
    Task { await load(); await refresh() }
  }

  func load() async {
    products = ((try? await Product.products(for: Self.ids)) ?? []).sorted { $0.price > $1.price }
  }

  func refresh() async {
    var on = false
    for await r in Transaction.currentEntitlements {
      if case let .verified(t) = r, Self.ids.contains(t.productID), t.revocationDate == nil { on = true }
    }
    active = on
    UserDefaults.standard.set(on, forKey: "premiumActive")
  }

  /// 買：成功回 true
  func buy(_ p: Product) async -> Bool {
    guard let r = try? await p.purchase() else { return false }
    if case let .success(v) = r, case let .verified(t) = v {
      await t.finish()
      await refresh()
      Telemetry.log("premium_buy", ["product": p.id])
      return true
    }
    return false
  }

  func restore() async {
    try? await AppStore.sync()
    await refresh()
  }
}

/// 付費牆：說清楚 Premium 多了什麼、價格、免費試用、恢復購買、條款連結（App 審核要求）
struct PaywallView: View {
  /// 從哪裡打開的（統計用）
  let from: String
  @Environment(\.dismiss) private var dismiss
  @State private var premium = Premium.shared
  @State private var buying: String?
  @State private var trial: [String: Bool] = [:]

  var body: some View {
    NavigationStack {
      ScrollView {
        VStack(alignment: .leading, spacing: 18) {
          HStack(spacing: 12) {
            Image("coach-cheer").resizable().scaledToFit().frame(width: 64, height: 64)
            VStack(alignment: .leading, spacing: 4) {
              Text("Rookie Lab Premium").font(.title2.bold()).foregroundStyle(Brand.ink)
              Text("陪你把每一盤棋看得更懂").font(.subheadline).foregroundStyle(.secondary)
            }
          }
          VStack(alignment: .leading, spacing: 12) {
            benefit("sparkles", String(localized: "問教練"), String(localized: "對任何一步提問，教練根據引擎分析回答"))
            benefit("flame.fill", String(localized: "不限組數的練習"), String(localized: "每天的 5 題做完，想練多少組都可以"))
            benefit("chart.xyaxis.line", String(localized: "20 局跨局報告"), String(localized: "看更長期的習慣與進步"))
          }
          .padding(14).background(Brand.cream, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
          Text("復盤、快速復盤、每天 5 題、最近 10 局的報告都維持免費。").font(.footnote).foregroundStyle(.secondary)
          if premium.products.isEmpty {
            ProgressView().frame(maxWidth: .infinity)
          }
          ForEach(premium.products, id: \.id) { p in
            Button {
              buying = p.id
              Task { let ok = await premium.buy(p); buying = nil; if ok { dismiss() } }
            } label: {
              HStack {
                VStack(alignment: .leading, spacing: 2) {
                  Text(p.displayName).font(.headline)
                  if trial[p.id] == true { Text("先免費試用 1 週").font(.caption) }
                }
                Spacer()
                if buying == p.id { ProgressView().tint(.white) } else {
                  Text(p.displayPrice + (p.subscription?.subscriptionPeriod.unit == .year ? String(localized: "／年") : String(localized: "／月"))).font(.headline)
                }
              }
              .padding(16).foregroundStyle(.white)
              .background(p.subscription?.subscriptionPeriod.unit == .year ? Brand.orange : Brand.ink, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            }
            .disabled(buying != nil)
            .task { trial[p.id] = await p.subscription?.isEligibleForIntroOffer == true && p.subscription?.introductoryOffer != nil }
          }
          Button("恢復購買") { Task { await premium.restore(); if premium.active { dismiss() } } }.frame(maxWidth: .infinity)
          Text("訂閱會自動續訂，可以隨時在「設定 → Apple 帳號 → 訂閱」取消；取消後用到這期結束。").font(.caption2).foregroundStyle(.secondary)
          HStack(spacing: 16) {
            Link("使用條款", destination: URL(string: "https://www.apple.com/legal/internet-services/itunes/dev/stdeula/")!)
            Link("隱私說明", destination: URL(string: "https://rookielab.io/privacy/")!)
          }
          .font(.caption)
        }
        .padding()
      }
      .background(Brand.paper)
      .toolbar { ToolbarItem(placement: .cancellationAction) { Button("之後再說") { dismiss() } } }
      .task { if premium.products.isEmpty { await premium.load() } }
      .onAppear { Telemetry.log("paywall_open", ["from": from]) }
    }
  }

  private func benefit(_ icon: String, _ title: String, _ detail: String) -> some View {
    HStack(alignment: .top, spacing: 12) {
      Image(systemName: icon).font(.title3).foregroundStyle(Brand.orange).frame(width: 28)
      VStack(alignment: .leading, spacing: 2) {
        Text(title).font(.subheadline.weight(.semibold)).foregroundStyle(Brand.ink)
        Text(detail).font(.caption).foregroundStyle(.secondary)
      }
    }
  }
}
