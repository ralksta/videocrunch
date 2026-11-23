import XCTest
@testable import VideoCrunch

final class LocalizationTests: XCTestCase {
    private let expectedCodes = [
        "de", "en", "en-GB", "es", "fr", "it", "nl", "pl", "pt-PT", "pt-BR", "ja"
    ]

    override func tearDown() {
        L10n.languageOverride = nil
        super.tearDown()
    }

    func testAllElevenLocalesExistAndHaveIdenticalKeys() throws {
        XCTAssertEqual(Set(L10n.supportedCodes), Set(expectedCodes))
        let explicitLanguages = AppLanguage.all.filter { !$0.code.isEmpty }
        XCTAssertEqual(explicitLanguages.count, expectedCodes.count)
        XCTAssertTrue(AppLanguage.all.contains { $0.code.isEmpty })

        var tables: [String: [String: String]] = [:]
        for code in expectedCodes {
            let lprojPath = try XCTUnwrap(
                L10n.rootBundle.path(forResource: code, ofType: "lproj"),
                "Missing .lproj bundle for \(code)"
            )
            let stringsPath = (lprojPath as NSString).appendingPathComponent("Localizable.strings")
            let rawDict = try XCTUnwrap(
                NSDictionary(contentsOfFile: stringsPath) as? [String: String],
                "Failed to load Localizable.strings for \(code)"
            )
            tables[code] = rawDict
        }

        let reference = try XCTUnwrap(tables["en"])
        XCTAssertGreaterThanOrEqual(reference.count, 500)
        let refKeys = Set(reference.keys)

        for code in expectedCodes {
            let dict = try XCTUnwrap(tables[code])
            let keys = Set(dict.keys)
            XCTAssertEqual(keys, refKeys, "Key mismatch in locale \(code)")

            for (key, value) in dict {
                XCTAssertFalse(
                    value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                    "Empty value for key '\(key)' in locale \(code)"
                )
            }
        }
    }

    func testFormatSpecifiersMatchReferenceAcrossAllLocales() throws {
        var tables: [String: [String: String]] = [:]
        for code in expectedCodes {
            let lprojPath = try XCTUnwrap(L10n.rootBundle.path(forResource: code, ofType: "lproj"))
            let stringsPath = (lprojPath as NSString).appendingPathComponent("Localizable.strings")
            tables[code] = try XCTUnwrap(NSDictionary(contentsOfFile: stringsPath) as? [String: String])
        }

        let reference = try XCTUnwrap(tables["en"])
        for (key, refValue) in reference {
            let expectedSpecs = extractSpecifiers(from: refValue)
            for code in expectedCodes where code != "en" {
                let localized = try XCTUnwrap(tables[code]?[key])
                let actualSpecs = extractSpecifiers(from: localized)
                XCTAssertEqual(
                    actualSpecs,
                    expectedSpecs,
                    "Format specifier mismatch for key '\(key)' in locale '\(code)': \(localized) vs \(refValue)"
                )
            }
        }
    }

    func testLiveLanguageSwitchingAndUKVariants() {
        L10n.languageOverride = "en"
        let enBadge = L("settings.privacy.badge")
        let enCompleted = L("completed.optimized_badge")
        let enPreset = EncodePreset.builtIn.first { $0.id == "builtin.archive" }?.name

        L10n.languageOverride = "en-GB"
        let gbCompleted = L("completed.optimized_badge")
        let gbAnalyze = L("scan.running.title")

        L10n.languageOverride = "de"
        let deBadge = L("settings.privacy.badge")
        let dePreset = EncodePreset.builtIn.first { $0.id == "builtin.archive" }?.name

        XCTAssertEqual(deBadge, "100 % lokal · Kostenlos · Kein Tracking")
        XCTAssertNotEqual(enBadge, deBadge)
        XCTAssertEqual(enCompleted, "Optimized")
        XCTAssertEqual(gbCompleted, "Optimised")
        XCTAssertTrue(gbAnalyze.contains("Analys"), "Expected British spelling, got: \(gbAnalyze)")
        XCTAssertNotEqual(enPreset, dePreset)

        for code in expectedCodes {
            L10n.languageOverride = code
            let translated = L("settings.privacy.badge")
            XCTAssertNotEqual(translated, "settings.privacy.badge", "Fallback to raw key in \(code)")
            XCTAssertFalse(translated.isEmpty)
        }
    }

    private func extractSpecifiers(from text: String) -> [String] {
        // Strip literal escaped percent signs (%%) before matching conversion specifiers.
        // Omit the space flag so prose like "100% original" is not mistaken for `% o`.
        let unescaped = text.replacingOccurrences(of: "%%", with: "")
        guard let regex = try? NSRegularExpression(
            pattern: "%[-+#0]*(?:\\d+|\\*)?(?:\\.(?:\\d+|\\*))?(?:hh|h|ll|l|q|z|t|j)?[@dDuUxXoOfeEgGcCsSpaAF]"
        ) else {
            return []
        }
        let nsRange = NSRange(unescaped.startIndex..<unescaped.endIndex, in: unescaped)
        return regex.matches(in: unescaped, range: nsRange).compactMap { match in
            Range(match.range, in: unescaped).map { String(unescaped[$0]) }
        }
    }
}
