import WajubMobile

/// Code written for 1.0.0 that must keep compiling: the deprecated `realtime` option, as an app set it.
/// Marked deprecated itself, so that it builds without warnings.
@available(*, deprecated)
func compatibilityWith1_0(token: String) -> [PresentOptions] {
    var options = PresentOptions(sessionToken: token)
    options.realtime = RealtimeOptions(enabled: true, host: "ws.example.com", port: 443, tls: true)
    let off = PresentOptions(sessionToken: token, locale: "fr", realtime: RealtimeOptions(enabled: false), cancelOnDismiss: false)
    return [options, off]
}

/// The Mobile Money helpers as 1.0.0 exposed them (`keepsTrunkZero` is deprecated since).
@available(*, deprecated)
func mobileMoneyAsIn1_0(_ number: String) -> [String] {
    var data = MobileMoneyData.shared
    var country: MobileMoneyData.Country? = data.countries["CM"]
    let keeps: Bool = country?.keepsTrunkZero ?? false
    country?.keepsTrunkZero = keeps
    let length: Int? = country?.nationalNumberLength
    let rules: [MobileMoneyData.PrefixRule] = country?.prefixRules ?? []
    let firstRule: (startsWith: [String], operatorId: String)? = rules.first.map { ($0.startsWith, $0.operatorId) }
    let brand: MobileMoneyData.Brand? = data.operators["mtn"]?.brand
    data.looseLength = 7...15
    let badge: OperatorBadge = data.badge(operatorId: "mtn", fallbackName: "MTN")
    let loadError: MobileMoneyData.LoadError = .unsupportedSchemaVersion(nil)
    return [data.sanitize(number), data.nationalDigits(number, country: "CM"), String(data.isValid(number, country: "CM")),
            data.detectOperator(number, country: "CM") ?? "", data.e164(number, country: "CM"), data.formatAsYouType(number),
            String(length ?? 0), firstRule?.operatorId ?? "", brand?.label ?? "", badge.text, "\(loadError)",
            country?.placeholderFormatted ?? "", data.fallbackBrandColor, String(data.operatorIndependentWallets.count)]
}
