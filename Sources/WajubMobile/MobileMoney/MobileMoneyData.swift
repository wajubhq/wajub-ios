import Foundation

/// Mobile Money numbers by country: checks, formats and reads them, recognises their operator, and
/// gives each operator's badge.
public struct MobileMoneyData: Sendable {
    /// The `schema_version` this SDK reads.
    static let supportedSchemaVersion = 2

    public struct PrefixRule: Sendable {
        public var startsWith: [String]
        public var operatorId: String
    }

    /// Whether a country's leading 0 is part of the number or only typed in front of it.
    enum LeadingZero: Sendable {
        /// Typed in front of the number, left out of it.
        case trunk
        /// Part of the number (Côte d'Ivoire, Benin, Congo…).
        case significant
    }

    /// The numbers of a country's earlier plan, read in their current form.
    struct Earlier: Sendable {
        var length: Int
        /// Earlier start → current start.
        var map: [String: String]
    }

    public struct Country: Sendable {
        public var code: String
        public var name: String
        /// `+237`.
        public var dialCode: String
        public var nationalNumberLength: Int?
        /// The leading 0 is part of the number (Côte d'Ivoire, Benin, Congo…). `nationalDigits(_:country:)`
        /// already keeps it there: to send a number, use `e164(_:country:)`.
        @available(*, deprecated, message: "nationalDigits(_:country:) keeps the 0 where it is part of the number: use e164(_:country:) to send a number.")
        public var keepsTrunkZero: Bool {
            get { leadingZero == .significant }
            set { leadingZero = newValue ? .significant : .trunk }
        }
        public var placeholder: String
        public var placeholderFormatted: String
        public var operators: [String]
        public var prefixRules: [PrefixRule]

        var leadingZero: LeadingZero = .trunk
        /// What every number of the country starts with, when they share a start.
        var numberPrefix: String?
        /// A number typed without its 0 gets it back when it then starts with one of these.
        var mobilePrefixes: [String] = []
        var earlier: Earlier?

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

    /// A sandbox test number: accepted whatever the country's numbering, and paid through the
    /// operator it tests.
    public struct SandboxTestNumber: Equatable, Sendable {
        /// The operator the number tests.
        public var operatorId: String
        /// The number as it is sent.
        public var e164: String
    }

    public var countries: [String: Country]
    public var operators: [String: Operator]
    /// Wallets that take any number: never a mismatch.
    public var operatorIndependentWallets: Set<String>
    public var fallbackBrandColor: String
    public var fallbackBrandBackground: String
    public var looseLength: ClosedRange<Int>
    /// Per country, the sandbox test prefixes (digits only), longest first, with their operator.
    var sandboxPrefixes: [String: [(prefix: String, operatorId: String)]] = [:]
    /// The endings of a sandbox test number.
    var sandboxOutcomes: [String] = []

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

    /// Reads Mobile Money tables; throws when they are not in a form this version of the SDK reads.
    public init(data: Data) throws {
        guard let json = try? JSONValue.parse(data) else { throw LoadError.unreadable }
        let version = json["schema_version"]?.int
        guard version == MobileMoneyData.supportedSchemaVersion else { throw LoadError.unsupportedSchemaVersion(version) }

        var countries: [String: Country] = [:]
        for (code, entry) in json["countries"]?.object ?? [:] {
            let rules = (entry["prefix_rules"]?.array ?? []).map {
                PrefixRule(startsWith: $0["starts_with"]?.strings ?? [], operatorId: $0["operator"]?.string ?? "")
            }
            var country = Country(
                code: code.uppercased(), name: entry["name"]?.string ?? code, dialCode: entry["dial_code"]?.string ?? "",
                nationalNumberLength: entry["national_number_length"]?.int,
                placeholder: entry["placeholder"]?.string ?? "", placeholderFormatted: entry["placeholder_formatted"]?.string ?? "",
                operators: entry["operators"]?.strings ?? [], prefixRules: rules)
            country.leadingZero = entry["leading_zero"]?.string == "significant" ? .significant : .trunk
            country.numberPrefix = entry["number_prefix"]?.nonEmptyString
            country.mobilePrefixes = entry["mobile_prefixes"]?.strings ?? []
            if let earlier = entry["earlier"], let length = earlier["length"]?.int, let map = earlier["map"]?.object {
                country.earlier = Earlier(length: length, map: map.compactMapValues { $0.nonEmptyString })
            }
            countries[code.uppercased()] = country
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
        var sandboxPrefixes: [String: [(prefix: String, operatorId: String)]] = [:]
        for (code, byOperator) in json["sandbox_test_numbers"]?["prefixes"]?.object ?? [:] {
            var prefixes: [(prefix: String, operatorId: String)] = []
            for (operatorId, list) in byOperator.object ?? [:] {
                for prefix in list.strings { prefixes.append((String(prefix.filter(\.isNumber)), operatorId)) }
            }
            sandboxPrefixes[code.uppercased()] = prefixes.sorted {
                $0.prefix.count != $1.prefix.count ? $0.prefix.count > $1.prefix.count : ($0.prefix, $0.operatorId) < ($1.prefix, $1.operatorId)
            }
        }
        self.countries = countries
        self.operators = operators
        operatorIndependentWallets = Set(json["operator_independent_wallets"]?.strings ?? [])
        fallbackBrandColor = json["fallback_brand"]?["color"]?.string ?? "#ffffff"
        fallbackBrandBackground = json["fallback_brand"]?["background"]?.string ?? "#525252"
        looseLength = (json["loose_length"]?["min"]?.int ?? 7)...(json["loose_length"]?["max"]?.int ?? 15)
        self.sandboxPrefixes = sandboxPrefixes
        sandboxOutcomes = (json["sandbox_test_numbers"]?["outcome_suffixes"]?.object ?? [:]).keys.sorted()
    }

    // MARK: Numbers

    /// Keeps the digits, dropping spaces, dashes and `+`. Digits typed on an Arabic, Persian or other
    /// keyboard are read as the same digits, so they show and count.
    public func sanitize(_ input: String) -> String {
        String(Digits.ascii(input).unicodeScalars.filter { ("0"..."9").contains($0) }.map(Character.init))
    }

    /// The digits after the dial code as typed, and whether they are another country's number.
    struct TypedNumber {
        var digits: String
        /// Written with `+` or `00` and another country's dial code.
        var foreign: Bool
    }

    /// The digits after the dial code, exactly as typed. A number written internationally (`+`, or the
    /// international prefix `00`) loses its dial code, or is another country's when it has another
    /// one; a number written nationally loses a dial code only when it is not already a national
    /// number as typed (Ghana's numbers that start like its dial code).
    func typedNumber(_ input: String, country: String, zeroZeroIsInternational: Bool = true) -> TypedNumber {
        let digits = sanitize(input)
        guard let entry = countries[country.uppercased()] else { return TypedNumber(digits: digits, foreign: false) }
        let dial = entry.dialDigits
        let firstMark = Digits.ascii(input).unicodeScalars.first { $0 == "+" || ("0"..."9").contains($0) }
        var international: String?
        if firstMark == "+" {
            international = digits
        } else if zeroZeroIsInternational, digits.hasPrefix("00") {
            international = String(digits.dropFirst(2))
        }
        if let international {
            guard international.hasPrefix(dial) else { return TypedNumber(digits: international, foreign: true) }
            return TypedNumber(digits: String(international.dropFirst(dial.count)), foreign: false)
        }
        if digits.hasPrefix(dial), !isNationalNumber(planDigits(digits, entry), entry) {
            return TypedNumber(digits: String(digits.dropFirst(dial.count)), foreign: false)
        }
        return TypedNumber(digits: digits, foreign: false)
    }

    func typedNationalDigits(_ input: String, country: String) -> String {
        typedNumber(input, country: country).digits
    }

    /// The typed digits by the country's current plan: an earlier number in its current form, then the
    /// leading 0 left out, or kept (and given back) where it is part of the number.
    func planDigits(_ typed: String, _ entry: Country) -> String {
        var digits = typed
        if let earlier = entry.earlier, digits.count == earlier.length, let key = MobileMoneyData.longestKey(of: earlier, starting: digits) {
            digits = earlier.map[key, default: key] + digits.dropFirst(key.count)
        }
        switch entry.leadingZero {
        case .trunk:
            digits = String(digits.drop { $0 == "0" })
        case .significant:
            let withZero = "0" + digits
            if !digits.hasPrefix("0"), let length = entry.nationalNumberLength, withZero.count == length,
               entry.mobilePrefixes.contains(where: { withZero.hasPrefix($0) }) {
                digits = withZero
            }
        }
        return digits
    }

    /// A complete national number of the country: its exact length, and its common start when it has one.
    func isNationalNumber(_ national: String, _ entry: Country) -> Bool {
        guard let length = entry.nationalNumberLength, national.count == length else { return false }
        if let prefix = entry.numberPrefix, !national.hasPrefix(prefix) { return false }
        return true
    }

    /// The national number by the country's current numbering plan: without the dial code, with its
    /// leading 0 only where the 0 is part of the number, and an earlier number in its current form
    /// (Benin: `96 12 34 56` → `0196123456`). Another country's number keeps its digits as written.
    public func nationalDigits(_ input: String, country: String) -> String {
        guard let entry = countries[country.uppercased()] else {
            return String(sanitize(input).drop { $0 == "0" })
        }
        let typed = typedNumber(input, country: country)
        return typed.foreign ? typed.digits : planDigits(typed.digits, entry)
    }

    /// Whether the number is a complete number of the country (any 7 to 15 digits for a country the
    /// SDK does not know). Another country's number, written with its dial code, is not.
    public func isValid(_ input: String, country: String) -> Bool {
        guard let entry = countries[country.uppercased()] else { return looseLength.contains(sanitize(input).count) }
        let typed = typedNumber(input, country: country)
        guard !typed.foreign else { return false }
        let national = planDigits(typed.digits, entry)
        if let length = entry.nationalNumberLength, national.count != length { return false }
        if let prefix = entry.numberPrefix, !national.hasPrefix(prefix) { return false }
        return true
    }

    /// The operator the number belongs to, as soon as its first digits say it; `nil` when they do not,
    /// for another country's number, and for wallets that take a number from any network.
    public func detectOperator(_ input: String, country: String) -> String? {
        guard let entry = countries[country.uppercased()] else { return nil }
        let typed = typedNumber(input, country: country)
        guard !typed.foreign else { return nil }
        var digits = planDigits(typed.digits, entry)
        if entry.numberPrefix != nil, !digits.isEmpty, !digits.hasPrefix("0") {
            // Still being typed without its 0, or the earlier way.
            if let earlier = entry.earlier, let key = MobileMoneyData.longestKey(of: earlier, starting: digits) {
                digits = earlier.map[key, default: key] + digits.dropFirst(key.count)
            } else {
                digits = "0" + digits
            }
        }
        guard !digits.isEmpty else { return nil }
        for rule in entry.prefixRules where rule.startsWith.contains(where: { digits.hasPrefix($0) }) {
            return operatorIndependentWallets.contains(rule.operatorId) ? nil : rule.operatorId
        }
        return nil
    }

    /// The number in international format, as it is sent; another country's number as written.
    public func e164(_ input: String, country: String) -> String {
        guard let entry = countries[country.uppercased()] else { return "+" + sanitize(input) }
        let typed = typedNumber(input, country: country)
        return typed.foreign ? "+" + typed.digits : entry.dialCode + planDigits(typed.digits, entry)
    }

    // MARK: Sandbox test numbers

    /// The sandbox test number `input` is, or `nil`. Only a sandbox payment takes test numbers, and
    /// never another country's.
    public func sandboxTestNumber(_ input: String, country: String) -> SandboxTestNumber? {
        let code = country.uppercased()
        guard let entry = countries[code], let prefixes = sandboxPrefixes[code], !prefixes.isEmpty else { return nil }
        let dial = entry.dialDigits
        // By the plan; as typed after the dial code, its 0s kept; and with a leading 00 as typed digits.
        var readings: [String] = []
        let typed = typedNumber(input, country: code)
        if !typed.foreign {
            readings.append(dial + planDigits(typed.digits, entry))
            readings.append(dial + typed.digits)
        }
        let asTyped = typedNumber(input, country: code, zeroZeroIsInternational: false)
        if !asTyped.foreign { readings.append(dial + asTyped.digits) }
        for reading in readings {
            for candidate in prefixes where reading.hasPrefix(candidate.prefix) {
                if isSandboxOutcome(reading.dropFirst(candidate.prefix.count)) {
                    return SandboxTestNumber(operatorId: candidate.operatorId, e164: "+" + reading)
                }
            }
        }
        return nil
    }

    /// `isValid(_:country:)`, where a sandbox payment also accepts its test numbers.
    public func isValid(_ input: String, country: String, sandbox: Bool) -> Bool {
        if sandbox, sandboxTestNumber(input, country: country) != nil { return true }
        return isValid(input, country: country)
    }

    /// `detectOperator(_:country:)`, where a sandbox test number names the operator it tests.
    public func detectOperator(_ input: String, country: String, sandbox: Bool) -> String? {
        if sandbox, let test = sandboxTestNumber(input, country: country) { return test.operatorId }
        return detectOperator(input, country: country)
    }

    /// `e164(_:country:)`, where a sandbox test number is sent as it is read (an 8-digit Beninese test
    /// number in its ten-digit form, for instance).
    public func e164(_ input: String, country: String, sandbox: Bool) -> String {
        if sandbox, let test = sandboxTestNumber(input, country: country) { return test.e164 }
        return e164(input, country: country)
    }

    /// Any 0s, then one of the outcome endings.
    private func isSandboxOutcome(_ rest: Substring) -> Bool {
        sandboxOutcomes.contains { suffix in
            rest.hasSuffix(suffix) && rest.dropLast(suffix.count).allSatisfy { $0 == "0" }
        }
    }

    /// The longest earlier start `digits` begin with.
    private static func longestKey(of earlier: Earlier, starting digits: String) -> String? {
        earlier.map.keys.filter { digits.hasPrefix($0) }.max { $0.count < $1.count }
    }

    // MARK: Display

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

/// An operator's badge, drawn when it has no usable logo.
public struct OperatorBadge: Equatable, Sendable {
    public var text: String
    /// Text colour, CSS hex.
    public var color: String
    /// Badge colour, CSS hex.
    public var background: String
}
