import Foundation

/// The shared Mobile Money tables (`Resources/mobile-money.json`, copied from the contract's
/// `data/mobile-money.json` by `sync-spec.sh`; never edited, never duplicated in code).
public struct MobileMoneyData: Sendable {
    /// The `schema_version` this SDK reads.
    static let supportedSchemaVersion = 1

    public struct PrefixRule: Sendable {
        public var startsWith: [String]
        public var operatorId: String
    }

    public struct Country: Sendable {
        public var code: String
        public var name: String
        /// `+237`.
        public var dialCode: String
        public var nationalNumberLength: Int?
        /// `keep` (Côte d'Ivoire) or `drop`.
        public var keepsTrunkZero: Bool
        public var placeholder: String
        public var placeholderFormatted: String
        public var operators: [String]
        public var prefixRules: [PrefixRule]

        /// The dial code's digits, without `+`.
        var dialDigits: String { String(dialCode.filter(\.isNumber)) }
    }

    /// An operator's fallback badge colours and text.
    public struct Brand: Equatable, Sendable {
        public var label: String
        public var mark: String?
        public var color: String
        public var background: String
    }

    public struct Operator: Sendable {
        public var id: String
        public var name: String
        public var operatorIndependent: Bool
        public var brand: Brand?
    }

    public var countries: [String: Country]
    public var operators: [String: Operator]
    /// Wallets that take any number: never a mismatch.
    public var operatorIndependentWallets: Set<String>
    public var fallbackBrandColor: String
    public var fallbackBrandBackground: String
    public var looseLength: ClosedRange<Int>

    public enum LoadError: Error, Equatable {
        case missingResource
        case unreadable
        case unsupportedSchemaVersion(Int?)
    }

    /// The SDK's copy, read once.
    public static let shared: MobileMoneyData = {
        do {
            return try load()
        } catch {
            preconditionFailure("WajubMobile: Resources/mobile-money.json is missing or unreadable (\(error)).")
        }
    }()

    static func load() throws -> MobileMoneyData {
        guard let url = Bundle.module.url(forResource: "mobile-money", withExtension: "json") else { throw LoadError.missingResource }
        return try MobileMoneyData(data: try Data(contentsOf: url))
    }

    /// Reads the data file; refuses a `schema_version` this SDK does not know.
    public init(data: Data) throws {
        guard let json = try? JSONValue.parse(data) else { throw LoadError.unreadable }
        let version = json["schema_version"]?.int
        guard version == MobileMoneyData.supportedSchemaVersion else { throw LoadError.unsupportedSchemaVersion(version) }

        var countries: [String: Country] = [:]
        for (code, entry) in json["countries"]?.object ?? [:] {
            let rules = (entry["prefix_rules"]?.array ?? []).map {
                PrefixRule(startsWith: $0["starts_with"]?.strings ?? [], operatorId: $0["operator"]?.string ?? "")
            }
            countries[code.uppercased()] = Country(
                code: code.uppercased(), name: entry["name"]?.string ?? code, dialCode: entry["dial_code"]?.string ?? "",
                nationalNumberLength: entry["national_number_length"]?.int,
                keepsTrunkZero: entry["e164_trunk_zero"]?.string == "keep",
                placeholder: entry["placeholder"]?.string ?? "", placeholderFormatted: entry["placeholder_formatted"]?.string ?? "",
                operators: entry["operators"]?.strings ?? [], prefixRules: rules)
        }
        var operators: [String: Operator] = [:]
        for (id, entry) in json["operators"]?.object ?? [:] {
            var brand: Brand?
            if let value = entry["brand"], value.object != nil {
                brand = Brand(label: value["label"]?.string ?? "", mark: value["mark"]?.nonEmptyString,
                              color: value["color"]?.string ?? "#ffffff", background: value["background"]?.string ?? "#525252")
            }
            operators[id] = Operator(id: id, name: entry["name"]?.string ?? id,
                                     operatorIndependent: entry["operator_independent"]?.bool ?? false, brand: brand)
        }
        self.countries = countries
        self.operators = operators
        operatorIndependentWallets = Set(json["operator_independent_wallets"]?.strings ?? [])
        fallbackBrandColor = json["fallback_brand"]?["color"]?.string ?? "#ffffff"
        fallbackBrandBackground = json["fallback_brand"]?["background"]?.string ?? "#525252"
        looseLength = (json["loose_length"]?["min"]?.int ?? 7)...(json["loose_length"]?["max"]?.int ?? 15)
    }

    // MARK: Algorithms (`algorithms` of the data file)

    /// Keeps `0-9` and `+`, then removes every `+`.
    public func sanitize(_ input: String) -> String {
        String(input.unicodeScalars.filter { ("0"..."9").contains($0) }.map(Character.init))
    }

    /// `sanitize`, minus a leading dial code, minus every leading `0`.
    public func nationalDigits(_ input: String, country: String) -> String {
        var digits = sanitize(input)
        if let dial = countries[country.uppercased()]?.dialDigits, !dial.isEmpty, digits.hasPrefix(dial) {
            digits.removeFirst(dial.count)
        }
        while digits.hasPrefix("0") { digits.removeFirst() }
        return digits
    }

    /// The country's exact national length when it has one, else 7 to 15 digits.
    public func isValid(_ input: String, country: String) -> Bool {
        if let length = countries[country.uppercased()]?.nationalNumberLength {
            return nationalDigits(input, country: country).count == length
        }
        return looseLength.contains(sanitize(input).count)
    }

    /// The first prefix rule the national digits start with; operator-independent wallets are never detected.
    public func detectOperator(_ input: String, country: String) -> String? {
        let national = nationalDigits(input, country: country)
        guard !national.isEmpty, let rules = countries[country.uppercased()]?.prefixRules else { return nil }
        for rule in rules where rule.startsWith.contains(where: { national.hasPrefix($0) }) {
            return operatorIndependentWallets.contains(rule.operatorId) ? nil : rule.operatorId
        }
        return nil
    }

    /// Dial code + (`0` when the country keeps it) + national digits.
    public func e164(_ input: String, country: String) -> String {
        guard let entry = countries[country.uppercased()] else { return "+" + sanitize(input) }
        return entry.dialCode + (entry.keepsTrunkZero ? "0" : "") + nationalDigits(input, country: country)
    }

    /// Digits only, at most 15, grouped by two: `671234567` → `67 12 34 56 7`.
    public func formatAsYouType(_ input: String) -> String {
        let digits = Array(sanitize(input).prefix(15))
        return stride(from: 0, to: digits.count, by: 2).map { String(digits[$0..<min($0 + 2, digits.count)]) }
            .joined(separator: " ")
    }

    /// The round badge drawn when an operator has no usable logo.
    public func badge(operatorId: String, fallbackName: String) -> OperatorBadge {
        if let brand = operators[operatorId]?.brand {
            return OperatorBadge(text: brand.mark ?? MobileMoneyData.badgeText(brand.label), color: brand.color,
                                 background: brand.background)
        }
        return OperatorBadge(text: MobileMoneyData.badgeText(fallbackName), color: fallbackBrandColor,
                             background: fallbackBrandBackground)
    }

    /// The first 8 alphanumerics, upper-cased.
    static func badgeText(_ label: String) -> String {
        String(label.filter { $0.isLetter || $0.isNumber }.prefix(8)).uppercased()
    }
}

/// An operator's fallback badge (`algorithms.brand_fallback`).
public struct OperatorBadge: Equatable, Sendable {
    public var text: String
    /// Text colour, CSS hex.
    public var color: String
    /// Badge colour, CSS hex.
    public var background: String
}
