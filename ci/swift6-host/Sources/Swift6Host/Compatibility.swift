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
