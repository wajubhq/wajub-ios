import Foundation

/// One operator the payer can pick.
public struct OperatorChoice: Equatable, Sendable, Identifiable {
    /// The operator: `mtn`, `orange`, `moov`…
    public var id: String
    /// The operator's name to show.
    public var label: String
    /// An `https` logo iOS can draw (never an SVG); when it is missing or fails to load, draw `badge`.
    public var logoURL: String?
    public var badge: OperatorBadge
    /// The channel the payment goes through: the aggregate's slug for an aggregate member.
    public var channelSlug: String
    /// The operator's own channel (`cm.mtn`).
    public var operatorSlug: String
    public var isAggregateMember: Bool
    /// A wallet that takes a number from any network: never a mismatch.
    public var isOperatorIndependent: Bool
    /// The amount is out of this channel's limits.
    public var limit: AmountLimit?
}

/// How the payer chooses the operator.
public enum OperatorMode: String, Sendable {
    /// The list is always shown (default).
    case choose
    /// The detected operator shows as a badge in the field; the list appears only when needed.
    case detect
}

/// The Mobile Money form: country, number, operator and validation.
public struct MobileMoneyForm: Equatable, Sendable {
    public private(set) var countries: [String]
    public private(set) var country: String
    /// The country selector is hidden.
    public let countryLocked: Bool
    public let operatorMode: OperatorMode
    public private(set) var choices: [OperatorChoice] = []
    public private(set) var selection: String?
    public private(set) var pickedByHand = false
    /// What the payer typed.
    public private(set) var phone = ""
    public private(set) var listOpened = false

    private let channels: [SessionChannel]
    private let language: WajubLanguage
    private let amount: Double
    private let config: SdkConfigResponse?

    init(channels: [SessionChannel], config: SdkConfigResponse?, language: WajubLanguage, amount: Double, options: MobileMoneyOptions,
         geoCountry: String?) {
        self.channels = channels
        self.config = config
        self.language = language
        self.amount = amount
        operatorMode = options.operatorMode
        var countries: [String] = []
        for code in channels.flatMap(\.countries) where !countries.contains(code) {
            countries.append(code)
        }
        self.countries = countries
        let requested = options.country?.uppercased()
        if let requested, countries.contains(requested) || channels.contains(where: { $0.countries.isEmpty }) {
            country = requested
            countryLocked = options.countryLocked
        } else {
            let coversAll = channels.contains { $0.countries.isEmpty }
            country = geoCountry.flatMap { countries.contains($0) || coversAll ? $0 : nil } ?? countries.first ?? geoCountry ?? ""
            countryLocked = false
        }
        if !country.isEmpty, !self.countries.contains(country) { self.countries.insert(country, at: 0) }
        refreshChoices()
    }

    var data: MobileMoneyData { .shared }

    // MARK: Derived

    public var dialCode: String { data.countries[country]?.dialCode ?? "" }
    public var placeholder: String { data.countries[country]?.placeholderFormatted ?? "" }
    public var formattedPhone: String { data.formatAsYouType(phone) }
    public var detectedOperator: String? { data.detectOperator(phone, country: country) }
    public var selectedChoice: OperatorChoice? { choices.first { $0.id == selection } }
    /// `operator_unavailable`: no operator the payer can pick for the country; Pay is disabled.
    public var hasNoOperator: Bool { !choices.contains { $0.limit == nil } }

    /// In `detect` mode the list stays hidden until the number (≥ 6 digits) names no offered operator,
    /// an operator-independent wallet is offered while the number names one, or the payer opens it.
    /// Once the payer has picked by hand it stays shown, with their pick.
    public var isOperatorListVisible: Bool {
        guard operatorMode == .detect else { return true }
        if listOpened || pickedByHand || unavailableDetected != nil { return true }
        let enabled = enabledIds
        let national = data.nationalDigits(phone, country: country)
        let detected = detectedOperator
        let detectedOffered = detected.map(enabled.contains) ?? false
        if national.count >= 6 && !detectedOffered && enabled.count > 1 { return true }
        if detected != nil && choices.contains(where: { $0.isOperatorIndependent && $0.limit == nil }) { return true }
        return false
    }

    /// The operator the number belongs to when it cannot take this amount (out of its limits): the sheet
    /// says so rather than quietly paying through another one.
    public var unavailableDetected: OperatorChoice? {
        guard let detected = detectedOperator else { return nil }
        return choices.first { $0.id == detected && $0.limit != nil }
    }

    /// In `detect` mode, the operator shown inside the field: the detected one, or the only one the payer can use.
    public var badgeChoice: OperatorChoice? {
        let enabled = choices.filter { $0.limit == nil }
        if let detected = detectedOperator, let choice = enabled.first(where: { $0.id == detected }) { return choice }
        return enabled.count == 1 ? enabled.first : nil
    }

    // MARK: Changes

    /// Changing country clears the picked flag and selects the first choice.
    mutating func setCountry(_ code: String) {
        guard !countryLocked, countries.contains(code.uppercased()), code.uppercased() != country else { return }
        country = code.uppercased()
        pickedByHand = false
        listOpened = false
        refreshChoices()
    }

    mutating func setPhone(_ text: String) {
        phone = String(data.sanitize(text).prefix(15))
        selection = MobileMoneyForm.preselect(current: selection, pickedByHand: pickedByHand, detected: detectedOperator,
                                              choiceIds: enabledIds)
    }

    /// A pick by hand is never overridden by detection. An operator out of its limits cannot be picked.
    mutating func pick(_ id: String) {
        guard choices.contains(where: { $0.id == id && $0.limit == nil }) else { return }
        selection = id
        pickedByHand = true
    }

    mutating func openList() {
        listOpened = true
    }

    /// The ids the payer can pick (operators out of their amount limits are shown disabled).
    private var enabledIds: [String] {
        choices.filter { $0.limit == nil }.map(\.id)
    }

    private mutating func refreshChoices() {
        choices = MobileMoneyForm.choices(channels: channels, country: country, config: config, language: language, amount: amount)
        selection = enabledIds.first
        selection = MobileMoneyForm.preselect(current: selection, pickedByHand: false, detected: detectedOperator, choiceIds: enabledIds)
    }

    // MARK: Submit

    /// The first problem of README §6.3, or `nil`. In sandbox an `operator_mismatch` does not block (it is returned as a warning).
    func validate(sandbox: Bool) -> (error: WajubError?, warning: WajubError?) {
        // An operator out of its limits is not offered: never a mismatch toward it.
        let code = MobileMoneyForm.validationCode(phone: phone, country: country, choiceIds: enabledIds,
                                                  selection: selection, data: data)
        guard let code else { return (nil, nil) }
        var error = WajubError.catalogue(code, language, values: mismatchLabels)
        error.param = code == WajubError.Code.operatorRequired ? "data.operator" : "data.phone"
        if code == WajubError.Code.operatorMismatch && sandbox { return (nil, error) }
        return (error, nil)
    }

    private var mismatchLabels: [String: String] {
        let detected = detectedOperator.flatMap { id in choices.first { $0.id == id }?.label } ?? ""
        return ["detected": detected, "selected": selectedChoice?.label ?? ""]
    }

    /// `POST /pay/process`'s channel and data (without `_client`).
    func request(returnURL: String?) -> (channel: String, data: [String: JSONValue])? {
        guard let choice = selectedChoice else { return nil }
        var data: [String: JSONValue] = [
            "phone": .string(self.data.e164(phone, country: country)),
            "country": .string(country),
        ]
        if let hint = MobileMoneyForm.operatorHint(isAggregate: choice.isAggregateMember, selection: choice.id,
                                                   pickedByHand: pickedByHand, detected: detectedOperator) {
            data["operator"] = .string(hint)
        }
        if let returnURL { data["return_url"] = .string(returnURL) }
        return (choice.channelSlug, data)
    }

    // MARK: Rules

    /// The choices for a country, in API order; a repeated id keeps the first.
    static func choices(channels: [SessionChannel], country: String, config: SdkConfigResponse?, language: WajubLanguage,
                        amount: Double) -> [OperatorChoice] {
        let data = MobileMoneyData.shared
        var choices: [OperatorChoice] = []
        for channel in channels where channel.isMobileMoney && (channel.countries.isEmpty || channel.countries.contains(country)) {
            let limit = MethodResolver.limit(channel, amount: amount)
            for member in availableOperators(channel, config: config, language: language)
            where !choices.contains(where: { $0.id == member.id }) {
                let label = data.operators[member.id]?.brand?.label ?? member.name
                choices.append(OperatorChoice(
                    id: member.id, label: label, logoURL: member.logo,
                    badge: data.badge(operatorId: member.id, fallbackName: member.name), channelSlug: channel.slug,
                    operatorSlug: member.slug, isAggregateMember: channel.isAggregate,
                    isOperatorIndependent: data.operatorIndependentWallets.contains(member.id), limit: limit))
            }
        }
        return choices
    }

    /// The operators of a Mobile Money channel that sdk-config does not mark unavailable.
    /// Aggregate members are named in the session's locale; another channel by its name for the sheet's language.
    static func availableOperators(_ channel: SessionChannel, config: SdkConfigResponse?,
                                   language: WajubLanguage = .en) -> [(id: String, name: String, logo: String?, slug: String)] {
        let members: [(id: String, name: String, logo: String?, slug: String)]
        if channel.isAggregate {
            members = channel.operators.map { ($0.operatorId, $0.name, $0.drawableLogo, $0.slug) }
        } else {
            let id = channel.slug.split(separator: ".").last.map(String.init) ?? channel.slug
            members = [(id, channel.localizedName(language), channel.drawableLogo, channel.slug)]
        }
        return members.filter { MethodResolver.mobileMoneyConfig(channel, operatorSlug: channel.isAggregate ? $0.slug : nil, config: config).available }
    }

    /// Detection selects a detected, offered operator only while the payer has not picked one by hand.
    static func preselect(current: String?, pickedByHand: Bool, detected: String?, choiceIds: [String]) -> String? {
        guard !pickedByHand, let detected, choiceIds.contains(detected) else { return current }
        return detected
    }

    /// `phone_required`, `invalid_phone`, `operator_mismatch`, `operator_required`, in that order.
    static func validationCode(phone: String, country: String, choiceIds: [String], selection: String?,
                               data: MobileMoneyData) -> String? {
        if data.sanitize(phone).isEmpty { return WajubError.Code.phoneRequired }
        if !data.isValid(phone, country: country) { return WajubError.Code.invalidPhone }
        if let detected = data.detectOperator(phone, country: country), choiceIds.contains(detected), let selection,
           detected != selection, !data.operatorIndependentWallets.contains(selection) {
            return WajubError.Code.operatorMismatch
        }
        if selection == nil { return WajubError.Code.operatorRequired }
        return nil
    }

    /// `data.operator`: only on an aggregate, and only when picked by hand or equal to the detected operator.
    static func operatorHint(isAggregate: Bool, selection: String, pickedByHand: Bool, detected: String?) -> String? {
        guard isAggregate, pickedByHand || detected == selection else { return nil }
        return selection
    }

    /// The label of the operator an API mismatch refusal names ("…belongs to ORANGE (cm.orange) but…"),
    /// else of the operator the form detects.
    func mismatchLabel(apiMessage: String) -> String {
        var id = detectedOperator
        var name: String?
        if let range = apiMessage.range(of: "belongs to ") {
            let rest = apiMessage[range.upperBound...]
            name = rest.split(separator: " ").first.map(String.init)
            if let open = rest.firstIndex(of: "("), let close = rest.firstIndex(of: ")"), open < close {
                let slug = rest[rest.index(after: open)..<close]
                id = slug.split(separator: ".").last.map(String.init) ?? id
            }
        }
        guard let id else { return name ?? "" }
        return choices.first { $0.id == id }?.label ?? data.operators[id]?.brand?.label ?? data.operators[id]?.name ?? name ?? id
    }
}

/// `PresentOptions.mobileMoney`: the country to start on and how the operator is chosen.
public struct MobileMoneyOptions: Equatable, Sendable {
    /// ISO-2 to start on.
    public var country: String?
    /// Hide the country selector when `country` is offered.
    public var countryLocked: Bool
    public var operatorMode: OperatorMode

    public init(country: String? = nil, countryLocked: Bool = false, operatorMode: OperatorMode = .choose) {
        self.country = country
        self.countryLocked = countryLocked
        self.operatorMode = operatorMode
    }
}
