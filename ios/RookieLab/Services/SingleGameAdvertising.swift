import Foundation
import Observation
import SwiftUI

struct SingleGameAdvertisement: Equatable, Identifiable {
  let id: String
  let sponsor: String
  let message: String
  let destination: URL
  var valid: Bool {
    !id.isEmpty && !sponsor.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      && !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      && destination.scheme == "https" && destination.host != nil
  }
}

/// The release intentionally has no provider until a real placement and compatible service are configured.
@MainActor protocol SingleGameAdProvider {
  func load() async throws -> SingleGameAdvertisement?
  /// A real SDK-owned 320×50 Banner view; text sponsor cards are not Banner ads.
  func bannerView(for advertisement: SingleGameAdvertisement) -> UIView?
}

extension SingleGameAdProvider {
  func bannerView(for advertisement: SingleGameAdvertisement) -> UIView? { nil }
}

@MainActor @Observable
final class SingleGameAdvertising {
  static let shared: SingleGameAdvertising = {
    #if canImport(GoogleMobileAds) && canImport(UserMessagingPlatform)
    return SingleGameAdvertising(provider: AdMobPilot.shared)
    #else
    return SingleGameAdvertising()
    #endif
  }()
  private(set) var advertisement: SingleGameAdvertisement?
  private(set) var banner: UIView?
  let configured: Bool
  private let provider: (any SingleGameAdProvider)?
  private var task: Task<Void, Never>?
  var pendingLoad: Task<Void, Never>? { task }
  private var generation = 0
  private var allowed = false

  init(provider: (any SingleGameAdProvider)? = nil) {
    self.provider = provider; configured = provider != nil
  }

  func update(adFree: Bool, entitlementReady: Bool) {
    #if DEBUG
    // 商店截圖：不顯示測試廣告
    if ProcessInfo.processInfo.arguments.contains("-storeScreenshots") { return }
    #endif
    let eligible = configured && entitlementReady && !adFree
    guard eligible != allowed || (eligible && task == nil && advertisement == nil) else { return }
    allowed = eligible; generation += 1; task?.cancel(); task = nil; advertisement = nil; banner = nil
    guard eligible, let provider else { return }
    let token = generation
    task = Task { [weak self] in
      let result = try? await provider.load()
      guard let self, !Task.isCancelled, self.allowed, self.generation == token else { return }
      self.advertisement = result?.valid == true ? result : nil
      self.banner = self.advertisement.flatMap { provider.bannerView(for: $0) }
      self.task = nil
    }
  }
}

struct SingleGameAdSlot: View {
  @State private var ads = SingleGameAdvertising.shared
  @State private var premium = Premium.shared
  @State private var paywall = false
  var body: some View {
    Group {
      if !premium.active, premium.entitlementReady, let banner = ads.banner {
        VStack(spacing: 6) {
          HStack {
            Text("廣告").font(.caption).foregroundStyle(.secondary)
            Spacer()
            Button("移除廣告") { paywall = true }.font(.caption)
          }
          NativeSingleGameBanner(view: banner).frame(width: 320, height: 50)
        }.padding(.vertical, 8).accessibilityIdentifier("single-game-ad")
      }
    }
    .task(id: "\(premium.active):\(premium.entitlementReady)") {
      ads.update(adFree: premium.active, entitlementReady: premium.entitlementReady)
    }
    .sheet(isPresented: $paywall) { PaywallView(from: "ads") }
  }
}

private struct NativeSingleGameBanner: UIViewRepresentable {
  let view: UIView
  func makeUIView(context: Context) -> UIView { view }
  func updateUIView(_ uiView: UIView, context: Context) {}
}
