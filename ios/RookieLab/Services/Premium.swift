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
  private(set) var entitlementReady = false
  private(set) var error: String?
  private var refreshGeneration = 0
  private let expiryKey = "premiumVerifiedUntil"

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
    error = nil
    do {
      products = try await Product.products(for: Self.ids).sorted { $0.price > $1.price }
      if products.isEmpty { error = String(localized: "暫時無法取得訂閱方案，請稍後重試。") }
    } catch { self.error = String(localized: "訂閱方案載入失敗，請檢查連線後重試。") }
  }

  func refresh() async {
    refreshGeneration += 1
    let generation = refreshGeneration
    entitlementReady = false
    SingleGameAdvertising.shared.update(adFree: active, entitlementReady: false)
    var records: [SubscriptionAccessRecord] = []
    var uncertain = false
    var currentIDs = Set<String>()
    for await result in Transaction.currentEntitlements {
      switch result {
      case .verified(let t) where Self.ids.contains(t.productID):
        currentIDs.insert(t.productID)
        records.append(.init(expiration: t.expirationDate, revoked: t.revocationDate != nil || t.isUpgraded, current: true))
      case .unverified(let t, _) where Self.ids.contains(t.productID): uncertain = true
      default: break
      }
    }
    for id in Self.ids where !currentIDs.contains(id) {
      if let result = await Transaction.latest(for: id) {
        switch result {
        case .verified(let t): records.append(.init(expiration: t.expirationDate, revoked: t.revocationDate != nil || t.isUpgraded, current: false))
        case .unverified: uncertain = true
        }
      }
    }
    guard generation == refreshGeneration else { return }
    let cached = UserDefaults.standard.object(forKey: expiryKey) as? Date
    let access = SubscriptionAccess.resolve(records: records, cachedUntil: cached, uncertain: uncertain, previousActive: active)
    active = access.active; entitlementReady = access.ready
    UserDefaults.standard.set(active, forKey: "premiumActive")
    if let until = access.validUntil { UserDefaults.standard.set(until, forKey: expiryKey) }
    else if access.ready { UserDefaults.standard.removeObject(forKey: expiryKey) }
    SingleGameAdvertising.shared.update(adFree: active, entitlementReady: entitlementReady)
  }

  /// 買：成功回 true
  func buy(_ p: Product) async -> Bool {
    error = nil
    let r: Product.PurchaseResult
    do { r = try await p.purchase() }
    catch { self.error = String(localized: "購買未完成，請稍後重試。"); return false }
    if case .pending = r { error = String(localized: "購買等待核准，完成後權益會自動更新。") }
    if case .success(.unverified) = r { error = String(localized: "暫時無法驗證購買，請稍後恢復購買。"); return false }
    if case let .success(v) = r, case let .verified(t) = v, Self.ids.contains(t.productID) {
      await t.finish()
      await refresh()
      Telemetry.log("premium_buy", ["product": p.id])
      if !active { error = String(localized: "購買已完成，權益確認中。請稍後恢復購買。") }
      return active
    }
    return false
  }

  func restore() async {
    error = nil
    do {
      try await AppStore.sync(); await refresh()
      if !entitlementReady { error = String(localized: "暫時無法驗證購買，請稍後恢復購買。") }
      else if !active { error = String(localized: "目前沒有可恢復的有效訂閱。請確認使用原購買帳號。") }
    } catch { self.error = String(localized: "恢復購買失敗，請稍後重試。") }
  }
}

/// 付費牆：說清楚 Premium 多了什麼、價格、免費試用、恢復購買、條款連結（App 審核要求）
struct PaywallView: View {
  /// 從哪裡打開的（統計用）
  let from: String
  @Environment(\.dismiss) private var dismiss
  @State private var premium = Premium.shared
  @State private var buying: String?
  @State private var restoring = false
  @State private var trial: [String: Bool] = [:]
  private var removal: Bool { from == "ads" }
  private var available: Bool { !removal || SingleGameAdvertising.shared.configured }

  var body: some View {
    NavigationStack {
      ScrollView {
        VStack(alignment: .leading, spacing: 18) {
          HStack(spacing: 12) {
            Image("accent-rook").resizable().scaledToFit().accessibilityHidden(true).frame(width: 64, height: 64)
            VStack(alignment: .leading, spacing: 4) {
              Text(removal ? String(localized: "移除廣告") : "Rookie Lab Premium").font(.title2.bold()).foregroundStyle(Brand.ink)
              Text("陪你把每一盤棋看得更懂").font(.subheadline).foregroundStyle(.secondary)
            }
          }
          if removal {
            Text(available ? String(localized: "保留完整單局分析，訂閱期間享受無廣告復盤。") : String(localized: "目前尚未啟用 App 廣告，暫不提供去廣告購買。已有訂閱仍可恢復原有權益。"))
              .foregroundStyle(.secondary)
          } else {
          VStack(alignment: .leading, spacing: 12) {
            if SingleGameAdvertising.shared.configured { benefit("rectangle.badge.checkmark", String(localized: "移除廣告"), String(localized: "訂閱有效期間不顯示 App 廣告")) }
            benefit("sparkles", String(localized: "問教練"), String(localized: "對任何一步提問，教練根據引擎分析回答"))
            benefit("flame.fill", String(localized: "不限組數的練習"), String(localized: "每天的 5 題做完，想練多少組都可以"))
            benefit("chart.xyaxis.line", String(localized: "20 局跨局報告"), String(localized: "看更長期的習慣與進步"))
          }
          .padding(14).background(Brand.cream, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
          Text("訂閱只移除廣告，單局分析與快速復盤的內容都一樣。").font(.footnote).foregroundStyle(.secondary)
          }
          if let error = premium.error {
            Text(error).font(.subheadline).foregroundStyle(.secondary).accessibilityIdentifier("subscription-error")
            if available && premium.products.isEmpty { Button("重新載入方案") { Task { await premium.load() } } }
          }
          if available && premium.products.isEmpty && premium.error == nil { ProgressView().frame(maxWidth: .infinity) }
          ForEach(available ? premium.products : [], id: \.id) { p in
            Button {
              buying = p.id
              Task { let ok = await premium.buy(p); buying = nil; if ok { dismiss() } }
            } label: {
              HStack {
                VStack(alignment: .leading, spacing: 2) {
                  Text(p.displayName).font(.headline)
                  if trial[p.id] == true, let offer = p.subscription?.introductoryOffer {
                    Text("先試用 \(period(offer.period))，之後 \(p.displayPrice)／\(period(p.subscription!.subscriptionPeriod))，自動續訂。")
                      .font(.caption)
                  }
                }
                Spacer()
                if buying == p.id { ProgressView().tint(.white) } else {
                  Text(p.displayPrice + (p.subscription?.subscriptionPeriod.unit == .year ? String(localized: "／年") : String(localized: "／月"))).font(.headline)
                }
              }
              .padding(16).foregroundStyle(.white)
              .background(p.subscription?.subscriptionPeriod.unit == .year ? Brand.orange : Brand.ink, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            }
            .disabled(buying != nil || restoring || !premium.entitlementReady)
            .task { trial[p.id] = await p.subscription?.isEligibleForIntroOffer == true && p.subscription?.introductoryOffer?.paymentMode == .freeTrial }
          }
          Button(restoring ? String(localized: "恢復中…") : String(localized: "恢復購買")) {
            restoring = true
            Task { await premium.restore(); restoring = false; if premium.active { dismiss() } }
          }.disabled(restoring || buying != nil).frame(maxWidth: .infinity)
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
      .task { if available && premium.products.isEmpty { await premium.load() } }
      .onAppear { Telemetry.log("paywall_open", ["from": from]) }
    }
  }

  private func period(_ p: Product.SubscriptionPeriod) -> String {
    switch p.unit {
    case .day: return String(localized: "\(p.value) 天")
    case .week: return String(localized: "\(p.value) 週")
    case .month: return String(localized: "\(p.value) 個月")
    case .year: return String(localized: "\(p.value) 年")
    @unknown default: return String(localized: "訂閱週期")
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
