// README › Appearance and Options, verbatim (ReadmeTests compares them). Lines marked `// wrapper` are not in the README.
import WajubMobile

func readmeAppearance(_ options: inout PresentOptions) { // wrapper
    options.appearance = Appearance(
        theme: .stripe,                          // presets: .stripe, .night, .flat, .noPreset
        colorScheme: .auto,                      // .light, .dark, .auto (follows the phone, live)
        variables: AppearanceVariables(colorPrimary: "#0F766E", fontFamily: "Poppins", borderRadius: "12px"),
        buttonTextColor: "#FFFFFF")
} // wrapper

/// The forms the README's text names.
func readmeAppearanceFromJSON(_ jsonString: String) throws -> Appearance {
    Appearance(json: try JSONValue.parse(jsonString))
}

func readmeOptions(token: String) -> PresentOptions {
    var options = PresentOptions(sessionToken: token)
    options.locale = "fr"
    options.loader = .spinner
    options.readyTimeout = 0
    options.mobileMoney = MobileMoneyOptions(country: "CM", countryLocked: true, operatorMode: .detect)
    options.realtime = RealtimeOptions(enabled: true, host: "ws.example.com", port: 443, tls: true)
    options.cancelOnDismiss = false
    options.autoCloseSuccess = 0
    options.appearance = Appearance(theme: .noPreset, shadow: .noShadow)
    return options
}
