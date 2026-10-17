import Foundation

/// A resolved colour scheme.
public enum ColorSchemeKind: String, Sendable {
    case light, dark
}

/// The sheet's colour tokens.
public struct ThemeTokens: Equatable, Sendable {
    public var primary: RGBAColor
    public var primaryPressed: RGBAColor
    public var onPrimary: RGBAColor
    public var background: RGBAColor
    public var surfaceRaised: RGBAColor
    public var surfaceMuted: RGBAColor
    public var selectedBackground: RGBAColor
    public var text: RGBAColor
    public var textSecondary: RGBAColor
    public var textPlaceholder: RGBAColor
    public var textDisabled: RGBAColor
    public var link: RGBAColor
    public var inputBackground: RGBAColor
    public var inputBorder: RGBAColor
    public var borderStrong: RGBAColor
    public var focusRing: RGBAColor
    public var danger: RGBAColor
    public var dangerBorder: RGBAColor
    public var dangerBackground: RGBAColor
    public var success: RGBAColor
    public var successBackground: RGBAColor
    public var warning: RGBAColor
    public var warningBackground: RGBAColor
    public var disabledBackground: RGBAColor

    /// Wajub's default colours for a scheme.
    public static func defaults(_ scheme: ColorSchemeKind) -> ThemeTokens {
        func c(_ hex: String) -> RGBAColor { RGBAColor(css: hex)! }
        switch scheme {
        case .light:
            return ThemeTokens(primary: c("#2563EB"), primaryPressed: c("#1D4ED8"), onPrimary: c("#FFFFFF"), background: c("#FFFFFF"),
                               surfaceRaised: c("#FFFFFF"), surfaceMuted: c("#F5F5F5"), selectedBackground: c("#EFF6FF"),
                               text: c("#171717"), textSecondary: c("#525252"), textPlaceholder: c("#737373"),
                               textDisabled: c("#A3A3A3"), link: c("#2563EB"), inputBackground: c("#FFFFFF"),
                               inputBorder: c("#E5E5E5"), borderStrong: c("#D4D4D4"), focusRing: c("#3B82F6"),
                               danger: c("#B91C1C"), dangerBorder: c("#EF4444"), dangerBackground: c("#FEF2F2"),
                               success: c("#15803D"), successBackground: c("#F0FDF4"), warning: c("#B45309"),
                               warningBackground: c("#FFFBEB"), disabledBackground: c("#F5F5F5"))
        case .dark:
            return ThemeTokens(primary: c("#3B82F6"), primaryPressed: c("#60A5FA"), onPrimary: c("#0A0A0A"), background: c("#0A0A0A"),
                               surfaceRaised: c("#171717"), surfaceMuted: c("#262626"), selectedBackground: c("#172554"),
                               text: c("#FAFAFA"), textSecondary: c("#A3A3A3"), textPlaceholder: c("#8A8A8A"),
                               textDisabled: c("#525252"), link: c("#60A5FA"), inputBackground: c("#0A0A0A"),
                               inputBorder: c("#404040"), borderStrong: c("#525252"), focusRing: c("#60A5FA"),
                               danger: c("#F87171"), dangerBorder: c("#F87171"), dangerBackground: c("#450A0A"),
                               success: c("#4ADE80"), successBackground: c("#052E16"), warning: c("#FBBF24"),
                               warningBackground: c("#451A03"), disabledBackground: c("#262626"))
        }
    }
}

/// What the presenting screen's theme gives when `inherit` is on.
public struct InheritedTheme: Equatable, Sendable {
    public var scheme: ColorSchemeKind?
    public var primary: RGBAColor?
    public var background: RGBAColor?
    public var text: RGBAColor?
    public var textSecondary: RGBAColor?
    public var inputBorder: RGBAColor?
    public var fontFamily: String?
    public var borderRadius: Double?

    public init(scheme: ColorSchemeKind? = nil, primary: RGBAColor? = nil, background: RGBAColor? = nil, text: RGBAColor? = nil,
                textSecondary: RGBAColor? = nil, inputBorder: RGBAColor? = nil, fontFamily: String? = nil, borderRadius: Double? = nil) {
        self.scheme = scheme
        self.primary = primary
        self.background = background
        self.text = text
        self.textSecondary = textSecondary
        self.inputBorder = inputBorder
        self.fontFamily = fontFamily
        self.borderRadius = borderRadius
    }

    /// Keeps only usable values: `primary` at 3:1 against the sheet's
    /// background, `text` and `textSecondary` at 4.5:1, the radius capped at 22.
    public func usable(against background: RGBAColor) -> InheritedTheme {
        var copy = self
        if let primary, primary.contrast(with: background) < 3 { copy.primary = nil }
        if let text, text.contrast(with: background) < 4.5 { copy.text = nil }
        if let textSecondary, textSecondary.contrast(with: background) < 4.5 { copy.textSecondary = nil }
        copy.borderRadius = borderRadius.map { min($0, ThemeShape.maxRadius) }
        return copy
    }
}

/// Shapes and type of the resolved theme.
public struct ThemeShape: Equatable, Sendable {
    public static let maxRadius = 22.0
    public static let inputHeight = 44.0

    public var radius: Double
    /// Families to try in order (Inter by default, if the app ships it); then the platform's font.
    public var fontFamilies: [String]
    public var fontSizeBase: Double
    public var fontWeightNormal: Int
    public var fontWeightMedium: Int
    public var fontWeightBold: Int
    public var spacingUnit: Double
    public var gapRow: Double
    public var gapColumn: Double

    /// Labels and hints are 0.875 × the base size.
    public var fontSizeLabel: Double { fontSizeBase * 0.875 }
    /// Inputs never go below 16.
    public var fontSizeInput: Double { max(fontSizeBase, 16) }
}

/// Everything the sheet draws with.
public struct ResolvedTheme: Equatable, Sendable {
    public var scheme: ColorSchemeKind
    /// `true` when the scheme follows the OS (it switches live).
    public var followsSystem: Bool
    public var tokens: ThemeTokens
    public var shape: ThemeShape
    public var shadow: AppearanceShadow?
    public var labels: AppearanceLabels
    public var disableAnimations: Bool
    /// The merchant is white-label: "Secured by Wajub" is hidden.
    public var hidesWajubBranding: Bool
    public var logoURL: String?
    public var businessName: String?
    /// The merchant's overlay intensity, 0…1.
    public var overlayOpacity: Double?
    public var separator: RGBAColor?
}

/// Resolves the sheet's theme: host appearance, preset, inherited host theme, merchant branding,
/// default palette — in that order for every token.
public enum ThemeResolver {
    /// The scheme preference: `colorScheme`/`theme` > preset > inherited > the merchant's appearance mode > auto.
    /// `nil` means auto (follow the OS).
    public static func schemePreference(appearance: Appearance?, branding: Branding?, inherited: InheritedTheme?) -> ColorSchemeKind? {
        if let colorScheme = appearance?.colorScheme {
            return colorScheme == .auto ? nil : ColorSchemeKind(rawValue: colorScheme.rawValue)
        }
        switch appearance?.theme {
        case .light?: return .light
        case .dark?: return .dark
        case .auto?, .system?: return nil
        case let preset?:
            if let scheme = Appearance.preset(preset)?.colorScheme, scheme != .auto {
                return ColorSchemeKind(rawValue: scheme.rawValue)
            }
        case nil:
            break
        }
        if appearance?.inherit == true, let scheme = inherited?.scheme { return scheme }
        switch branding?.appearanceMode?.lowercased() {
        case "light": return .light
        case "dark": return .dark
        default: return nil
        }
    }

    public static func resolve(appearance: Appearance?, branding: Branding?, inherited: InheritedTheme? = nil,
                               system: ColorSchemeKind) -> ResolvedTheme {
        let preference = schemePreference(appearance: appearance, branding: branding, inherited: inherited)
        let scheme = preference ?? system
        let defaults = ThemeTokens.defaults(scheme)
        let host = appearance ?? Appearance()
        let preset = host.theme.flatMap(Appearance.preset) ?? Appearance()
        let hostTheme = host.inherit == true ? inherited : nil
        // Scheme-bound merchant colours apply to the scheme the merchant designed for.
        let merchantScheme: ColorSchemeKind = branding?.appearanceMode?.lowercased() == "dark" ? .dark : .light
        let schemeBranding = scheme == merchantScheme ? branding : nil

        func color(_ candidates: String?...) -> RGBAColor? {
            candidates.lazy.compactMap { $0.flatMap(RGBAColor.init(css:)) }.first
        }

        var tokens = defaults
        let background = color(host.variables.colorBackground, host.backgroundColor, preset.backgroundColor)
            ?? hostTheme?.background ?? color(schemeBranding?.backgroundColor)
        if let background { tokens.background = background }
        let inherited = hostTheme?.usable(against: tokens.background)

        var primary = color(host.variables.colorPrimary, host.primaryColor, preset.primaryColor) ?? inherited?.primary
        var merchantPrimary = false
        if primary == nil, let merchant = color(branding?.primaryColor), merchant.contrast(with: tokens.background) >= 3 {
            primary = merchant
            merchantPrimary = true
        }
        if let primary {
            tokens.primary = primary
            tokens.primaryPressed = primary.mixed(with: scheme == .light ? RGBAColor(red: 0, green: 0, blue: 0) : .white, amount: 0.15)
            tokens.link = primary
            tokens.focusRing = primary
        }
        // The merchant's button text goes with the merchant's primary only.
        let onPrimary = color(host.buttonTextColor, preset.buttonTextColor, merchantPrimary ? branding?.buttonTextColor : nil)
        tokens.onPrimary = onPrimary ?? (tokens.primary.contrast(with: .white) >= tokens.primary.contrast(with: .nearBlack) ? .white : .nearBlack)

        if let text = color(host.variables.colorText) ?? inherited?.text { tokens.text = text }
        if let secondary = color(host.variables.colorTextSecondary, host.textMutedColor, preset.textMutedColor)
            ?? inherited?.textSecondary ?? color(schemeBranding?.textMutedColor) {
            tokens.textSecondary = secondary
        }
        if let placeholder = color(host.variables.colorTextPlaceholder) { tokens.textPlaceholder = placeholder }
        if let danger = color(host.variables.colorDanger, host.errorColor, preset.errorColor, branding?.errorColor) {
            tokens.danger = danger
            tokens.dangerBorder = danger
        }
        if let success = color(host.variables.colorSuccess, host.successColor, preset.successColor, branding?.successColor) {
            tokens.success = success
        }
        if let muted = color(host.secondaryColor, preset.secondaryColor, schemeBranding?.secondaryColor) {
            tokens.surfaceMuted = muted
        }
        if let inputBackground = color(host.inputBackgroundColor, preset.inputBackgroundColor, schemeBranding?.inputBackgroundColor) {
            tokens.inputBackground = inputBackground
        } else if let background {
            tokens.inputBackground = background
        }
        if let inputBorder = color(host.inputBorderColor, preset.inputBorderColor) ?? inherited?.inputBorder
            ?? color(schemeBranding?.inputBorderColor) {
            tokens.inputBorder = inputBorder
        }
        if background != nil {
            tokens.surfaceRaised = tokens.background
        }
        tokens.selectedBackground = primary == nil && background == nil
            ? defaults.selectedBackground : tokens.background.mixed(with: tokens.primary, amount: 0.12)

        let radius = AppearanceValue.length(host.variables.borderRadius) ?? AppearanceValue.length(host.borderRadius)
            ?? AppearanceValue.length(preset.borderRadius) ?? inherited?.borderRadius
            ?? AppearanceValue.brandingRadius(branding?.borderRadius) ?? 8
        let families = AppearanceValue.fontStack(host.variables.fontFamily) ?? AppearanceValue.fontStack(host.fontFamily)
            ?? AppearanceValue.fontStack(preset.fontFamily) ?? AppearanceValue.fontStack(inherited?.fontFamily)
            ?? AppearanceValue.fontStack(branding?.font) ?? ["Inter"]
        let spacing = AppearanceValue.length(host.variables.spacingUnit) ?? (branding?.density == "compact" ? 3 : 4)
        let shape = ThemeShape(
            radius: min(radius, ThemeShape.maxRadius), fontFamilies: families,
            fontSizeBase: AppearanceValue.length(host.variables.fontSizeBase) ?? 16,
            fontWeightNormal: AppearanceValue.fontWeight(host.variables.fontWeightNormal) ?? branding?.fontWeightBody ?? 400,
            fontWeightMedium: AppearanceValue.fontWeight(host.variables.fontWeightMedium) ?? 500,
            fontWeightBold: AppearanceValue.fontWeight(host.variables.fontWeightBold) ?? branding?.fontWeightHeading ?? 600,
            spacingUnit: spacing,
            gapRow: AppearanceValue.length(host.variables.spacingGridRow) ?? spacing * 3,
            gapColumn: AppearanceValue.length(host.variables.spacingGridColumn) ?? spacing * 3)

        return ResolvedTheme(
            scheme: scheme, followsSystem: preference == nil, tokens: tokens, shape: shape,
            shadow: host.shadow ?? preset.shadow ?? branding?.shadow.flatMap { AppearanceShadow(rawValue: $0.lowercased()) },
            labels: host.labels ?? .above, disableAnimations: host.disableAnimations ?? false,
            hidesWajubBranding: branding?.isWhiteLabel ?? false, logoURL: branding?.headerLogoURL,
            businessName: branding?.businessName,
            overlayOpacity: branding?.overlayIntensity.map { Double(min(max($0, 0), 100)) / 100 },
            separator: color(branding?.separatorColor))
    }
}
