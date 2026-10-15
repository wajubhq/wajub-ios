import XCTest
@testable import WajubMobile

/// `PrivacyInfo.xcprivacy` says what the SDK uses and collects, with Apple's documented values only.
final class PrivacyManifestTests: XCTestCase {
    /// Apple's `NSPrivacyAccessedAPIType` categories, with the APIs each one covers.
    private static let requiredReasonAPIs: [String: [String]] = [
        "NSPrivacyAccessedAPICategoryUserDefaults": ["UserDefaults"],
        "NSPrivacyAccessedAPICategorySystemBootTime": ["systemUptime", "mach_absolute_time"],
        "NSPrivacyAccessedAPICategoryFileTimestamp": [".creationDate", ".modificationDate", "fileModificationDate",
                                                      "contentModificationDateKey", "creationDateKey", "getattrlist",
                                                      "fstat(", "fstatat(", "lstat(", " stat("],
        "NSPrivacyAccessedAPICategoryDiskSpace": ["volumeAvailableCapacity", "volumeTotalCapacity", "systemFreeSize",
                                                  ".systemSize", "statfs(", "statvfs("],
        "NSPrivacyAccessedAPICategoryActiveKeyboards": ["activeInputModes"],
    ]

    /// Apple's `NSPrivacyCollectedDataType` values.
    private static let dataTypes: Set<String> = [
        "Name", "EmailAddress", "PhoneNumber", "PhysicalAddress", "OtherUserContactInfo", "Health", "Fitness",
        "PaymentInfo", "CreditInfo", "OtherFinancialInfo", "PreciseLocation", "CoarseLocation", "SensitiveInfo",
        "Contacts", "EmailsOrTextMessages", "PhotosorVideos", "AudioData", "GameplayContent", "CustomerSupport",
        "OtherUserContent", "BrowsingHistory", "SearchHistory", "UserID", "DeviceID", "PurchaseHistory",
        "ProductInteraction", "AdvertisingData", "OtherUsageData", "CrashData", "PerformanceData",
        "OtherDiagnosticData", "EnvironmentScanning", "Hands", "Head", "OtherDataTypes",
    ].reduce(into: Set<String>()) { $0.insert("NSPrivacyCollectedDataType" + $1) }

    /// Apple's `NSPrivacyCollectedDataTypePurposes` values.
    private static let purposes: Set<String> = [
        "ThirdPartyAdvertising", "DeveloperAdvertising", "Analytics", "ProductPersonalization", "AppFunctionality", "Other",
    ].reduce(into: Set<String>()) { $0.insert("NSPrivacyCollectedDataTypePurpose" + $1) }

    private func manifest() throws -> [String: Any] {
        let url = Fixtures.packageRoot.appendingPathComponent("Sources/WajubMobile/PrivacyInfo.xcprivacy")
        let plist = try PropertyListSerialization.propertyList(from: Data(contentsOf: url), options: [], format: nil)
        return try XCTUnwrap(plist as? [String: Any])
    }

    func test_privacyManifestDeclaresNoTracking() throws {
        let manifest = try manifest()
        XCTAssertEqual(manifest["NSPrivacyTracking"] as? Bool, false)
        XCTAssertEqual((manifest["NSPrivacyTrackingDomains"] as? [Any])?.count, 0)
        let package = try String(contentsOf: Fixtures.packageRoot.appendingPathComponent("Package.swift"), encoding: .utf8)
        XCTAssertTrue(package.contains(#".copy("PrivacyInfo.xcprivacy")"#), "shipped as a resource of WajubMobile")
    }

    func test_privacyManifestDeclaresTheRequiredReasonAPIsTheSourcesUse() throws {
        let declared = try XCTUnwrap(manifest()["NSPrivacyAccessedAPITypes"] as? [[String: Any]])
        var reasons: [String: [String]] = [:]
        for entry in declared {
            let category = try XCTUnwrap(entry["NSPrivacyAccessedAPIType"] as? String)
            XCTAssertNotNil(Self.requiredReasonAPIs[category], "\(category) is not one of Apple's categories")
            reasons[category] = entry["NSPrivacyAccessedAPITypeReasons"] as? [String]
        }
        // Only the system boot time, to measure elapsed time for timers (35F9.1: never sent off the device).
        XCTAssertEqual(reasons, ["NSPrivacyAccessedAPICategorySystemBootTime": ["35F9.1"]])

        // Every category the sources use is declared, and only those.
        var used: Set<String> = []
        let sources = Fixtures.packageRoot.appendingPathComponent("Sources")
        let files = FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil)?
            .compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" } ?? []
        XCTAssertGreaterThan(files.count, 20)
        for file in files {
            let text = try String(contentsOf: file, encoding: .utf8)
            for (category, apis) in Self.requiredReasonAPIs where apis.contains(where: text.contains) {
                used.insert(category)
            }
        }
        XCTAssertEqual(used, Set(reasons.keys))
    }

    func test_privacyManifestDeclaresTheCollectedData() throws {
        let collected = try XCTUnwrap(manifest()["NSPrivacyCollectedDataTypes"] as? [[String: Any]])
        var types: [String] = []
        for entry in collected {
            let type = try XCTUnwrap(entry["NSPrivacyCollectedDataType"] as? String)
            XCTAssertTrue(Self.dataTypes.contains(type), "\(type) is not one of Apple's data types")
            XCTAssertEqual(entry["NSPrivacyCollectedDataTypeLinked"] as? Bool, true, "\(type): sent with the payment")
            XCTAssertEqual(entry["NSPrivacyCollectedDataTypeTracking"] as? Bool, false, type)
            XCTAssertEqual(entry["NSPrivacyCollectedDataTypePurposes"] as? [String],
                           ["NSPrivacyCollectedDataTypePurposeAppFunctionality"], type)
            for purpose in entry["NSPrivacyCollectedDataTypePurposes"] as? [String] ?? [] {
                XCTAssertTrue(Self.purposes.contains(purpose), purpose)
            }
            types.append(type)
        }
        // The payer's details the forms send, and `data._client` (the install fingerprint; time zone,
        // language and screen as other data).
        XCTAssertEqual(types, ["Name", "EmailAddress", "PhoneNumber", "PhysicalAddress", "PaymentInfo", "DeviceID", "OtherDataTypes"]
            .map { "NSPrivacyCollectedDataType" + $0 })
    }

    func test_privacyManifestCoversTheDeviceSignals() async throws {
        // `data._client`: the install fingerprint (DeviceID); time zone, language and screen (other data).
        let signals = await DeviceEnvironment.test().clientSignals()
        XCTAssertEqual(signals.object?.keys.sorted(), ["client", "color_depth", "fingerprint", "language", "screen", "timezone"],
                       "a new device signal needs PrivacyInfo.xcprivacy and the README's Privacy section checked")
    }
}
