import Foundation

/// Digits typed on a keyboard that does not write ASCII ones.
enum Digits {
    /// Every Unicode decimal digit (Arabic-Indic `٠١٢…`, Persian `۰۱۲…`, full-width `０１２…`) as its ASCII
    /// digit; every other character unchanged.
    static func ascii(_ text: String) -> String {
        var result = String.UnicodeScalarView()
        for scalar in text.unicodeScalars {
            if !scalar.isASCII, scalar.properties.generalCategory == .decimalNumber,
               let value = scalar.properties.numericValue, value >= 0, value <= 9 {
                result.append(Unicode.Scalar(UInt8(48 + Int(value))))
            } else {
                result.append(scalar)
            }
        }
        return String(result)
    }

    /// Only ASCII digits.
    static func isASCIIDigits<S: StringProtocol>(_ text: S) -> Bool {
        !text.isEmpty && text.unicodeScalars.allSatisfy { ("0"..."9").contains($0) }
    }
}
