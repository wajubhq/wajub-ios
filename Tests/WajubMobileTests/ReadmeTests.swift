import XCTest

/// The README's Swift samples are the ones `ci/swift6-host` compiles in Swift 6 mode, so they can't drift
/// from the API.
final class ReadmeTests: XCTestCase {
    func test_readmeSwiftSamplesAreTheCompiledOnes() throws {
        let root = Fixtures.packageRoot
        let readme = try String(contentsOf: root.appendingPathComponent("README.md"), encoding: .utf8)
        let samples = root.appendingPathComponent("ci/swift6-host/Sources/Swift6Host/Readme")
        let files = try FileManager.default.contentsOfDirectory(at: samples, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "swift" }
            .map { try Self.lines(String(contentsOf: $0, encoding: .utf8)) }
        XCTAssertFalse(files.isEmpty)

        let blocks = Self.swiftBlocks(readme)
        XCTAssertEqual(blocks.count, 5, "a new Swift sample needs its copy in ci/swift6-host/Sources/Swift6Host/Readme")
        for block in blocks {
            // The SwiftPM manifest excerpt is not app code.
            if block.contains(".package(url:") { continue }
            let lines = Self.lines(block)
            XCTAssertTrue(files.contains { Self.contains($0, lines) },
                          "README sample not compiled as written:\n\(block)")
        }
    }

    /// The ```swift blocks of a Markdown text.
    private static func swiftBlocks(_ markdown: String) -> [String] {
        var blocks: [String] = []
        var current: [Substring]?
        for line in markdown.split(separator: "\n", omittingEmptySubsequences: false) {
            if current == nil, line == "```swift" {
                current = []
            } else if current != nil, line == "```" {
                blocks.append(current!.joined(separator: "\n"))
                current = nil
            } else {
                current?.append(line)
            }
        }
        return blocks
    }

    /// Trimmed, non-empty lines, without those marked `// wrapper` (code giving a sample a home) and
    /// without the samples files' header comments.
    private static func lines(_ text: String) -> [String] {
        text.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasSuffix("// wrapper") }
    }

    private static func contains(_ haystack: [String], _ needle: [String]) -> Bool {
        guard !needle.isEmpty, needle.count <= haystack.count else { return needle.isEmpty }
        return (0...(haystack.count - needle.count)).contains { Array(haystack[$0..<($0 + needle.count)]) == needle }
    }
}
