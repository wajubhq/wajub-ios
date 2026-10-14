import Foundation

/// Amounts in the currency's usual format and decimals (XAF, XOF: none).
enum AmountFormatter {
    static func format(_ amount: Double, currency: String, language: WajubLanguage) -> String {
        let formatter = NumberFormatter()
        formatter.locale = Locale(identifier: language == .fr ? "fr_FR" : "en_US")
        guard currency.count == 3 else {
            formatter.numberStyle = .decimal
            return formatter.string(from: NSNumber(value: amount)) ?? String(amount)
        }
        formatter.numberStyle = .currency
        formatter.currencyCode = currency.uppercased()
        return formatter.string(from: NSNumber(value: amount)) ?? "\(amount) \(currency)"
    }
}
