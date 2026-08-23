import XCTest
@testable import PDFIt

final class LocalizationAndProductTests: XCTestCase {

    // MARK: - External Links Tests

    func testExternalLinksAreValidHttpsURLs() {
        let privacy = ExternalLinks.privacyPolicy
        let terms = ExternalLinks.termsOfUse
        let support = ExternalLinks.support

        XCTAssertEqual(privacy.scheme, "https")
        XCTAssertEqual(terms.scheme, "https")
        XCTAssertEqual(support.scheme, "https")

        XCTAssertFalse(privacy.host?.isEmpty ?? true)
        XCTAssertFalse(terms.host?.isEmpty ?? true)
        XCTAssertFalse(support.host?.isEmpty ?? true)

        XCTAssertTrue(privacy.absoluteString.contains("privacy"))
        XCTAssertTrue(terms.absoluteString.contains("terms"))
        XCTAssertTrue(support.absoluteString.contains("issues") || support.absoluteString.contains("support"))
    }

    // MARK: - Privacy Manifest Tests

    func testPrivacyManifestStructureAndCategories() throws {
        // Load PrivacyInfo.xcprivacy from Config or Bundle
        let bundle = Bundle(for: Self.self)
        let manifestURL = bundle.url(forResource: "PrivacyInfo", withExtension: "xcprivacy")
            ?? URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .appendingPathComponent("Config/PrivacyInfo.xcprivacy")

        XCTAssertTrue(FileManager.default.fileExists(atPath: manifestURL.path),
                      "Privacy manifest should exist at \(manifestURL.path)")

        let data = try Data(contentsOf: manifestURL)
        guard let plist = try PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any] else {
            XCTFail("Privacy manifest could not be deserialized as dictionary")
            return
        }

        // Must not track
        let tracking = plist["NSPrivacyTracking"] as? Bool
        XCTAssertEqual(tracking, false, "NSPrivacyTracking must be false")

        // Tracking domains must be empty
        let trackingDomains = plist["NSPrivacyTrackingDomains"] as? [String]
        XCTAssertEqual(trackingDomains?.count, 0, "NSPrivacyTrackingDomains must be empty")

        // Collected data types must be empty
        let collectedTypes = plist["NSPrivacyCollectedDataTypes"] as? [[String: Any]]
        XCTAssertEqual(collectedTypes?.count, 0, "NSPrivacyCollectedDataTypes must be empty")

        // Accessed API Types must declare UserDefaults, FileTimestamp, DiskSpace
        guard let accessedTypes = plist["NSPrivacyAccessedAPITypes"] as? [[String: Any]] else {
            XCTFail("NSPrivacyAccessedAPITypes must be present")
            return
        }

        let typeCategories = accessedTypes.compactMap { $0["NSPrivacyAccessedAPIType"] as? String }
        XCTAssertTrue(typeCategories.contains("NSPrivacyAccessedAPICategoryUserDefaults"), "Must declare UserDefaults API")
        XCTAssertTrue(typeCategories.contains("NSPrivacyAccessedAPICategoryFileTimestamp"), "Must declare FileTimestamp API")
        XCTAssertTrue(typeCategories.contains("NSPrivacyAccessedAPICategoryDiskSpace"), "Must declare DiskSpace API")

        // Verify reason codes
        for item in accessedTypes {
            let reasons = item["NSPrivacyAccessedAPITypeReasons"] as? [String]
            XCTAssertNotNil(reasons)
            XCTAssertFalse(reasons?.isEmpty ?? true)
        }
    }

    // MARK: - Localization Catalog Tests

    func testLocalizableStringsCatalogCompleteFor5Locales() throws {
        let bundle = Bundle(for: Self.self)
        let catalogURL = bundle.url(forResource: "Localizable", withExtension: "xcstrings")
            ?? URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .appendingPathComponent("Shared/Resources/Localizable.xcstrings")

        XCTAssertTrue(FileManager.default.fileExists(atPath: catalogURL.path),
                      "Localizable.xcstrings must exist at \(catalogURL.path)")

        let data = try Data(contentsOf: catalogURL)
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            XCTFail("Localizable.xcstrings is not valid JSON")
            return
        }

        let sourceLanguage = json["sourceLanguage"] as? String
        XCTAssertEqual(sourceLanguage, "en", "sourceLanguage must be en")

        let strings = json["strings"] as? [String: [String: Any]]
        XCTAssertNotNil(strings)
        XCTAssertFalse(strings?.isEmpty ?? true)

        let requiredLocales = ["en", "fr", "es", "de", "it"]

        for (key, entry) in strings! {
            guard let localizations = entry["localizations"] as? [String: Any] else {
                XCTFail("Key '\(key)' is missing localizations dictionary")
                continue
            }

            for locale in requiredLocales {
                guard let localeEntry = localizations[locale] as? [String: Any] else {
                    XCTFail("Key '\(key)' is missing locale '\(locale)'")
                    continue
                }

                if let stringUnit = localeEntry["stringUnit"] as? [String: Any] {
                    let value = stringUnit["value"] as? String
                    XCTAssertNotNil(value, "Key '\(key)' in locale '\(locale)' has nil stringUnit value")
                    XCTAssertFalse(value?.isEmpty ?? true, "Key '\(key)' in locale '\(locale)' has empty stringUnit value")
                } else if let variations = localeEntry["variations"] as? [String: Any] {
                    let plural = variations["plural"] as? [String: Any]
                    XCTAssertNotNil(plural, "Key '\(key)' in locale '\(locale)' has neither stringUnit nor plural variations")
                } else {
                    XCTFail("Key '\(key)' in locale '\(locale)' has neither stringUnit nor variations")
                }
            }
        }
    }

    func testPluralizationKeysPresentInCatalog() throws {
        let catalogURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Shared/Resources/Localizable.xcstrings")

        let data = try Data(contentsOf: catalogURL)
        let json = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        let strings = json["strings"] as! [String: [String: Any]]

        let requiredPluralKeys = [
            "plural.pages %lld",
            "plural.images %lld",
            "plural.items %lld",
            "plural.files %lld",
            "plural.text_items %lld",
            "plural.skipped_media_notice %lld"
        ]

        for key in requiredPluralKeys {
            XCTAssertNotNil(strings[key], "Catalog missing required plural key: \(key)")
            if let entry = strings[key], let locs = entry["localizations"] as? [String: Any] {
                for loc in ["en", "fr", "es", "de", "it"] {
                    let locEntry = locs[loc] as? [String: Any]
                    XCTAssertNotNil(locEntry, "Plural key \(key) missing locale \(loc)")
                    let variations = locEntry?["variations"] as? [String: Any]
                    let plural = variations?["plural"] as? [String: Any]
                    XCTAssertNotNil(plural, "Plural variations missing for \(key) in \(loc)")
                }
            }
        }
    }

    // MARK: - Option & Error Localization Tests

    func testConversionModesHaveDisplayNames() {
        for mode in ConversionMode.allCases {
            XCTAssertFalse(mode.displayName.isEmpty)
            XCTAssertFalse(mode.description.isEmpty)
        }
    }

    func testPaperSizesHaveDisplayNames() {
        for size in PDFPaperSize.allCases {
            XCTAssertFalse(size.displayName.isEmpty)
        }
    }

    func testImageQualitiesHaveDisplayNames() {
        for quality in ImageQuality.allCases {
            XCTAssertFalse(quality.displayName.isEmpty)
        }
    }

    func testConversionErrorsHaveHeadlinesAndMessages() {
        let errors: [ConversionError] = [
            .noUsableContent,
            .someContentSkipped,
            .fileTooLarge(name: "large.jpg"),
            .unreadableFile(name: "corrupt.png"),
            .invalidURL,
            .pageUnreachable(reason: "offline"),
            .pageTooSlow,
            .webProcessTerminated,
            .generationFailed,
            .cancelled
        ]

        for error in errors {
            XCTAssertFalse(error.headline.isEmpty)
            XCTAssertFalse(error.message.isEmpty)
            for action in error.recoveryActions {
                XCTAssertFalse(action.title.isEmpty)
            }
        }
    }

    func testStorageErrorHasDescription() {
        let error1 = StorageError.containerUnavailable
        let error2 = StorageError.writeFailed(underlying: "disk full")

        XCTAssertNotNil(error1.errorDescription)
        XCTAssertNotNil(error2.errorDescription)
        XCTAssertFalse(error1.errorDescription?.isEmpty ?? true)
        XCTAssertFalse(error2.errorDescription?.isEmpty ?? true)
    }

    // MARK: - Filename Date Formatting Test

    func testFilenameDateFormattingIsLocaleAware() {
        let doc = ConvertedDocument(data: Data(),
                                    pageCount: 1,
                                    suggestedTitle: "Photos",
                                    sourceURL: nil,
                                    source: .photos)
        let testDate = Date(timeIntervalSince1970: 1787395200) // 2026-08-22

        let enName = FilenameGenerator.baseName(for: doc, date: testDate, locale: Locale(identifier: "en_US"))
        let frName = FilenameGenerator.baseName(for: doc, date: testDate, locale: Locale(identifier: "fr_FR"))
        let deName = FilenameGenerator.baseName(for: doc, date: testDate, locale: Locale(identifier: "de_DE"))

        XCTAssertTrue(enName.contains("2026"), "En name must contain year: \(enName)")
        XCTAssertTrue(frName.contains("2026"), "Fr name must contain year: \(frName)")
        XCTAssertTrue(deName.contains("2026"), "De name must contain year: \(deName)")
    }
}
