import Foundation

/// "Copied" on a Copy button: back to "Copy" `seconds` after the last copy, so a second copy keeps it
/// for its own full time.
package struct CopyFeedback: Equatable, Sendable {
    /// How long "Copied" shows after a copy.
    package static let seconds: Double = 2

    /// "Copied" is shown.
    package private(set) var isShown = false
    private var copies = 0

    package init() {}

    /// A copy: "Copied" shows. Pass what it returns to `expire(_:)` once `seconds` have passed.
    package mutating func copy() -> Int {
        copies += 1
        isShown = true
        return copies
    }

    /// `seconds` after a copy: back to "Copy", unless the payer copied again since.
    package mutating func expire(_ copy: Int) {
        if copy == copies { isShown = false }
    }
}
