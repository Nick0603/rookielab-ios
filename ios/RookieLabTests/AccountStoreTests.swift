import XCTest
@testable import RookieLab

@MainActor
final class AccountStoreTests: XCTestCase {
  override func setUp() { AccountStore.save([]); AccountStore.current = nil }

  func testSwitchKeepsOrderAndRemoveFallsBack() {
    let app = AppModel()
    let a = Account(platform: .chesscom, username: "a"), b = Account(platform: .lichess, username: "b")
    app.use(a)
    app.use(b)
    XCTAssertEqual(app.accounts.map(\.username), ["b", "a"])
    app.use(a)
    XCTAssertEqual(app.accounts.map(\.username), ["b", "a"], "切換不改順序")
    XCTAssertEqual(AccountStore.current?.username, "a")
    app.remove(a)
    XCTAssertEqual(app.account?.username, "b", "刪掉目前的帳號換到下一個")
    app.remove(b)
    XCTAssertNil(app.account, "都刪光回到第一次使用")
    XCTAssertTrue(app.accounts.isEmpty)
  }
}
