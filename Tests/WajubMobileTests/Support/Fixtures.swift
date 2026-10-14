import Foundation
import XCTest
@testable import WajubMobile

/// The contract's fixtures, as synced into `Tests/WajubMobileTests/Fixtures` by `sync-spec.sh`.
enum Fixtures {
    static var directory: URL {
        Bundle.module.url(forResource: "Fixtures", withExtension: nil)!
    }

    /// Every fixture file name, without `.json` (the vectors excluded).
    static var allNames: [String] {
        let files = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        return files.filter { $0.hasSuffix(".json") && $0 != "mobile-money.vectors.json" }
            .map { String($0.dropLast(5)) }.sorted()
    }

    static func envelope(_ name: String) -> JSONValue {
        let url = directory.appendingPathComponent(name.hasSuffix(".json") ? name : name + ".json")
        guard let data = try? Data(contentsOf: url), let json = try? JSONValue.parse(data) else {
            fatalError("missing fixture \(name)")
        }
        return json
    }

    static func body(_ name: String) -> JSONValue {
        let envelope = envelope(name)
        return envelope["body"] ?? envelope["data"] ?? .null
    }

    static func status(_ name: String) -> Int {
        envelope(name)["http_status"]?.int ?? 200
    }

    static func headers(_ name: String) -> [String: String] {
        var headers: [String: String] = [:]
        for (key, value) in envelope(name)["response_headers"]?.object ?? [:] { headers[key] = value.string }
        return headers
    }

    static var vectors: JSONValue {
        envelope("mobile-money.vectors")
    }

    static func session(_ name: String) -> SessionResponse {
        try! SessionResponse(json: body(name))
    }

    static func config(_ name: String) -> SdkConfigResponse {
        SdkConfigResponse(json: body(name))
    }

    /// The SDK repository's root, for the spec-sync check.
    static var packageRoot: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
    }
}

extension JSONValue {
    /// A copy with `value` set at `path` (object keys; `"0"`, `"1"`… index arrays). `nil` removes the key.
    func setting(_ path: [String], to value: JSONValue?) -> JSONValue {
        guard let head = path.first else { return value ?? .null }
        let rest = Array(path.dropFirst())
        switch self {
        case .object(var members):
            if rest.isEmpty {
                members[head] = value
            } else {
                members[head] = (members[head] ?? .object([:])).setting(rest, to: value)
            }
            return .object(members)
        case .array(var items):
            guard let index = Int(head), items.indices.contains(index) else { return self }
            items[index] = rest.isEmpty ? (value ?? .null) : items[index].setting(rest, to: value)
            return .array(items)
        default:
            return self
        }
    }
}
