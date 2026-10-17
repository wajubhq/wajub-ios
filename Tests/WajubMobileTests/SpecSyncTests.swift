import XCTest
@testable import WajubMobile

/// SY — the synced copies of the contract's fixtures and data are untouched.
final class SpecSyncTests: XCTestCase {
    /// SY-01 uses the synced spec files
    func test_SY_01_usesTheSyncedSpecFiles() throws {
        let root = Fixtures.packageRoot
        let manifest = try String(contentsOf: root.appendingPathComponent("Tests/WajubMobileTests/Fixtures/spec.sha256"), encoding: .utf8)
        let lines = manifest.split(separator: "\n").filter { !$0.isEmpty }
        XCTAssertEqual(lines.count, 110, "108 fixtures, the vectors and the data file")
        for line in lines {
            let parts = line.split(separator: " ", omittingEmptySubsequences: true)
            XCTAssertEqual(parts.count, 2, String(line))
            let path = String(parts[1])
            let url = root.appendingPathComponent(path)
            guard let data = try? Data(contentsOf: url) else {
                XCTFail("missing \(path)")
                continue
            }
            XCTAssertEqual(Digest.sha256Hex(data), String(parts[0]), "\(path) differs from the spec: run sync-spec.sh ios")
        }
    }

    func test_sha256MatchesTheStandardVectors() {
        XCTAssertEqual(Digest.sha256Hex(""), "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
        XCTAssertEqual(Digest.sha256Hex("abc"), "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
        XCTAssertEqual(Digest.sha256Hex(String(repeating: "a", count: 1000)),
                       "41edece42d63e8d9bf515a9ba6932e1c20cbc9f5a5d134645adb5db1b9737ea3")
    }
}
