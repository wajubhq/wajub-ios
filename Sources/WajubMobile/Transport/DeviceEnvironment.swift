import Foundation
#if canImport(UIKit) && os(iOS)
import UIKit
#endif

/// The SDK's version.
public enum WajubSDK {
    public static let version = "1.1.0"
    /// The version of Wajub's mobile checkout this SDK supports.
    public static let specVersion = "2.1"
    static let name = "ios"
    /// `https://api.wajub.com`, for both environments.
    static let apiURL = URL(string: "https://api.wajub.com")!
}

/// What the SDK says about the device (README §2.2–2.3).
struct DeviceEnvironment: Sendable {
    /// `ios` on iPhone and iPad; the SDK also runs its tests on `macos` and `linux`.
    var platform: String
    var osVersion: String
    /// BCP 47 tags with region, most preferred first.
    var preferredLanguages: [String]
    var timeZone: String
    /// `<app name>/<app version>`, the start of the `User-Agent`.
    var appUserAgent: String?
    /// `<width>x<height>` of the main display in physical pixels, portrait.
    var screen: @Sendable () async -> String
    var installIDStore: InstallIDStore

    static var current: DeviceEnvironment {
        let version = ProcessInfo.processInfo.operatingSystemVersion
        var osVersion = "\(version.majorVersion).\(version.minorVersion)"
        if version.patchVersion > 0 { osVersion += ".\(version.patchVersion)" }
        #if os(iOS)
        let platform = "ios"
        #elseif os(macOS)
        let platform = "macos"
        #elseif os(Linux)
        let platform = "linux"
        #else
        let platform = "ios"
        #endif
        let info = Bundle.main.infoDictionary
        var appUserAgent: String?
        if let name = (info?["CFBundleName"] as? String) ?? (info?["CFBundleExecutable"] as? String) {
            let appVersion = (info?["CFBundleShortVersionString"] as? String) ?? "0"
            appUserAgent = "\(name.replacingOccurrences(of: " ", with: ""))/\(appVersion)"
        }
        return DeviceEnvironment(platform: platform, osVersion: osVersion, preferredLanguages: Locale.preferredLanguages,
                                 timeZone: TimeZone.current.identifier, appUserAgent: appUserAgent,
                                 screen: { await DeviceEnvironment.mainScreen() }, installIDStore: FileInstallIDStore.standard)
    }

    /// `wajub-ios/1.1.0 (ios 18.1)`.
    var clientIdentifier: String {
        "wajub-\(WajubSDK.name)/\(WajubSDK.version) (\(platform) \(osVersion))"
    }

    /// The platform's own `User-Agent` start followed by `clientIdentifier`.
    var userAgent: String {
        [appUserAgent, clientIdentifier].compactMap { $0 }.joined(separator: " ")
    }

    /// The device's first language, e.g. `fr-CM`.
    var language: String {
        preferredLanguages.first ?? "en"
    }

    /// `fr-CM, fr;q=0.9, en;q=0.8`: each language followed by its base language, with decreasing weights.
    var acceptLanguage: String {
        var tags: [String] = []
        for tag in preferredLanguages.isEmpty ? ["en"] : preferredLanguages {
            let base = String(tag.split(separator: "-").first ?? Substring(tag))
            for candidate in [tag, base] where !tags.contains(candidate) {
                tags.append(candidate)
            }
        }
        return tags.enumerated().map { index, tag in
            guard index > 0 else { return tag }
            let weight = max(1.0 - Double(index) / 10.0, 0.1)
            return "\(tag);q=\(String(format: "%.1f", weight))"
        }.joined(separator: ", ")
    }

    /// The `data._client` object sent with every `POST /pay/process`.
    func clientSignals() async -> JSONValue {
        let screen = await screen()
        return .object([
            "timezone": .string(timeZone),
            "language": .string(language),
            "screen": .string(screen),
            "color_depth": .number(24),
            "fingerprint": .string(InstallFingerprint.value(store: installIDStore)),
            "client": .string(clientIdentifier),
        ])
    }

    private static func mainScreen() async -> String {
        #if canImport(UIKit) && os(iOS)
        let bounds = await MainActor.run { UIScreen.main.nativeBounds }
        let width = Int(min(bounds.width, bounds.height))
        let height = Int(max(bounds.width, bounds.height))
        return "\(width)x\(height)"
        #else
        return "0x0"
        #endif
    }
}

/// Where the install's random id is kept.
protocol InstallIDStore: Sendable {
    func read() -> String?
    func write(_ id: String)
}

/// A file in the app's Application Support directory: private to the app, kept across updates.
struct FileInstallIDStore: InstallIDStore {
    let fileURL: URL

    static var standard: FileInstallIDStore {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return FileInstallIDStore(fileURL: base.appendingPathComponent("com.wajub.mobile", isDirectory: true)
            .appendingPathComponent("install-id"))
    }

    func read() -> String? {
        guard let data = try? Data(contentsOf: fileURL) else { return nil }
        let text = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return UUID(uuidString: text) == nil ? nil : text
    }

    func write(_ id: String) {
        let directory = fileURL.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? Data(id.utf8).write(to: fileURL, options: .atomic)
        #if canImport(Darwin)
        var url = fileURL
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? url.setResourceValues(values)
        #endif
    }
}

/// The install fingerprint: hex SHA-256 of `"device:" + <a UUID generated once and stored>`.
/// Never derived from a hardware or advertising identifier.
enum InstallFingerprint {
    private static let lock = NSLock()

    static func value(store: InstallIDStore) -> String {
        lock.lock()
        defer { lock.unlock() }
        let id: String
        if let stored = store.read() {
            id = stored
        } else {
            id = UUID().uuidString.lowercased()
            store.write(id)
        }
        return Digest.sha256Hex("device:" + id)
    }
}
