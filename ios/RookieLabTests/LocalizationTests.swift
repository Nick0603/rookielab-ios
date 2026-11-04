import XCTest
@testable import RookieLab

final class LocalizationTests: XCTestCase {
  private func table(_ lang: String) throws -> Bundle {
    let path = try XCTUnwrap(Bundle.main.path(forResource: lang, ofType: "lproj"), "\(lang) 沒有被編進 App")
    return try XCTUnwrap(Bundle(path: path))
  }

  func testTerms() throws {
    let cases: [(key: String, en: String, es: String, pt: String)] = [
      ("將軍", "Check", "Jaque", "Xeque"),
      ("捉雙", "Fork", "Horquilla", "Garfo"),
      ("牽制", "Pin", "Clavada", "Cravada"),
      ("串打", "Skewer", "Enfilada", "Espeto"),
      ("嚴重失誤", "Blunder", "Error grave", "Erro grave"),
      ("入堡（短）", "Castles kingside", "Enroque corto", "Roque pequeno"),
    ]
    let en = try table("en"), es = try table("es"), pt = try table("pt-BR")
    for c in cases {
      XCTAssertEqual(NSLocalizedString(c.key, bundle: en, comment: ""), c.en)
      XCTAssertEqual(NSLocalizedString(c.key, bundle: es, comment: ""), c.es)
      XCTAssertEqual(NSLocalizedString(c.key, bundle: pt, comment: ""), c.pt)
    }
  }

  func testPlural() throws {
    let en = try table("en")
    let one = String.localizedStringWithFormat(NSLocalizedString("%lld 局", bundle: en, comment: ""), 1)
    let many = String.localizedStringWithFormat(NSLocalizedString("%lld 局", bundle: en, comment: ""), 3)
    XCTAssertEqual(one, "1 game")
    XCTAssertEqual(many, "3 games")
  }

  func testDefaultsToChinese() throws {
    try XCTSkipUnless(Locale.preferredLanguages.first?.hasPrefix("zh") ?? false)
    XCTAssertEqual(AppLang.code, "zh")
    XCTAssertEqual(String(localized: "將軍"), "將軍")
  }
}
