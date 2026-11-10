// 首頁 Banner（AdMob）。正式版用正式版位；Debug、模擬器與自己裝的版本只用 Google 測試版位，避免無效流量。
#if canImport(GoogleMobileAds) && canImport(UserMessagingPlatform)
import GoogleMobileAds
import UserMessagingPlatform
import UIKit

@MainActor final class AdMobPilot: NSObject, SingleGameAdProvider, BannerViewDelegate {
  static let shared = AdMobPilot()
  private var banner: BannerView?
  private var started = false
  private var bannerContinuation: CheckedContinuation<SingleGameAdvertisement?, Error>?
  private func event(_ name: String, _ extra: [String: Any] = [:]) {
    var values = extra
    values["ad_format"] = "banner"; values["provider"] = "admob"; values["test_ad"] = Self.testAds
    values["placement"] = "home"
    Telemetry.log(name, values)
  }
  private var controller: UIViewController? {
    let scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first { $0.activationState == .foregroundActive }
    var vc = scene?.windows.first { $0.isKeyWindow }?.rootViewController
    while let next = vc?.presentedViewController { vc = next }
    return vc
  }
  private func prepare() async throws {
    guard Premium.shared.entitlementReady, !Premium.shared.active else { throw CancellationError() }
    if !started {
      do {
        try await ConsentInformation.shared.requestConsentInfoUpdate(with: RequestParameters())
        try await ConsentForm.loadAndPresentIfRequired(from: controller)
      } catch {
        let e = error as NSError
        event("ad_load_failed", ["stage": "consent", "error_code": e.code])
        AppLog.add("ads", "consent \(e.domain) \(e.code) \(e.localizedDescription)")
        NSLog("[RookieLabAds] consent error %@ %ld %@", e.domain, e.code, e.localizedDescription)
        // 照 Google 範例：更新失敗時，若先前已取得可請求廣告的同意狀態就照常載入
      }
      guard ConsentInformation.shared.canRequestAds else {
        event("ad_skipped", ["reason": "consent_status_\(ConsentInformation.shared.consentStatus.rawValue)"])
        NSLog("[RookieLabAds] cannot request ads, consent status %ld", ConsentInformation.shared.consentStatus.rawValue)
        throw CancellationError()
      }
      await MobileAds.shared.start()
      started = true
    }
    guard !Premium.shared.active, Premium.shared.entitlementReady, ConsentInformation.shared.canRequestAds else { throw CancellationError() }
  }
  static var testAds: Bool {
    #if DEBUG || DEVINSTALL || targetEnvironment(simulator)
    return true
    #else
    return false
    #endif
  }
  func load() async throws -> SingleGameAdvertisement? {
    try await prepare()
    event("ad_request")
    let view = BannerView(adSize: AdSizeBanner)
    view.adUnitID = Self.testAds ? "ca-app-pub-3940256099942544/2934735716" : "ca-app-pub-5287756452662687/5394414908"
    view.rootViewController = controller; view.delegate = self; banner = view
    return try await withCheckedThrowingContinuation { continuation in
      bannerContinuation = continuation; view.load(Request())
    }
  }
  func bannerViewDidReceiveAd(_ bannerView: BannerView) {
    event("ad_loaded")
    let ad = SingleGameAdvertisement(id: Self.testAds ? "admob-test-banner" : "admob-banner", sponsor: "Google", message: "Ad", destination: URL(string: "https://ads.google.com/")!)
    bannerContinuation?.resume(returning: ad); bannerContinuation = nil
  }
  func bannerView(_ bannerView: BannerView, didFailToReceiveAdWithError error: Error) {
    event("ad_load_failed", ["error_code": (error as NSError).code])
    bannerContinuation?.resume(throwing: error); bannerContinuation = nil; banner = nil
  }
  func bannerViewDidRecordImpression(_ bannerView: BannerView) { event("ad_impression") }
  func bannerViewDidRecordClick(_ bannerView: BannerView) { event("ad_click") }
  func bannerView(for advertisement: SingleGameAdvertisement) -> UIView? { banner }
  func privacyOptions() async throws { try await ConsentForm.presentPrivacyOptionsForm(from: controller) }
}
#endif
